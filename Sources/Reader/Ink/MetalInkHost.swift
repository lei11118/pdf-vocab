import UIKit
import PDFKit
import PencilKit

/// v0.46.0:自研墨迹引擎的宿主层 —— 把 `InkMetalCanvasView` 接到 PDFView 上。
/// v0.47.0:补齐"墨跟着 PDF 走"与"页外零墨"两条铁律。
///
/// 职责边界:
/// - **坐标唯一真相 = 页面坐标**(页号 + 页内点,左上原点)。视图坐标只活在渲染的一瞬间;
/// - **每次滚动/缩放重映射**:内部 `UIScrollView` 的 `contentOffset` / `zoomScale` 一变就重算
///   每页的屏幕矩形,把页面坐标墨迹映射到视图坐标再画 → 滚动时墨贴着纸走;
/// - **页外硬裁剪**:落库前按页矩形把一笔切成若干段,页外段直接丢弃;
///   渲染时再把页矩形传进片元着色器,连半个笔宽都出不去;
/// - **落库**:按页写 `InkPage`(JSON),切页懒加载。
final class MetalInkHost: UIView {

    // MARK: - 状态

    private weak var pdfView: PDFView?
    private let canvas = InkMetalCanvasView()
    private var store: PencilInkStore?
    private var docSha: String = ""
    /// 页号 → 墨迹(页面坐标)
    private var pages: [Int: InkPage] = [:]
    /// 页号 → 当前屏幕矩形(视图坐标)
    private var boxes: [Int: CGRect] = [:]
    /// 页号 → 页面点 → 视图点缩放
    private var scales: [Int: CGFloat] = [:]
    private var observations: [NSKeyValueObservation] = []
    private weak var observedScrollView: UIScrollView?
    private var refreshScheduled = false
    private(set) var isAttached = false
    private var visibleRange: ClosedRange<Int>?

    // MARK: - 撤销(v0.47.0:自研引擎自己管栈;PencilKit 的 undoManager 管不到这里)

    private struct UndoEntry {
        var group: Int
        var page: Int
        var before: InkPage
        var after: InkPage
    }
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private var commitGroup = 0
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var isDrawingEnabled: Bool {
        get { canvas.isDrawingEnabled }
        set { canvas.isDrawingEnabled = newValue && canvas.isReady }
    }

    /// v0.47.1:宿主是**纯渲染层**,永不接触摸。
    /// 手指直接落到 PDFView 的原生滚动/捏合/选词上;笔由挂在 PDFView 上的
    /// `InkPencilGrabRecognizer` 抓取后转给内部画布 —— 不再靠命中判定猜触摸类型。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    // MARK: - 挂载

    func attach(to pdfView: PDFView, store: PencilInkStore?, docSha: String) {
        if isAttached, self.pdfView === pdfView {
            self.store = store
            refresh()
            return
        }
        self.pdfView = pdfView
        self.store = store
        self.docSha = docSha
        backgroundColor = .clear
        isOpaque = false
        canvas.frame = bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.onStrokeCommitted = { [weak self] stroke in self?.commit(stroke) }
        addSubview(canvas)
        frame = pdfView.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.addSubview(self)
        isAttached = true
        // v0.47.1:笔从 PDFView 上"抓",不靠命中 —— 手指永远走原生滚动
        installPencilGrab(on: pdfView)
        observeScroll()
        refresh()
        DiagLog.log("metal ink: attached size=\(Int(bounds.width))x\(Int(bounds.height))")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        if let pdfView, frame != pdfView.bounds { frame = pdfView.bounds }
        scheduleRefresh()
    }

    // MARK: - 抓笔(只接 Pencil,手指完全不经它手)

    private var pencilGrab: InkPencilGrabRecognizer?

    private func installPencilGrab(on pdfView: PDFView) {
        guard pencilGrab == nil else { return }
        let grab = InkPencilGrabRecognizer(target: nil, action: nil)
        // 只有"书写模式 + 渲染器就绪"才吃笔;否则这个识别器什么都不做(它本来就不取消触摸)
        grab.isActive = { [weak self] in
            guard let self else { return false }
            return self.canvas.isDrawingEnabled && self.canvas.isReady
        }
        grab.onBegan = { [weak self] touch, _ in
            self?.canvas.handleBegan(touch)
        }
        grab.onMoved = { [weak self] touches, event in
            self?.canvas.handleMoved(touches, event: event)
        }
        grab.onEnded = { [weak self] touches, event in
            self?.canvas.handleEnded(touches, event: event)
        }
        grab.onCancelled = { [weak self] in
            self?.canvas.handleCancelled()
        }
        pdfView.addGestureRecognizer(grab)
        pencilGrab = grab
        DiagLog.log("metal ink: pencil grab installed")
    }

