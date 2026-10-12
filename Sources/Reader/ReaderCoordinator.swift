import UIKit
import PDFKit

/// 自绘拖动柄:原生风格的蓝点 + 指向文字的短柄(起点柄在文字上方、终点柄在文字下方)。
final class SelectionHandleView: UIView {
    private let dot = UIView()
    private let stem = UIView()
    private let isStart: Bool

    init(isStart: Bool) {
        self.isStart = isStart
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        backgroundColor = .clear
        dot.backgroundColor = .systemBlue
        dot.layer.cornerRadius = 7
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.borderWidth = 1.5
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.25
        dot.layer.shadowRadius = 1.5
        dot.layer.shadowOffset = CGSize(width: 0, height: 0.5)
        addSubview(dot)
        stem.backgroundColor = .systemBlue
        stem.layer.cornerRadius = 1.25
        addSubview(stem)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let dotSize: CGFloat = 14
        if isStart {
            // 起点柄:圆点在选区下方,短柄朝上指向首行(与 iOS 原生不对称布局一致)
            dot.frame = CGRect(x: (bounds.width - dotSize) / 2, y: (bounds.height - dotSize) / 2 + 6, width: dotSize, height: dotSize)
            stem.frame = CGRect(x: bounds.width / 2 - 1.25, y: dot.frame.minY - 6, width: 2.5, height: 6)
        } else {
            // 终点柄:圆点在选区上方,短柄朝下指向末行
            dot.frame = CGRect(x: (bounds.width - dotSize) / 2, y: (bounds.height - dotSize) / 2 - 6, width: dotSize, height: dotSize)
            stem.frame = CGRect(x: bounds.width / 2 - 1.25, y: dot.frame.maxY, width: 2.5, height: 6)
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -14, dy: -14).contains(point)
    }
}

/// 取词交互协调器(v0.3.2)。
///
/// 架构:**手指与 Pencil 统一走自有取词管线**(长按 → 点坐标取词 → 拖动扩展 → 自研拖动柄 → 自绘编辑菜单),
/// 并**停用 PDFKit 内置的选择手势**(长按/双击)——真机实证:内置选择机制在部分 PDF 上会把选区
/// 解析到文档末尾,触发"跳最后一页 + 卡死";自有管线无此问题。
/// 全程**不设置 PDFView 的选区状态**(setCurrentSelection 不存在),
/// 黄高亮/拖动柄/信息条/菜单全部由自有状态驱动。
///
/// v0.3.4:
/// - 选区蓝贴近 iOS 原生(systemBlue 半透明);
/// - 拖动柄与原生同款**不对称布局**:起点柄在选区**下方**(短柄朝上)、终点柄在选区**上方**(短柄朝下);
/// - 点击规则:点选区=仅切换编辑菜单(**永不关闭选区**,编辑栏关闭≠选区关闭);点空白=菜单开着时先只关菜单,否则取消选中。
final class ReaderCoordinator: NSObject {
    weak var pdfView: PDFView?
    var onPageChanged: (Int) -> Void
    var onSelectionInfo: ((SelectionInfo?) -> Void)
    /// 「翻译」菜单项的回调(由 SwiftUI 层弹出系统翻译面板)
    var onTranslate: ((String) -> Void)?
    /// 当前文档标识(sha 前 8 位,取自文件名),仅用于日志
    var docLabel = ""

    private var tempAnnotations: [String: (page: PDFPage, annotation: PDFAnnotation)] = [:]
    private var tempRects: [(page: PDFPage, rect: CGRect)] = []
    private var lastAppliedSelectionKey: String?
    private var observers: [NSObjectProtocol] = []

    // 手势状态
    private weak var fingerSelectRef: UILongPressGestureRecognizer?
    private weak var pencilSelectRef: UILongPressGestureRecognizer?
    private var lastOwnSelectionActionTime: CFAbsoluteTime = 0
    private var lastAnySelectionChangeTime: CFAbsoluteTime = 0
    private var lastAppliedCharCount = 0
    private var suppressLogged = false
    /// 自有路线最近一次选中的文本(菜单各项与手势结束判断用)
    private var lastOurSelectionText = ""

    // 拖动柄
    private var startHandle: SelectionHandleView?
    private var endHandle: SelectionHandleView?
    private var handleDrag: DragState?
    private var scrollObservers: [NSKeyValueObservation] = []

    // 拖动期间冻结滚动
    private weak var frozenScrollView: UIScrollView?
    private var scrollWasEnabled = false

    // 防跳页
    private var lastGoodPage: (index: Int, time: CFAbsoluteTime) = (0, 0)
    private var jumpGuardUntil: CFAbsoluteTime = 0

    // 自定义编辑菜单
    private var editMenuInteraction: UIEditMenuInteraction?
    private var isMenuPresented = false

    private struct DragState {
        var page: PDFPage
        var anchorPoint: CGPoint
        var anchorWord: PDFSelection
        var lastPoint: CGPoint
    }
    private var drag: DragState?

    private static let maxHighlightLines = 150

    init(
        onPageChanged: @escaping (Int) -> Void,
        onSelectionInfo: @escaping (SelectionInfo?) -> Void
    ) {
        self.onPageChanged = onPageChanged
        self.onSelectionInfo = onSelectionInfo
    }

    deinit {
        scrollObservers.forEach { $0.invalidate() }
        removeObservers()
    }

    // MARK: - 通知

    func installObservers() {
        guard let pdfView else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.pageDidChange()
        })
        observers.append(nc.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.selectionDidChange()
        })
        observers.append(nc.addObserver(forName: .PDFViewDocumentChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.documentDidChange()
        })
    }

    func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// 文档加载完成后调用:记录信息 + 压制内置手势 + 挂载滚动观察(拖动柄跟随滚动/缩放)
    func documentDidLoad(_ document: PDFDocument) {
        DiagLog.log("doc: \(document.pageCount) pages sha=\(docLabel.prefix(8))")
        suppressNativeSelection(in: pdfView)
        observeScrolling()
        for delay in [0.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let view = self.pdfView else { return }
                self.suppressNativeSelection(in: view)
            }
        }
    }

    private func documentDidChange() {
        guard let pdfView else { return }
        if let doc = pdfView.document {
            DiagLog.log("docChanged: \(doc.pageCount) pages")
        }
        jumpGuardUntil = 0
        let index = pdfView.document.flatMap { doc in pdfView.currentPage.map { doc.index(for: $0) } } ?? 0
        lastGoodPage = (index, CFAbsoluteTimeGetCurrent())
        freezeScrolling(false)
        suppressNativeSelection(in: pdfView)
        observeScrolling()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let view = self.pdfView else { return }
            self.suppressNativeSelection(in: view)
        }
    }

    private func pageDidChange() {
        guard let pdfView, let page = pdfView.currentPage else { return }
        let index = pdfView.document?.index(for: page) ?? 0
        let now = CFAbsoluteTimeGetCurrent()
        DiagLog.log("page->\(index)")

        // 防跳页:紧跟选区变化(0.8s 内)的跨页"前跳"判为异常,拉回上次稳定页
        if now > jumpGuardUntil,
           now - lastAnySelectionChangeTime < 0.8,
           abs(index - lastGoodPage.index) > 5,
           index > lastGoodPage.index {
            DiagLog.log("JUMP suspected \(lastGoodPage.index)->\(index); restore")
            jumpGuardUntil = now + 1.0
            if let target = pdfView.document?.page(at: lastGoodPage.index) {
                pdfView.go(to: target)
            }
            return
        }

        lastGoodPage = (index, now)
        suppressNativeSelection(in: pdfView)
        refreshHandles()
        onPageChanged(index)
    }

    // MARK: - 手势与拖动柄

    func installGestures(on view: PDFView) {
        // 手指长按选词(0.5s)
        let fingerSelect = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        fingerSelect.minimumPressDuration = 0.5
        fingerSelect.allowableMovement = 14
        fingerSelect.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.addGestureRecognizer(fingerSelect)
        fingerSelectRef = fingerSelect

        // Pencil 长按选词(0.45s)
        let pencilSelect = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        pencilSelect.minimumPressDuration = 0.45
        pencilSelect.allowableMovement = 14
        pencilSelect.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        view.addGestureRecognizer(pencilSelect)
        pencilSelectRef = pencilSelect

        // 自绘编辑菜单
        let menuInteraction = UIEditMenuInteraction(delegate: self)
        view.addInteraction(menuInteraction)
        editMenuInteraction = menuInteraction

        // 单击:点在已加亮词上保持,点空白清除;须等长按失败(避免与长按双击发)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]
        tap.delegate = self
        tap.require(toFail: fingerSelect)
        tap.require(toFail: pencilSelect)
        view.addGestureRecognizer(tap)

        // 自研拖动柄(原生风格:蓝点 + 指向文字的短柄)
        let start = SelectionHandleView(isStart: true)
        start.isHidden = true
        view.addSubview(start)
        startHandle = start
        let end = SelectionHandleView(isStart: false)
        end.isHidden = true
        view.addSubview(end)
        endHandle = end
        for handle in [start, end] {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleHandlePan(_:)))
            handle.addGestureRecognizer(pan)
        }

        suppressNativeSelection(in: view)
        observeScrolling()
    }

    /// 停用 PDFKit 内置的选择手势(长按 / 双击)。
    /// 这些机制在异常文本层文档上会触发"跳最后一页 + 卡死",且与自有管线冲突;
    /// 保留滚动、缩放与链接单击。
    func suppressNativeSelection(in view: UIView?) {
        guard let view else { return }
        var disabled = 0
        func walk(_ v: UIView) {
            for gr in v.gestureRecognizers ?? [] {
                if gr === fingerSelectRef || gr === pencilSelectRef { continue }
                let isLongPress = gr is UILongPressGestureRecognizer
                let isMultiTap = (gr as? UITapGestureRecognizer).map { $0.numberOfTapsRequired >= 2 } ?? false
                if (isLongPress || isMultiTap), gr.isEnabled {
                    gr.isEnabled = false
                    disabled += 1
                }
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        if disabled > 0, !suppressLogged {
            suppressLogged = true
            DiagLog.log("suppressNative: disabled \(disabled) recognizers")
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let pdfView else { return }
        let kind = Self.kind(of: gesture)
        let viewPoint = gesture.location(in: pdfView)

        switch gesture.state {
        case .began:
            guard let hit = pageHit(viewPoint) else {
                DiagLog.log("press.began(\(kind)): no page")
                return
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            let word = hit.page.selectionForWord(at: hit.point) ?? hit.page.selectionForLine(at: hit.point)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            guard let word, Self.isSane(word, maxPages: 1, maxChars: 300) else {
                DiagLog.log(String(format: "press.began(%@): no word (%.0fms)", kind, ms))
                return
            }
            let snippet = Self.logSnippet(word.string ?? "")
            DiagLog.log(String(format: "press.began(%@): word=「%@」 len=%d pickup=%.0fms", kind, snippet, word.string?.count ?? 0, ms))
            drag = DragState(page: hit.page, anchorPoint: hit.point, anchorWord: word, lastPoint: hit.point)
            freezeScrolling(true) // 拖动期间页面不再滚动,拖动=稳定扩选
            applyOurSelection(word)

        case .changed:
            guard let dragState = drag,
                  let hit = pageHit(viewPoint), hit.page === dragState.page else { return }
            let step: CGFloat = lastAppliedCharCount > 800 ? 8 : 3
            let dx = hit.point.x - dragState.lastPoint.x
            let dy = hit.point.y - dragState.lastPoint.y
            guard dx * dx + dy * dy >= step * step else { return }
            drag?.lastPoint = hit.point
            let t0 = CFAbsoluteTimeGetCurrent()
            if let selection = selectionBetween(dragState, and: hit.point) {
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                if ms > 60 {
                    DiagLog.log(String(format: "press.changed slow %.0fms", ms))
                }
                applyOurSelection(selection)
            }

        case .ended, .cancelled, .failed:
            let hadDrag = drag != nil
            let isEnded = gesture.state == .ended
            drag = nil
            freezeScrolling(false)
            DiagLog.log("press.end(\(kind)) ours=\(hadDrag) ended=\(isEnded)")
            refreshHandles()
            if hadDrag, isEnded, !lastOurSelectionText.isEmpty {
                let point = gesture.location(in: pdfView)
                editMenuInteraction?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
                DiagLog.log("menu presented")
            }

        default:
            break
        }
    }

    /// 拖动柄:拖住选区一端的圆点,按自有扩选逻辑微调(另一端的词为锚点)。
    @objc private func handleHandlePan(_ gesture: UIPanGestureRecognizer) {
        guard let pdfView else { return }
        let isStart = (gesture.view === startHandle)
        let viewPoint = gesture.location(in: pdfView)

        switch gesture.state {
        case .began:
            guard let (page, rects) = orderedSelectionRects(),
                  let firstLine = rects.first, let lastLine = rects.last else { return }
            let fixedPoint = isStart
                ? CGPoint(x: lastLine.maxX - 0.6, y: lastLine.midY)
                : CGPoint(x: firstLine.minX + 0.6, y: firstLine.midY)
            guard let anchor = page.selectionForWord(at: fixedPoint) ?? page.selectionForLine(at: fixedPoint) else { return }
            handleDrag = DragState(page: page, anchorPoint: fixedPoint, anchorWord: anchor, lastPoint: fixedPoint)
            freezeScrolling(true)
            DiagLog.log("handle.drag began isStart=\(isStart)")

        case .changed:
            guard let hd = handleDrag, let hit = pageHit(viewPoint), hit.page === hd.page else { return }
            let dx = hit.point.x - hd.lastPoint.x
            let dy = hit.point.y - hd.lastPoint.y
            guard dx * dx + dy * dy >= 4 else { return } // 2pt 细粒度
            handleDrag?.lastPoint = hit.point
            if let selection = selectionBetween(hd, and: hit.point) {
                applyOurSelection(selection)
            }

        case .ended, .cancelled, .failed:
            handleDrag = nil
            freezeScrolling(false)
            DiagLog.log("handle.drag end")
            refreshHandles()

        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let pdfView else { return }
        let point = gesture.location(in: pdfView)

        if let page = pdfView.page(for: point, nearest: false) {
            let pagePoint = pdfView.convert(point, to: page)
            // 命中判定留宽容差(行间隙/选区边缘的点击都算"点选区")
            let onHighlight = tempRects.contains { $0.page === page && $0.rect.insetBy(dx: -10, dy: -10).contains(pagePoint) }
            if onHighlight {
                // 点选区:只切换编辑菜单,**永不关闭选区**
                if isMenuPresented {
                    editMenuInteraction?.dismissMenu()
                    isMenuPresented = false
                    DiagLog.log("tap: dismiss menu (selection kept)")
                } else {
                    editMenuInteraction?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
                    DiagLog.log("tap: show menu (selection kept)")
                }
                return
            }
        }
        // 点空白:若编辑菜单开着,先只关菜单(选区保留);菜单已关时再取消选中
        if isMenuPresented {
            editMenuInteraction?.dismissMenu()
            isMenuPresented = false
            DiagLog.log("tap: dismiss menu only")
            return
        }
        DiagLog.log("tap: clear")
        clearSelectionEverything()
    }

    // MARK: - 拖动柄显示/计算

    /// 选区行矩形,按阅读顺序(从上到下、从左到右)。
    private func orderedSelectionRects() -> (page: PDFPage, rects: [CGRect])? {
        guard let first = tempRects.first else { return nil }
        let page = first.page
        let rects = tempRects.filter { $0.page === page }.map { $0.rect }
            .sorted { a, b in
                if abs(a.midY - b.midY) < 2 { return a.minX < b.minX }
                return a.midY > b.midY
            }
        return (page, rects)
    }

    /// 更新两个拖动柄的位置(起点=首行左上,终点=末行右下)。
    private func refreshHandles() {
        guard let pdfView, drag == nil else {
            hideHandles()
            return
        }
        guard let (page, rects) = orderedSelectionRects(),
              let firstLine = rects.first, let lastLine = rects.last else {
            hideHandles()
            return
        }
        // 与 iOS 原生同款不对称布局:起点柄在首行**下方**(圆点在下),终点柄在末行**上方**(圆点在上)
        let startView = pdfView.convert(CGPoint(x: firstLine.minX, y: firstLine.minY), from: page)
        let endView = pdfView.convert(CGPoint(x: lastLine.maxX, y: lastLine.maxY), from: page)
        place(startHandle, at: CGPoint(x: startView.x, y: startView.y + 16))
        place(endHandle, at: CGPoint(x: endView.x, y: endView.y - 16))
    }

    private func place(_ handle: SelectionHandleView?, at center: CGPoint) {
        guard let handle else { return }
        handle.isHidden = false
        handle.center = center
    }

    private func hideHandles() {
        startHandle?.isHidden = true
        endHandle?.isHidden = true
    }

    /// 拖动柄跟随滚动/缩放
    private func observeScrolling() {
        guard let pdfView else { return }
        guard let sv = pdfScrollView(pdfView) else { return }
        if observedScrollView === sv, scrollObservers.count == 2 {
            return
        }
        scrollObservers.forEach { $0.invalidate() }
        scrollObservers.removeAll()
        observedScrollView = sv
        scrollObservers.append(sv.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.refreshHandles()
        })
        scrollObservers.append(sv.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in
            self?.refreshHandles()
        })
    }
    private weak var observedScrollView: UIScrollView?

    // MARK: - 选择 / 高亮

    /// 自有路线选中:只更新黄高亮/信息条/拖动柄,**不触碰 PDFView 的选区状态**。
    private func applyOurSelection(_ selection: PDFSelection) {
        guard let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lastOwnSelectionActionTime = now
        lastAnySelectionChangeTime = now
        lastOurSelectionText = text
        applySelection(selection, text: text, src: "own")
    }

    private func selectionDidChange() {
        guard let pdfView else { return }

        let selection = pdfView.currentSelection
        let text = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let now = CFAbsoluteTimeGetCurrent()
        let isOurs = now - lastOwnSelectionActionTime <= 0.05
        lastAnySelectionChangeTime = now
        if !isOurs, !text.isEmpty {
            // 内置手势没能压住(被重建):再次压制,并留下证据
            DiagLog.log("native sel detected; re-suppress")
            suppressNativeSelection(in: pdfView)
        }
        DiagLog.log("selChange(\(isOurs ? "own" : "native")): len=\(text.count) pages=\(selection?.pages.count ?? 0) 「\(Self.logSnippet(text))」")

        if let selection, !selection.pages.isEmpty, !text.isEmpty {
            applySelection(selection, text: text, src: isOurs ? "own" : "native")
        } else {
            lastAppliedSelectionKey = nil
            lastAppliedCharCount = 0
            lastOurSelectionText = ""
            clearTempHighlight()
            onSelectionInfo(nil)
        }
    }

    private func applySelection(_ selection: PDFSelection, text: String, src: String) {
        guard Self.isSane(selection, maxPages: 1, maxChars: 6_000) else {
            DiagLog.log("applySelection rejected(\(src)): pages=\(selection.pages.count) len=\(text.count)")
            lastAppliedSelectionKey = nil
            lastAppliedCharCount = 0
            clearTempHighlight()
            onSelectionInfo(nil)
            return
        }
        let pageIndex = selection.pages.first.flatMap { pdfView?.document?.index(for: $0) } ?? -1
        let key = "\(pageIndex)|\(text.count)|\(text.hashValue)"
        guard key != lastAppliedSelectionKey else { return }
        lastAppliedSelectionKey = key
        lastAppliedCharCount = text.count
        updateTempHighlight(for: selection)
        refreshHandles()
        let display = text.count > 400 ? String(text.prefix(400)) + "…" : text
        onSelectionInfo(SelectionInfo(text: display, wordCount: WordPicker.countWords(in: text)))
    }

    /// 差量更新临时高亮:只移除消失的行、只新增出现的行;越界矩形拒绝并计数。
    private func updateTempHighlight(for selection: PDFSelection) {
        let t0 = CFAbsoluteTimeGetCurrent()
        var desired: [String: (page: PDFPage, rect: CGRect)] = [:]
        var rejected = 0
        for page in selection.pages {
            let pageBounds = page.bounds(for: pdfView?.displayBox ?? .cropBox)
            let lineSelections = selection.selectionsByLine()
                .prefix(Self.maxHighlightLines)
                .filter { $0.pages.first === page }
            var rects = lineSelections.map { $0.bounds(for: page) }
            if rects.isEmpty { rects = [selection.bounds(for: page)] }

            for rect in rects {
                guard Self.isValid(rect) else { rejected += 1; continue }
                guard rect.intersects(pageBounds.insetBy(dx: -24, dy: -24)) else { rejected += 1; continue }
                desired[annotationKey(page, rect)] = (page, rect)
            }
        }

        let staleKeys = tempAnnotations.keys.filter { desired[$0] == nil }
        for key in staleKeys {
            if let entry = tempAnnotations.removeValue(forKey: key) {
                entry.page.removeAnnotation(entry.annotation)
            }
        }

        for (key, entry) in desired where tempAnnotations[key] == nil {
            let annotation = PDFAnnotation(
                bounds: entry.rect.insetBy(dx: -1, dy: -1),
                forType: .highlight,
                withProperties: nil
            )
            annotation.color = UIColor.systemBlue.withAlphaComponent(0.30)
            entry.page.addAnnotation(annotation)
            tempAnnotations[key] = (entry.page, annotation)
        }

        tempRects = desired.values.map { ($0.page, $0.rect) }

        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        DiagLog.log(String(format: "hl: lines=%d ms=%.0f rej=%d", desired.count, ms, rejected))
    }

    func clearTempHighlight() {
        for (_, entry) in tempAnnotations {
            entry.page.removeAnnotation(entry.annotation)
        }
        tempAnnotations.removeAll()
        tempRects.removeAll()
        hideHandles()
    }

    private func clearSelectionEverything() {
        guard let pdfView else { return }
        DiagLog.log("clearSelection")
        if isMenuPresented {
            editMenuInteraction?.dismissMenu()
            isMenuPresented = false
        }
        freezeScrolling(false)
        pdfView.currentSelection = nil
        pdfView.clearSelection()
        lastAppliedSelectionKey = nil
        lastAppliedCharCount = 0
        lastOurSelectionText = ""
        clearTempHighlight()
        onSelectionInfo(nil)
    }

    // MARK: - 拖选计算(纯点坐标)

    private func selectionBetween(_ dragState: DragState, and current: CGPoint) -> PDFSelection? {
        let page = dragState.page
        let anchorRect = dragState.anchorWord.bounds(for: page)

        if let currentWord = page.selectionForWord(at: current) {
            let currentRect = currentWord.bounds(for: page)
            if Self.isValid(anchorRect), Self.isValid(currentRect) {
                let leftPoint = CGPoint(x: anchorRect.minX + 0.6, y: anchorRect.midY)
                let rightPoint = CGPoint(x: currentRect.maxX - 0.6, y: currentRect.midY)
                let (from, to) = Self.ordered(leftPoint, rightPoint)
                if let selection = page.selection(from: from, to: to),
                   Self.isSane(selection, maxPages: 2, maxChars: 6_000),
                   let text = selection.string, !text.isEmpty {
                    return selection
                }
            }
        }
        return page.selection(from: dragState.anchorPoint, to: current)
    }

    /// 页面坐标 y 向上:先按行(容差 6pt),同行按 x 排序,保证 from 在 to 之前。
    private static func ordered(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
        if abs(a.y - b.y) < 6 { return a.x <= b.x ? (a, b) : (b, a) }
        return a.y > b.y ? (a, b) : (b, a)
    }

    private static func isSane(_ selection: PDFSelection, maxPages: Int, maxChars: Int) -> Bool {
        guard !selection.pages.isEmpty, selection.pages.count <= maxPages else { return false }
        guard let text = selection.string, !text.isEmpty, text.count <= maxChars else { return false }
        return true
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.width < 10_000 && rect.height < 10_000
    }

    private static func kind(of gesture: UILongPressGestureRecognizer) -> String {
        if let t = gesture.allowedTouchTypes.first, t.intValue == Int32(UITouch.TouchType.pencil.rawValue) {
            return "pencil"
        }
        return "finger"
    }

    private static func logSnippet(_ s: String) -> String {
        String(s.replacingOccurrences(of: "\n", with: " ").prefix(16))
    }

    // MARK: - 工具

    private func annotationKey(_ page: PDFPage, _ rect: CGRect) -> String {
        let r = String(format: "%.1f_%.1f_%.1f_%.1f", rect.minX, rect.minY, rect.width, rect.height)
        return "\(ObjectIdentifier(page).hashValue)_\(r)"
    }

    private func pageHit(_ viewPoint: CGPoint) -> (page: PDFPage, point: CGPoint)? {
        guard let pdfView else { return nil }
        if let page = pdfView.page(for: viewPoint, nearest: false) {
            return (page, pdfView.convert(viewPoint, to: page))
        }
        guard let page = pdfView.page(for: viewPoint, nearest: true) else { return nil }
        let point = pdfView.convert(viewPoint, to: page)
        let bounds = page.bounds(for: pdfView.displayBox)
        guard bounds.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        return (page, point)
    }

    private func pdfScrollView(_ view: PDFView) -> UIScrollView? {
        if let scroll = view.documentView?.superview as? UIScrollView { return scroll }
        return Self.findScrollView(in: view)
    }

    private static func findScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for subview in view.subviews {
            if let scroll = findScrollView(in: subview) { return scroll }
        }
        return nil
    }

    /// 长按拖动期间冻结/恢复页面滚动(与原生选择手感一致,避免拖动被滚动抢走)。
    private func freezeScrolling(_ freeze: Bool) {
        guard let pdfView else { return }
        if freeze {
            if frozenScrollView == nil, let sv = pdfScrollView(pdfView) {
                scrollWasEnabled = sv.panGestureRecognizer.isEnabled
                if scrollWasEnabled {
                    sv.panGestureRecognizer.isEnabled = false
                }
                frozenScrollView = sv
                DiagLog.log("scroll frozen")
            }
        } else {
            if let sv = frozenScrollView, scrollWasEnabled {
                sv.panGestureRecognizer.isEnabled = true
            }
            frozenScrollView = nil
        }
    }

    private static func topViewController(from view: UIView) -> UIViewController? {
        var vc = view.window?.rootViewController
        while let presented = vc?.presentedViewController {
            vc = presented
        }
        return vc
    }

    private func presentShare(text: String, sourcePoint: CGPoint) {
        guard let pdfView, let host = Self.topViewController(from: pdfView) else {
            DiagLog.log("share: no host")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            if let pop = vc.popoverPresentationController {
                pop.sourceView = pdfView
                pop.sourceRect = CGRect(x: sourcePoint.x, y: sourcePoint.y, width: 1, height: 1)
            }
            host.present(vc, animated: true)
            DiagLog.log("share presented")
        }
    }

    /// 系统词典「查询」
    private func presentLookup(term: String) {
        guard let pdfView, let host = Self.topViewController(from: pdfView) else { return }
        if UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: term) {
            let vc = UIReferenceLibraryViewController(term: term)
            host.present(vc, animated: true)
            DiagLog.log("lookup presented")
        } else {
            let alert = UIAlertController(title: "未找到词条", message: "系统词典中没有「\(term)」的释义。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            host.present(alert, animated: true)
            DiagLog.log("lookup: no definition")
        }
    }
}

extension ReaderCoordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

extension ReaderCoordinator: UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        willPresentMenuFor configuration: UIEditMenuConfiguration,
        animator: UIEditMenuInteractionAnimating
    ) {
        isMenuPresented = true
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: UIEditMenuInteractionAnimating
    ) {
        isMenuPresented = false
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        let text = lastOurSelectionText.isEmpty ? (pdfView?.currentSelection?.string ?? "") : lastOurSelectionText

        let copy = UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            guard let self else { return }
            var value = self.lastOurSelectionText
            if value.isEmpty { value = self.pdfView?.currentSelection?.string ?? "" }
            guard !value.isEmpty else { return }
            UIPasteboard.general.string = value
        }

        let lookup = UIAction(title: "查询", image: UIImage(systemName: "book")) { [weak self] _ in
            guard let self, !text.isEmpty else { return }
            let term = text.split(separator: " ").first.map(String.init) ?? text
            self.presentLookup(term: term)
        }

        let translate = UIAction(title: "翻译", image: UIImage(systemName: "translate")) { [weak self] _ in
            guard let self, !text.isEmpty else { return }
            self.onTranslate?(text)
        }

        let webSearch = UIAction(title: "搜索网页", image: UIImage(systemName: "globe")) { _ in
            let query = text.replacingOccurrences(of: "\n", with: " ")
            guard !query.isEmpty,
                  let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://www.bing.com/search?q=" + encoded) else { return }
            UIApplication.shared.open(url)
            DiagLog.log("web search")
        }

        let share = UIAction(title: "共享", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self, !text.isEmpty else { return }
            self.presentShare(text: text, sourcePoint: configuration.sourcePoint)
        }

        return UIMenu(children: [copy, lookup, translate, webSearch, share])
    }
}