    // MARK: - 跟着 PDFView 滚动 / 缩放

    /// PDFView 不是 UIScrollView,内部滚动视图要从子树里找。
    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let pdf = view as? PDFView, let parent = pdf.documentView?.superview as? UIScrollView {
            return parent
        }
        if let direct = view.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView { return direct }
        for sub in view.subviews {
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    private func observeScroll() {
        guard let pdfView else { return }
        observations.removeAll()
        guard let scroll = findScrollView(in: pdfView) else {
            DiagLog.log("metal ink: no scroll view (fallback to layout refresh)")
            return
        }
        observedScrollView = scroll
        // v0.47.0 根因:滚动/缩放原先**没有任何观察者** → pageRects 只在 refresh() 时才更新,
        // 屏幕上的墨钉在视图坐标里不动,翻页时才整块跳到新位置
        // (用户:"不随 PDF 滑动、飘到其他地方")。
        observations = [
            scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            scroll.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() }
        ]
        DiagLog.log("metal ink: scroll observed zoom=\(String(format: "%.2f", scroll.zoomScale))")
    }

    /// 同一 runloop 内多次滚动回调合并成一次重算
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    // MARK: - 工具

    func applyTool(color: UIColor, baseWidth: CGFloat) {
        canvas.inkColor = color
        canvas.baseWidth = max(0.8, baseWidth)
        canvas.viewScale = scales[currentIndex() ?? 0] ?? 1
    }

    // MARK: - 布局 / 重映射

    private func currentIndex() -> Int? {
        guard let pdfView, let document = pdfView.document else { return nil }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard let page = pdfView.page(for: center, nearest: true) else { return nil }
        return document.index(for: page)
    }

    /// 重算可见页矩形 + 把页面坐标墨迹映射到视图坐标
    func refresh() {
        guard let pdfView, let document = pdfView.document, document.pageCount > 0 else { return }
        if frame != pdfView.bounds { frame = pdfView.bounds }
        if canvas.frame != bounds { canvas.frame = bounds }

        let current = currentIndex() ?? 0
        let lo = max(0, current - 2)
        let hi = min(document.pageCount - 1, current + 2)
        visibleRange = lo...max(lo, hi)

        var newBoxes: [Int: CGRect] = [:]
        var newScales: [Int: CGFloat] = [:]
        var items: [InkRenderItem] = []
        for index in visibleRange ?? (0...0) {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: pdfView.displayBox)
            guard box.width > 1, box.height > 1 else { continue }
            let rect = pdfView.convert(box, from: page)
            guard rect.width > 1, rect.height > 1 else { continue }
            let scale = rect.width / box.width
            newBoxes[index] = rect
            newScales[index] = scale
            guard let pageInk = pageInk(index) else { continue }
            for stroke in pageInk.strokes {
                var mapped = stroke
                mapped.points = stroke.points.map { p in
                    var q = p
                    q.x = p.x * Double(scale) + Double(rect.minX)
                    q.y = p.y * Double(scale) + Double(rect.minY)
                    q.width = p.width * Double(scale)
                    return q
                }
                items.append(InkRenderItem(stroke: mapped, clip: rect))
            }
        }
        boxes = newBoxes
        scales = newScales
        canvas.clipRects = Array(newBoxes.values)
        canvas.viewScale = newScales[current] ?? 1
        canvas.renderItems = items
        DiagLog.log("metal ink: refresh pages=\(newBoxes.count) strokes=\(items.count)")
    }

    // MARK: - 读页(含旧数据迁移与污染清理)

    private func pageInk(_ index: Int) -> InkPage? {
        if let cached = pages[index] { return cached }
        guard let store, !docSha.isEmpty, let record = store.drawing(docSha: docSha, page: index) else { return nil }
        if let page = InkPage.decode(record.data) {
            // v0.47.0:v0.46.x 写进去的"同一笔重复几百份"必须清掉,否则永远是一团重影
            let cleaned = sanitize(page, index: index)
            if cleaned.strokes.count != page.strokes.count {
                DiagLog.log("metal ink: cleaned page \(index) \(page.strokes.count)->\(cleaned.strokes.count)")
                store.save(docSha: docSha, page: index, data: cleaned.data(), scale: 1)
            }
            pages[index] = cleaned
            return cleaned
        }
        if let legacy = try? PKDrawing(data: record.data) {
            let scale = max(1, record.scale)
            let page = InkPage(strokes: InkLegacyMigration.strokes(from: legacy, scale: CGFloat(scale)))
            let cleaned = sanitize(page, index: index)
            pages[index] = cleaned
            DiagLog.log("metal ink: migrated page \(index) strokes=\(cleaned.strokes.count)")
            return cleaned
        }
        return nil
    }

    /// 丢弃页外笔迹、退化笔迹与重复副本
    private func sanitize(_ page: InkPage, index: Int) -> InkPage {
        guard let pdfView, let document = pdfView.document, let pdfPage = document.page(at: index) else { return page }
        let box = pdfPage.bounds(for: pdfView.displayBox)
        let allowed = CGRect(x: -4, y: -4, width: box.width + 8, height: box.height + 8)
        var kept: [InkStroke] = []
        var signatures: Set<String> = []
        for stroke in page.strokes {
            guard stroke.points.count >= 2 else { continue }
            let mid = stroke.points[stroke.points.count / 2].cg
            guard allowed.contains(mid) else { continue }
            // 同一笔的重复副本:点数相同且首尾点几乎重合
            let first = stroke.points[0], last = stroke.points[stroke.points.count - 1]
            let sig = "\(stroke.points.count)|\(Int(first.x / 2))|\(Int(first.y / 2))|\(Int(last.x / 2))|\(Int(last.y / 2))"
            guard !signatures.contains(sig) else { continue }
            signatures.insert(sig)
            kept.append(stroke)
        }
        return InkPage(strokes: kept)
    }

    // MARK: - 落库

    /// 提交一段墨(视图坐标):按页矩形切成若干段,页外段丢弃,每段换算回所属页的页面坐标
    private func commit(_ stroke: InkStroke) {
        guard stroke.points.count >= 2, !boxes.isEmpty else { return }
        commitGroup += 1
        var currentPage: Int?
        var run: [InkPoint] = []
        var saved = 0

        func flushRun() {
            guard let index = currentPage, run.count >= 2,
                  let rect = boxes[index], let scale = scales[index], scale > 0 else {
                run.removeAll(); return
            }
            var s = stroke
            s.points = run.map { p in
                var q = p
                q.x = (p.x - Double(rect.minX)) / Double(scale)
                q.y = (p.y - Double(rect.minY)) / Double(scale)
                q.width = p.width / Double(scale)
                return q
            }
            // 硬边界:换算后再滤一次,页外点不进库
            s.points = s.points.filter { $0.x >= -0.5 && $0.y >= -0.5 }
            guard s.points.count >= 2 else { run.removeAll(); return }
            var page = pages[index] ?? InkPage()
            // 撤销快照:动作前整页(写时复制,落笔瞬间零序列化)
            undoStack.append(UndoEntry(group: commitGroup, page: index, before: page, after: page))
            redoStack.removeAll()
            page.append(s)
            pages[index] = page
            if !undoStack.isEmpty { undoStack[undoStack.count - 1].after = page }
            store?.save(docSha: docSha, page: index, data: page.data(), scale: 1)
            saved += 1
            run.removeAll()
        }

        for p in stroke.points {
            let v = CGPoint(x: p.x, y: p.y)
            if let index = boxes.first(where: { $0.value.contains(v) })?.key {
                if currentPage != index {
                    flushRun()
                    currentPage = index
                }
                run.append(p)
            } else {
                flushRun()
                currentPage = nil
            }
        }
        flushRun()
        DiagLog.log("metal ink: commit strokes=\(saved)")
        // 立刻重映射:否则刚写的墨要等下一次滚动/翻页才出现(用户:"写完就消失")
        refresh()
    }

    // MARK: - 撤销 / 重做

    /// 撤销一次动作(一笔跨页时该笔涉及的所有页一起回退)
    func undo() {
        guard let group = undoStack.last?.group else { return }
        var touched: Set<Int> = []
        var moved: [UndoEntry] = []
        while let last = undoStack.last, last.group == group {
            pages[last.page] = last.before
            touched.insert(last.page)
            moved.append(last)
            undoStack.removeLast()
        }
        redoStack.append(contentsOf: moved.reversed())
        persist(touched)
        DiagLog.log("metal ink: undo pages=\(touched.count)")
    }

    func redo() {
        guard let group = redoStack.last?.group else { return }
        var touched: Set<Int> = []
        var moved: [UndoEntry] = []
        while let last = redoStack.last, last.group == group {
            pages[last.page] = last.after
            touched.insert(last.page)
            moved.append(last)
            redoStack.removeLast()
        }
        undoStack.append(contentsOf: moved.reversed())
        persist(touched)
        DiagLog.log("metal ink: redo pages=\(touched.count)")
    }

    private func persist(_ pages: Set<Int>) {
        for index in pages {
            let ink = self.pages[index] ?? InkPage()
            store?.save(docSha: docSha, page: index, data: ink.data(), scale: 1)
        }
        refresh()
    }
}
