import UIKit
import PencilKit
import PDFKit

/// v0.33.0:连续排布方向。跨页只能沿这个方向搬 —— 横向排布时邻页在左右,没有上下邻页。
enum InkFlowAxis {
    case vertical
    case horizontal
}

/// Pencil 标记层(v0.9.0,M4;v0.14.0 Paper Modern 手写体验重构):
/// - `PencilOverlayProvider` 经 `PDFView.pageOverlayViewProvider` 为**每一页**叠加一个画布容器;
/// - 画布为 `PKCanvasView`(`drawingPolicy = .pencilOnly`),只接受 Pencil;
/// - **选词模式**:容器 `hitTest` 一律返回 nil → 触摸全部穿透给 PDFView,选区逻辑原样;
/// - **标记模式**:容器一律接管命中(返回画布);手指滚动/缩放/长按由祖先手势与 drawingPolicy 保证;
/// - v0.14.0:工具由外部 `PencilToolSession` 驱动(自绘浮动工具带,不再使用系统 PKToolPicker);
/// - 手写数据按 (docSha, page) 存 SQLite(`pencil_ink`),**不改动原 PDF**;停笔 0.8s 防抖落盘。
///
/// 坐标约定:画布尺寸 = 该页 PDF 尺寸(页坐标 pt)。PDFView 会把叠加层随缩放一起变换,
/// 因此手写笔迹在任意缩放档位应对齐。
final class PencilOverlayProvider: NSObject, PDFPageOverlayViewProvider {
    private weak var pdfView: PDFView?
    private let docSha: String
    private let inkStore: PencilInkStore?
    private(set) var markMode: Bool
    private var overlays: [Int: InkOverlayView] = [:]
    /// v0.14.0:当前笔具(新页画布创建时套用;调色盘变化时由协调器 setTool 更新)
    var currentTool: PKTool?
    /// v0.16.0:直尺辅助层状态(对所有页同一口径)
    private(set) var rulerActive = false
    /// v0.32.0:直尺当前挂在哪一页(-1 = 还没算过)。PencilKit 的直尺是**每块画布各带一把**,
    /// 所以只能给视口中心那一页开,否则屏幕上会同时出现好几把。
    private var rulerFocusPage = -1
    /// v0.22.0:自研橡皮配置(active / 整笔 / 半径[画布坐标])
    private var eraserConfig: (active: Bool, whole: Bool, radius: CGFloat) = (false, false, 33)
    /// v0.23.0:激光笔 / 形状工具配置(新页画布创建时继承)
    private var laserActive = false
    private var shapeConfig: (active: Bool, kind: PencilShapeKind, color: UIColor, width: CGFloat) = (false, .line, .label, 2)
    /// v0.28.0:最近一次完整工具状态 —— 新页叠层创建时一次性继承,不再逐个 config 拼装。
    private(set) var modeState = PencilToolState()
    /// v0.28.0:全局湿墨层(形状预览走它,页缝外不再被邻页遮挡)
    weak var wetHost: PencilWetInkHost? {
        didSet {
            for (_, overlay) in overlays { overlay.wetHost = wetHost }
        }
    }
    /// v0.30.0:画布内容已落定(干墨层已接手)—— 协调器可以立刻撤掉湿墨预览,
    /// 避免同一段墨被湿墨多边形和 PencilKit 各画一遍。
    var onInkCommitted: (() -> Void)?
    /// v0.30.0:跨页干墨层 —— 每页墨迹里越过页面矩形的部分由它画在邻页上。
    /// 墨迹归属落笔页,不再切分/搬迁,所以不存在"搬失败导致断笔"。
    weak var dryHost: PencilDryInkHost? {
        didSet {
            guard let dryHost else { return }
            for (index, overlay) in overlays {
                dryHost.update(page: index, drawing: overlay.canvasSnapshot,
                               pageSize: overlay.bounds.size)
            }
        }
    }
    /// v0.14.0:最近落笔的画布(撤销 / 重做目标)
    private weak var activeCanvas: PKCanvasView?

    // MARK: - v0.27.0 统一撤销组(一条记录可跨页)

    private let inkUndo = InkUndoStack()
    /// 正在进行的用户动作:name + 各页「动作前」快照 + 涉及页集合
    private var pendingAction: (name: String, before: [Int: PKDrawing], pages: Set<Int>)?
    private var actionCommitWork: DispatchWorkItem?

    init(pdfView: PDFView?, docSha: String, inkStore: PencilInkStore?, markMode: Bool, tool: PKTool? = nil, rulerActive: Bool = false) {
        self.pdfView = pdfView
        self.docSha = docSha
        self.inkStore = inkStore
        self.markMode = markMode
        self.currentTool = tool
        self.rulerActive = rulerActive
        super.init()
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard !docSha.isEmpty else { return nil }
        let index = view.document?.index(for: page) ?? 0
        let overlay: InkOverlayView
        if let existing = overlays[index] {
            overlay = existing
        } else {
            overlay = InkOverlayView(pageIndex: index, docSha: docSha, inkStore: inkStore, markMode: markMode, tool: currentTool, rulerActive: rulerActive && index == focusedPageIndex)
            overlay.toolProvider = self
            let size = page.bounds(for: view.displayBox).size
            overlay.frame = CGRect(origin: .zero, size: size)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.onCanvasBecameActive = { [weak self] canvas in
                self?.activeCanvas = canvas
            }
            // v0.30.0:画布内容变化 → 干墨跨页层重画"页面矩形之外"的那部分。
            overlay.onDrawingChanged = { [weak self] drawing in
                guard let self, let current = self.overlays[index] else { return }
                self.dryHost?.update(page: index, drawing: drawing, pageSize: current.bounds.size)
                // v0.30.0:干墨层已经拿到这一笔 —— 湿墨预览可以立刻撤(同一段墨不重复画)
                self.onInkCommitted?()
                // v0.32.0:抬笔后把越出页面矩形的段搬到邻页(幂等,搬完就没有越界段了)
                self.scheduleOverflowSettle(page: index)
            }
            // v0.27.0:一次用户动作的开始/结束 → 合成一条（可跨页的）撤销记录
            overlay.onActionBegin = { [weak self] name, before in
                self?.beginInkAction(name: name, page: index, before: before)
            }
            overlay.onActionEnd = { [weak self] in
                self?.scheduleInkActionCommit()
            }
            // v0.28.0:新页画布一次性继承完整工具状态(橡皮/激光/形状/直尺)
            overlay.wetHost = wetHost
            overlay.applyModeState(modeState)
            overlays[index] = overlay
            // v0.30.0:从库里载入的墨可能带页外部分 —— 干墨跨页层立即补上
            dryHost?.update(page: index, drawing: overlay.canvasSnapshot, pageSize: overlay.bounds.size)
            // v0.34.0:载入的墨若越界(跨 3 页以上时中间页会存着越界段),先结算一次
            scheduleOverflowSettle(page: index)
            DiagLog.log("pencil: overlay created page=\(index)")
            // v0.13.3:落位后确保叠层在页内容之上(墨水可见、命中优先)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak overlay] in
                guard let overlay, let host = overlay.superview else { return }
                host.bringSubviewToFront(overlay)
            }
        }
        return overlay
    }

    func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        (overlayView as? InkOverlayView)?.flushSave()
    }

    /// v0.28.0:**同步**套用整份模式状态(直尺/橡皮/激光/形状/预览配置)。
    /// 这一步只改标志位与手势开关,不碰 `PKCanvasView.tool`,所以可以立即执行 ——
    /// 用户选完形状后下一次拖动就是新形状,不必等异步那一段。
    func applyModeState(_ state: PencilToolState) {
        modeState = state
        for (_, overlay) in overlays {
            overlay.applyModeState(state)
        }
    }

    // MARK: - v0.32.0 跨页:抬笔把越界段搬到邻页

    /// 结算调度(等 PencilKit 把这一笔真正并入 drawing 再动它)
    private var overflowWork: DispatchWorkItem?
    /// 防止「切分 → 写回 drawing → 再次触发检查」的递归
    private var settling = false

    func scheduleOverflowSettle(page: Int) {
        guard !settling, let overlay = overlays[page], !overlay.inkPostProcessingSuppressed else { return }
        overflowWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settleOverflow(page: page) }
        overflowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
    }

    /// 当前连续排布方向(纵向 = 上下翻页;横向 = 左右翻页)
    var flowAxis: InkFlowAxis = .vertical

    /// 把这一页里越出页面矩形的笔迹切开:页内段留下,页外段搬到邻页
    /// (邻页还没建叠层就写进它的墨迹库)。
    /// 幂等:搬完之后这一页不再有越界段,重复调用不会再改任何东西。
    func settleOverflow(page: Int) {
        guard !settling, let overlay = overlays[page] else { return }
        let pageSize = overlay.bounds.size
        guard pageSize.width > 1, pageSize.height > 1 else { return }
        let rect = InkGeometry.pageRectInCanvas(pageSize: pageSize)
        var strokes = overlay.canvasSnapshot.strokes
        guard !strokes.isEmpty else { return }

        // v0.33.0:沿排布方向切。横向排布时邻页在左右,按 y 切会把墨搬到"右边那一页"。
        let axis: InkSplitAxis = flowAxis == .vertical ? .y : .x
        let edgeMax: CGFloat = axis == .y ? rect.maxY : rect.maxX
        let edgeMin: CGFloat = axis == .y ? rect.minY : rect.minX

        func beyond(_ s: PKStroke) -> Bool {
            s.path.contains { PencilStrokeTools.value($0, axis) > edgeMax + 0.5 }
        }
        func before(_ s: PKStroke) -> Bool {
            s.path.contains { PencilStrokeTools.value($0, axis) < edgeMin - 0.5 }
        }

        var changed = false
        var rounds = 0
        var touched: Set<Int> = []
        settling = true
        defer { settling = false }

        while rounds < 32 {
            rounds += 1
            guard let idx = strokes.firstIndex(where: { beyond($0) || before($0) }) else { break }
            let stroke = strokes[idx]
            let forward = beyond(stroke)
            let parts = forward
                ? PencilStrokeTools.splitBeyond(stroke, threshold: edgeMax, axis: axis)
                : PencilStrokeTools.splitBefore(stroke, threshold: edgeMin, axis: axis)
            // 前进方向用本页尺寸,后退方向用邻页尺寸(封面/插页尺寸不同时不错位)
            let ownSpan = axis == .y ? pageSize.height : pageSize.width
            let span = forward ? ownSpan : (neighborSpan(page: page - 1, axis: axis) ?? ownSpan)
            let delta = (forward ? -span : span) * InkGeometry.scale
            let guardTarget = forward ? page + 1 : page - 1
            guard parts.outside.count >= 2,
                  let outside = PencilStrokeTools.makeStroke(points: parts.outside, template: stroke),
                  let moved = PencilStrokeTools.shifted(outside,
                                                        dx: axis == .x ? delta : 0,
                                                        dy: axis == .y ? delta : 0),
                  handoff(page: guardTarget, canvasStroke: moved) else {
                DiagLog.log("pencil: overflow \(axis == .y ? "y" : "x")\(forward ? "+" : "-") stuck page=\(page) pts=\(parts.outside.count)")
                break
            }
            touched.insert(guardTarget)   // v0.34.0:邻页若还有越界段,接着往下一页传(3 页以上)
            if parts.inside.count >= 2,
               let inside = PencilStrokeTools.makeStroke(points: parts.inside, template: stroke) {
                strokes[idx] = inside
            } else {
                strokes.remove(at: idx)
            }
            changed = true
            DiagLog.log("pencil: overflow \(axis == .y ? "y" : "x")\(forward ? "+" : "-") page \(page) -> \(forward ? page + 1 : page - 1) pts=\(parts.outside.count)")
        }
        guard changed else { return }
        let settled = PKDrawing(strokes: strokes)
        overlay.applyCanvasSnapshot(settled)
        overlay.flushSave()
        dryHost?.update(page: page, drawing: settled, pageSize: pageSize)

        // v0.34.0:一笔可以跨 3 页以上 —— 邻页收到墨后可能仍然越界。等本次结算收尾
        // (settling 复位)后再结算邻页,否则会被 `guard !settling` 挡掉,墨就卡在中间那页。
        if !touched.isEmpty {
            let pages = touched
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for page in pages.sorted() { self.scheduleOverflowSettle(page: page) }
            }
        }
    }

    /// 邻页在切分轴上的尺寸(叠层没建时问文档)
    private func neighborSpan(page: Int, axis: InkSplitAxis) -> CGFloat? {
        if let overlay = overlays[page] {
            return axis == .y ? overlay.bounds.height : overlay.bounds.width
        }
        guard let pdfView, let document = pdfView.document, page >= 0, page < document.pageCount,
              let target = document.page(at: page) else { return nil }
        let size = target.bounds(for: pdfView.displayBox).size
        return axis == .y ? size.height : size.width
    }

    /// 把一段(源页画布坐标,已平移好)交给目标页
    private func handoff(page target: Int, canvasStroke: PKStroke) -> Bool {
        guard let pdfView, let document = pdfView.document,
              target >= 0, target < document.pageCount,
              let page = document.page(at: target) else { return false }
        if let next = overlays[target] {
            next.canvas.drawing = PKDrawing(strokes: next.canvas.drawing.strokes + [canvasStroke])
            next.flushSave()
            return true
        }
        // PDFKit 只为可见页建叠层:目标页还没叠层时直接写进它的墨迹库(库里是页面坐标)
        return appendToStore(page: target, canvasStroke: canvasStroke, pageSize: page.bounds(for: pdfView.displayBox).size)
    }

    private func appendToStore(page: Int, canvasStroke: PKStroke, pageSize: CGSize) -> Bool {
        guard let inkStore else { return false }
        var drawing = PKDrawing()
        if let record = inkStore.drawing(docSha: docSha, page: page), !record.data.isEmpty,
           var existing = try? PKDrawing(data: record.data) {
            let target = Double(InkGeometry.scale)
            if record.scale > 0.001, abs(record.scale - target) > 0.001 {
                let factor = CGFloat(target / record.scale)
                existing.transform(using: CGAffineTransform(scaleX: factor, y: factor))
            }
            drawing = existing
        }
        var piece = PKDrawing(strokes: [canvasStroke])
        piece.transform(using: InkGeometry.canvasFromPage.inverted())
        drawing = PKDrawing(strokes: drawing.strokes + piece.strokes)
        inkStore.save(docSha: docSha, page: page,
                      data: drawing.dataRepresentation(),
                      scale: Double(InkGeometry.scale))
        return true
    }

    /// v0.14.0:把当前笔具套用到全部页画布(幂等)。
    /// v0.34.0:**设完工具必须重算一次手势状态**。给 `canvas.tool` 赋值会让 PencilKit 重建
    /// 内部手势识别器,把自研橡皮/形状/激光笔的"接管绘制手势"重新打开 —— 真机表现就是
    /// 「选了形状,画出来却是普通笔迹」。
    func setTool(_ tool: PKTool?) {
        currentTool = tool
        guard let tool else { return }
        for (_, overlay) in overlays {
            overlay.canvas.tool = tool
            overlay.refreshGestureState()
        }
    }

    /// v0.16.0:直尺开关同步到所有已创建页画布(新页在创建时继承)。
    /// v0.32.0:只挂视口中心那一页;滚动/缩放/翻页时由 `refreshRulerFocus()` 挪过去。
    func setRulerActive(_ active: Bool) {
        rulerActive = active
        refreshRulerFocus(force: true)
    }

    /// 把直尺挪到当前焦点页(幂等)
    func refreshRulerFocus(force: Bool = false) {
        let focus = focusedPageIndex
        if !force, focus == rulerFocusPage { return }
        rulerFocusPage = focus
        for (index, overlay) in overlays {
            overlay.setRulerActive(rulerActive && index == focus)
        }
    }

    /// 视口中心落在哪一页
    private var focusedPageIndex: Int {
        guard let pdfView, let document = pdfView.document else { return 0 }
        let center = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        guard let page = pdfView.page(for: center, nearest: true) else { return 0 }
        return document.index(for: page)
    }

    /// v0.22.0:自研橡皮配置同步到所有页画布(半径单位 = 画布坐标)
    func setEraserMode(active: Bool, whole: Bool, radius: CGFloat) {
        eraserConfig = (active, whole, radius)
        for (_, overlay) in overlays {
            overlay.setEraserMode(active: active, whole: whole, radius: radius)
        }
    }

    /// v0.23.0:激光笔配置同步到所有页画布(不落墨,只留会淡出的轨迹)
    func setLaserMode(active: Bool) {
        laserActive = active
        for (_, overlay) in overlays {
            overlay.setLaserMode(active)
        }
    }

    /// v0.23.0:形状工具配置同步到所有页画布(颜色/笔宽单位 = 页面点)
    func setShapeMode(active: Bool, kind: PencilShapeKind, color: UIColor, width: CGFloat) {
        shapeConfig = (active, kind, color, width)
        for (_, overlay) in overlays {
            overlay.setShapeMode(active: active, kind: kind, color: color, width: width)
        }
    }

    /// v0.23.0:清空某页手写(缩略图/菜单的「清空本页」)
    func clearInk(pageIndex: Int) -> Bool {
        guard let overlay = overlays[pageIndex] else { return false }
        overlay.clearInk()
        return true
    }

    // MARK: - v0.27.0 统一撤销组

    /// 某页当前画面的值快照(`PKDrawing` 是写时复制,取快照几乎零成本;叠层不存在时从墨迹库读)
    private func snapshotDrawing(page: Int) -> PKDrawing {
        if let overlay = overlays[page] { return overlay.canvasSnapshot }
        guard let record = inkStore?.drawing(docSha: docSha, page: page), !record.data.isEmpty,
              var drawing = try? PKDrawing(data: record.data) else {
            return PKDrawing()
        }
        let target = Double(InkGeometry.scale)
        if record.scale > 0.001, abs(record.scale - target) > 0.001 {
            let factor = CGFloat(target / record.scale)
            drawing.transform(using: CGAffineTransform(scaleX: factor, y: factor))
        }
        // 库里是页面坐标,画布坐标还差一个左上出血偏移
        drawing.transform(using: InkGeometry.canvasFromPage)
        return drawing
    }

    /// 动作开始:记下这一页「动作前」的样子。若上一个动作还没落定,先把它关掉。
    private func beginInkAction(name: String, page: Int, before: PKDrawing?) {
        if pendingAction != nil { commitInkActionNow() }
        let snapshot = before ?? snapshotDrawing(page: page)
        pendingAction = (name: name, before: [page: snapshot], pages: [page])
        scheduleInkActionCommit()
    }

    /// 这个动作接下来要动到哪些页(必须在改动之前调用,才能拿到正确的"动作前"快照)
    private func notePagesInAction(_ pages: [Int]) {
        guard var action = pendingAction else { return }
        for page in pages where page >= 0 {
            if action.before[page] == nil {
                action.before[page] = snapshotDrawing(page: page)
            }
            action.pages.insert(page)
        }
        pendingAction = action
    }

    private func scheduleInkActionCommit() {
        actionCommitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitInkActionNow() }
        actionCommitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// 动作结束:把涉及的所有页「动作后」的快照一起收进**一条**记录
    /// (跨页书写因此只需要撤销一次)。等 0.35s 是为了让直线吸附先完成。
    private func commitInkActionNow() {
        actionCommitWork?.cancel()
        actionCommitWork = nil
        guard let action = pendingAction else { return }
        pendingAction = nil
        var after: [Int: PKDrawing] = [:]
        for page in action.pages {
            after[page] = snapshotDrawing(page: page)
        }
        let entry = InkUndoEntry(name: action.name, before: action.before, after: after)
        guard !entry.isEmpty else { return }
        inkUndo.push(entry)
        DiagLog.log("pencil: undo push \(action.name) pages=\(action.pages.sorted()) depth=\(inkUndo.undoDepth)")
    }

    private func applyInkSnapshots(_ snapshots: [Int: PKDrawing]) {
        for (page, drawing) in snapshots {
            if let overlay = overlays[page] {
                overlay.suppressInkPostProcessing(for: 0.8)
                overlay.applyCanvasSnapshot(drawing)
                overlay.flushSave()
            } else {
                var stored = drawing
                stored.transform(using: InkGeometry.pageFromCanvas)
                inkStore?.save(
                    docSha: docSha,
                    page: page,
                    data: stored.dataRepresentation(),
                    scale: Double(InkGeometry.scale)
                )
            }
        }
    }

    /// 撤销:优先走统一栈(可跨页);栈空时退回 PencilKit 自带栈(兼容老记录)。
    /// v0.16.2:记录笔画数变化 —— 真机日志里出现过「30 笔 → 一次保存 10 笔」的整页回退。
    func undo() {
        commitInkActionNow()
        if let entry = inkUndo.popUndo() {
            applyInkSnapshots(entry.before)
            inkUndo.pushRedo(entry)
            DiagLog.log("pencil: undo \(entry.name) pages=\(entry.before.keys.sorted()) depth=\(inkUndo.undoDepth)")
            return
        }
        guard let canvas = activeCanvas ?? overlays.values.first?.canvas else {
            DiagLog.log("pencil: undo ignored (no canvas)")
            return
        }
        let before = canvas.drawing.strokes.count
        canvas.becomeFirstResponder()
        canvas.undoManager?.undo()
        DiagLog.log("pencil: undo (legacy) \(before) -> \(canvas.drawing.strokes.count) strokes")
    }

    func redo() {
        if let entry = inkUndo.popRedo() {
            applyInkSnapshots(entry.after)
            inkUndo.pushUndoBack(entry)
            DiagLog.log("pencil: redo \(entry.name) pages=\(entry.after.keys.sorted()) depth=\(inkUndo.redoDepth)")
            return
        }
        guard let canvas = activeCanvas ?? overlays.values.first?.canvas else {
            DiagLog.log("pencil: redo ignored (no canvas)")
            return
        }
        let before = canvas.drawing.strokes.count
        canvas.becomeFirstResponder()
        canvas.undoManager?.redo()
        DiagLog.log("pencil: redo (legacy) \(before) -> \(canvas.drawing.strokes.count) strokes")
    }

    func setMarkMode(_ on: Bool) {
        markMode = on
        for (_, overlay) in overlays {
            overlay.setMarking(on)
        }
    }

    func flushAll() {
        // v0.27.0:收尾前先把未落定的动作收进撤销栈,避免"最后一笔撤不掉"
        commitInkActionNow()
        for (_, overlay) in overlays {
            overlay.flushSave()
        }
    }
}

/// 单页画布容器:透明,内含铺满的 PKCanvasView;触摸过滤规则见文件头注释。
final class InkOverlayView: UIView, PKCanvasViewDelegate {
    private let pageIndex: Int
    private let docSha: String
    private let inkStore: PencilInkStore?
    let canvas = PKCanvasView()
    /// v0.14.0:落笔通知(协调器记录撤销目标)
    var onCanvasBecameActive: ((PKCanvasView) -> Void)?
    /// v0.32.0:画布激活时向 provider 要一次当前工具 —— 兜住创建/复用/层级重建漏套的情况
    weak var toolProvider: PencilOverlayProvider?
    /// v0.30.0:画布内容变化(落笔/擦除/撤销/清空/吸附)→ provider 同步干墨跨页层。
    var onDrawingChanged: ((PKDrawing) -> Void)?
    /// v0.27.0:一次用户动作(落笔/橡皮/形状/清空)的开始与结束 —— provider 用它把
    /// 涉及到的页合成**一条**撤销记录。
    var onActionBegin: ((String, PKDrawing?) -> Void)?
    var onActionEnd: (() -> Void)?

    // MARK: - v0.22.0 自研橡皮(可调大小 / 局部擦除)

    private let eraserPan = UIPanGestureRecognizer()
    private var eraserActive = false
    private var eraserWhole = false
    private var eraserRadiusCanvas: CGFloat = 33
    private var eraseUndoSnapshot: PKDrawing?
    private var lastErasePoint: CGPoint?
    private var lastEraseAt: CFAbsoluteTime = 0

    // MARK: - v0.23.0 激光笔 / 形状工具(同一支自研手势,按模式分派)

    private var laserActive = false
    private var laserLayer: CAShapeLayer?
    private var laserPoints: [CGPoint] = []
    private var shapeActive = false
    private var shapeKind: PencilShapeKind = .line
    private var shapeColor: UIColor = .label
    private var shapeWidth: CGFloat = 2.0
    private var shapePreviewLayer: CAShapeLayer?
    private var shapeStartCanvas: CGPoint?
    private var shapeUndoSnapshot: PKDrawing?

    // MARK: - v0.28.0 全局湿墨层

    /// v0.28.0:全局湿墨层(由 provider 注入)。形状预览画在这里,跨页时不被邻页遮住。
    weak var wetHost: PencilWetInkHost?
    /// v0.25.1:后处理(直线吸附)的调度状态,见 `schedulePostProcess`
    private var postProcessWork: DispatchWorkItem?
    /// v0.24.0:本次动作新增笔迹的起始下标(吸附用)
    private var pendingPostProcessStart: Int?
    /// v0.27.0:在这个时刻之前,不做直线吸附(撤销装回快照后要静一会儿)
    private var postProcessSuppressUntil: CFAbsoluteTime = 0
    /// v0.28.0:PencilKit 正在书写时不做后处理
    private var strokeInProgress = false

    private var marking = false
    private var loaded = false
    private var saveWork: DispatchWorkItem?
    private var lastLoggedSize = CGSize.zero
    /// v0.24.0:本次落笔开始时已有的笔数(= 新笔在 drawing 里的下标)。
    /// 以前靠 `creationDate` 的 3 秒窗口判断"刚刚画完的一笔" —— 慢慢写超过 3 秒的长笔
    /// 会漏吸附(直线拉直不生效)。
    private var strokeIndexAtBegin: Int?
    /// v0.13.3:命中诊断日志节流(1s 一次)
    private var lastHitLog: CFAbsoluteTime = 0

    init(pageIndex: Int, docSha: String, inkStore: PencilInkStore?, markMode: Bool, tool: PKTool?, rulerActive: Bool) {
        self.pageIndex = pageIndex
        self.docSha = docSha
        self.inkStore = inkStore
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        // v0.26.0:允许画布把「出血区」里的墨迹画到页面之外 —— 跨页书写时笔迹不会在
        // 页边突然消失再跳到下一页,而是连续地越过页缝。命中判定仍按本页 bounds,
        // 所以不会抢走邻页的触摸。
        clipsToBounds = false

        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // v0.25.0:纸面永远是白纸,墨水就永远是真正的黑 —— 深色模式下 PencilKit 会按
        // 外观给墨色做"适配"(黑笔看起来发灰、看不清)。把画布钉在浅色外观里,墨色不再漂移。
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = self
        // v0.14.0:工具由外部会话驱动(保底黑笔);绘制手势只收 Pencil(公开属性第二道闸)
        canvas.tool = tool ?? PKInkingTool(.pen, color: .black, width: 2.5 * InkGeometry.scale)
        canvas.isRulerActive = rulerActive
        canvas.drawingGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        // v0.17.0:高清书写 —— 画布 bounds = 页面 ×3,再用 1/3 变换压回页面大小;
        // 栅格化密度随画布尺寸提高,屏幕放大时不再糊。约束改为 layoutSubviews 手工布局。
        canvas.translatesAutoresizingMaskIntoConstraints = true
        canvas.layer.anchorPoint = .zero
        canvas.layer.position = .zero
        canvas.transform = InkGeometry.inverseTransform
        canvas.bounds = CGRect(origin: .zero, size: InkGeometry.canvasSize(for: CGSize(width: 1, height: 1)))
        addSubview(canvas)

        // v0.22.0:自研橡皮手势(只收 Pencil;橡皮激活时接管绘制手势)
        eraserPan.addTarget(self, action: #selector(handleToolPan(_:)))
        eraserPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        eraserPan.maximumNumberOfTouches = 1
        eraserPan.isEnabled = false
        canvas.addGestureRecognizer(eraserPan)

        loadInk()
        marking = markMode
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 触摸过滤(模式)

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 选词模式:整体穿透(手指与 Pencil 都交给 PDFView 的选区管线)
        guard marking else { return nil }
        // v0.13.3(关键修复):标记模式**一律由本层接管**(返回画布),不再依赖 event 里能否
        // 看到 Pencil——命中判定的时机不可靠(首次 hitTest 时 allTouches 可能缺失/不含笔),
        // 一旦漏判 Pencil 就落空,真机表现 =「画不出字」。
        // 手指各项能力都不依赖命中目标,全部由祖先机制保证、照常工作:
        //   · 手指滚动 / 双指缩放:PDFView 滚动视图的 pan / pinch(祖先手势)照常收到触摸;
        //   · 手指永不落墨:PKCanvasView.drawingPolicy = .pencilOnly(在画布内过滤);
        //   · 长按选词:自定义长按手势挂在 pdfView(祖先),不受命中目标影响。
        let target = super.hitTest(point, with: event)
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastHitLog > 1.0 {
            lastHitLog = now
            let types = (event?.allTouches ?? []).map { String($0.type.rawValue) }.sorted().joined(separator: ",")
            DiagLog.log("pencil: hitTest page=\(pageIndex) touchTypes=[\(types)] -> \(target.map { String(describing: type(of: $0)) } ?? "nil")")
        }
        return target
    }

    // MARK: - 模式切换

    /// v0.16.0:同步直尺辅助层;PencilKit 会在画布上绘制可拖动的直尺。
    /// v0.16.1:不再在这里抢 first responder —— 多页画布会互相顶掉(卡死风险),
    /// 标记模式激活时画布本来就会 becomeFirstResponder。
    func setRulerActive(_ active: Bool) {
        guard canvas.isRulerActive != active else { return }
        canvas.isRulerActive = active
    }

    func setMarking(_ on: Bool) {
        guard marking != on else { return }
        marking = on
        applyToolGestureState()
        if on {
            activateMarking()
        } else {
            if canvas.isFirstResponder { canvas.resignFirstResponder() }
            flushSave()
        }
        DiagLog.log("pencil: page \(pageIndex) marking=\(on)")
        NSLog("[yuewen/pencil] overlay page=%d marking=%d", pageIndex, on ? 1 : 0)
    }

    /// v0.22.0:自研橡皮开关 —— 橡皮激活时关掉 PencilKit 的绘制手势,交给 eraserPan
    func setEraserMode(active: Bool, whole: Bool, radius: CGFloat) {
        eraserActive = active
        eraserWhole = whole
        eraserRadiusCanvas = max(radius, 2)
        applyToolGestureState()
        DiagLog.log("pencil: page \(pageIndex) eraser=\(active ? 1 : 0) whole=\(whole ? 1 : 0) r=\(Int(radius))")
    }

    /// v0.23.0:激光笔 —— 不落墨,只在画面上留一条会淡出的红色轨迹
    func setLaserMode(_ active: Bool) {
        laserActive = active
        applyToolGestureState()
        if !active {
            laserLayer?.removeFromSuperlayer()
            laserLayer = nil
            laserPoints = []
        }
        DiagLog.log("pencil: page \(pageIndex) laser=\(active ? 1 : 0)")
    }

    /// v0.23.0:形状工具 —— 拖动生成规整的直线/矩形/椭圆/箭头,写入当前页画布
    func setShapeMode(active: Bool, kind: PencilShapeKind, color: UIColor, width: CGFloat) {
        shapeActive = active
        shapeKind = kind
        shapeColor = color
        shapeWidth = max(width, 0.8)
        applyToolGestureState()
        if !active {
            shapePreviewLayer?.removeFromSuperlayer()
            shapePreviewLayer = nil
            shapeStartCanvas = nil
            shapeUndoSnapshot = nil
        }
        DiagLog.log("pencil: page \(pageIndex) shape=\(active ? 1 : 0) kind=\(kind.rawValue)")
    }

    private func applyToolGestureState() {
        let custom = (eraserActive || laserActive || shapeActive) && marking
        canvas.drawingGestureRecognizer.isEnabled = !custom
        eraserPan.isEnabled = custom
        if custom {
            // 自研工具接管绘制手势,PencilKit 不会再有"进行中的一笔"。
            strokeInProgress = false
        } else {
            lastErasePoint = nil
            eraseUndoSnapshot = nil
        }
    }

    /// v0.34.0:外部(provider.setTool)赋完 `canvas.tool` 后调用 —— PencilKit 重建手势时
    /// 会把绘制手势重新打开,自研橡皮/形状/激光笔必须再接管一次。
    func refreshGestureState() {
        applyToolGestureState()
    }

    /// v0.28.0:一次装填整份模式状态。与逐项 setXxxMode 的差别是:
    /// 只算一次手势状态、只打一行日志,并且形状参数在**同一次调用**里就位。
    func applyModeState(_ state: PencilToolState) {
        let wasLaser = laserActive
        let wasShape = shapeActive
        // v0.32.0:直尺**不在这里设**。PencilKit 的直尺是每块画布各带一把,
        // 只能由 provider 的 `refreshRulerFocus()` 挂到视口焦点页;
        // 这里对所有页都设 true 就是"屏幕上出现好几把尺子"的原因。
        eraserActive = state.kind == .eraser && state.useCustomEraser
        eraserWhole = state.eraserWhole
        eraserRadiusCanvas = max(state.eraserRadius * InkGeometry.scale, 2)
        laserActive = state.kind == .laser
        shapeActive = state.kind == .shape
        shapeKind = state.shapeKind
        shapeColor = state.currentUIColor
        shapeWidth = max(state.width, 0.8)

        if wasLaser && !laserActive {
            laserLayer?.removeFromSuperlayer()
            laserLayer = nil
            laserPoints = []
        }
        if wasShape && !shapeActive {
            shapePreviewLayer?.removeFromSuperlayer()
            shapePreviewLayer = nil
            shapeStartCanvas = nil
            shapeUndoSnapshot = nil
            wetHost?.clear()
        }
        applyToolGestureState()
        DiagLog.log("pencil: page \(pageIndex) mode applied kind=\(state.kind.rawValue) shape=\(state.shapeKind.rawValue) eraser=\(eraserActive ? 1 : 0) laser=\(laserActive ? 1 : 0)")
    }

    // MARK: - 自研工具手势(橡皮 / 激光笔 / 形状共用一个 pan)

    @objc private func handleToolPan(_ gesture: UIPanGestureRecognizer) {
        guard marking else { return }
        if laserActive {
            handleLaserGesture(gesture)
            return
        }
        if shapeActive {
            handleShapeGesture(gesture)
            return
        }
        guard eraserActive else { return }
        handleEraseGesture(gesture)
    }

    // MARK: - 自研橡皮:按点擦除 / 整笔擦除

    private func handleEraseGesture(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: canvas)
        switch gesture.state {
        case .began:
            eraseUndoSnapshot = canvas.drawing
            onActionBegin?("橡皮", canvasSnapshot)
            lastErasePoint = point
            lastEraseAt = 0
            eraseSegment(from: point, to: point)
            if let undo = canvas.undoManager, let snapshot = eraseUndoSnapshot {
                undo.registerUndo(withTarget: self) { target in
                    target.canvas.drawing = snapshot
                }
            }
        case .changed:
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastEraseAt >= 0.012 else { return }
            lastEraseAt = now
            let from = lastErasePoint ?? point
            eraseSegment(from: from, to: point)
            lastErasePoint = point
        case .ended, .cancelled, .failed:
            if let from = lastErasePoint {
                eraseSegment(from: from, to: point)
            }
            lastErasePoint = nil
            eraseUndoSnapshot = nil
            flushSave()
            onActionEnd?()
        default:
            break
        }
    }

    private func eraseSegment(from: CGPoint, to: CGPoint) {
        let radius = eraserRadiusCanvas
        let box = CGRect(
            x: min(from.x, to.x) - radius,
            y: min(from.y, to.y) - radius,
            width: abs(to.x - from.x) + radius * 2,
            height: abs(to.y - from.y) + radius * 2
        )

        // 整笔擦除按 `creationDate` 分组:同一笔被切分/部分擦除后仍共享同一个创建时间,
        // 擦到任意一段就把整笔一起删掉,而不是只少一段。
        if eraserWhole {
            var groups: [Date] = []
            for stroke in canvas.drawing.strokes {
                guard stroke.renderBounds.insetBy(dx: -radius, dy: -radius).intersects(box) else { continue }
                if strokeIntersects(stroke, from: from, to: to, radius: radius) {
                    groups.append(stroke.path.creationDate)
                }
            }
            guard !groups.isEmpty else { return }
            let kept = canvas.drawing.strokes.filter { stroke in
                !groups.contains { abs($0.timeIntervalSince(stroke.path.creationDate)) < 0.0005 }
            }
            guard kept.count != canvas.drawing.strokes.count else { return }
            canvas.drawing = PKDrawing(strokes: kept)
            notifyDrawingChanged()
            return
        }

        var changed = false
        var result: [PKStroke] = []
        result.reserveCapacity(canvas.drawing.strokes.count)
        for stroke in canvas.drawing.strokes {
            guard stroke.renderBounds.insetBy(dx: -radius, dy: -radius).intersects(box) else {
                result.append(stroke)
                continue
            }
            let runs = remainingRuns(of: stroke, from: from, to: to, radius: radius)
            if runs.isEmpty {
                changed = true
            } else if runs.count == 1, runs[0].count == stroke.path.count {
                result.append(stroke)
            } else {
                changed = true
                for run in runs where run.count >= 2 {
                    if let piece = PencilStrokeTools.makeStroke(
                        points: run, template: stroke, creationDate: stroke.path.creationDate
                    ) {
                        result.append(piece)
                    }
                }
            }
        }
        guard changed else { return }
        canvas.drawing = PKDrawing(strokes: result)
        notifyDrawingChanged()
    }

    private func strokeIntersects(_ stroke: PKStroke, from: CGPoint, to: CGPoint, radius: CGFloat) -> Bool {
        for point in stroke.path where distanceToSegment(point.location, from, to) < radius {
            return true
        }
        return false
    }

    /// 返回未被擦到的连续点段(每段 ≥ 2 点才能重建一笔)
    private func remainingRuns(of stroke: PKStroke, from: CGPoint, to: CGPoint, radius: CGFloat) -> [[PKStrokePoint]] {
        var runs: [[PKStrokePoint]] = []
        var current: [PKStrokePoint] = []
        for point in stroke.path {
            if distanceToSegment(point.location, from, to) < radius {
                if current.count >= 2 { runs.append(current) }
                current = []
            } else {
                current.append(point)
            }
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared < 0.0001 {
            return hypot(p.x - a.x, p.y - a.y)
        }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        let projected = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - projected.x, p.y - projected.y)
    }

    // MARK: - 激光笔

    private func handleLaserGesture(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)   // 页面坐标(容器)
        switch gesture.state {
        case .began:
            laserPoints = [point]
            let layer = CAShapeLayer()
            layer.strokeColor = UIColor.systemRed.cgColor
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 4
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.shadowColor = UIColor.systemRed.cgColor
            layer.shadowRadius = 5
            layer.shadowOpacity = 0.7
            layer.shadowOffset = .zero
            self.layer.addSublayer(layer)
            laserLayer = layer
            updateLaserPath()
        case .changed:
            laserPoints.append(point)
            if laserPoints.count > 256 { laserPoints.removeFirst(laserPoints.count - 256) }
            updateLaserPath()
        case .ended, .cancelled, .failed:
            let layer = laserLayer
            laserLayer = nil
            laserPoints = []
            UIView.animate(withDuration: 0.5, delay: 0.12, options: [.curveEaseOut]) {
                layer?.opacity = 0
            } completion: { _ in
                layer?.removeFromSuperlayer()
            }
        default:
            break
        }
    }

    private func updateLaserPath() {
        guard let layer = laserLayer, let first = laserPoints.first else { return }
        if laserPoints.count < 2 {
            layer.path = UIBezierPath(ovalIn: CGRect(x: first.x - 2.5, y: first.y - 2.5, width: 5, height: 5)).cgPath
            return
        }
        let path = UIBezierPath()
        path.move(to: first)
        for point in laserPoints.dropFirst() { path.addLine(to: point) }
        layer.path = path.cgPath
    }

    // MARK: - 形状工具

    private func handleShapeGesture(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: canvas)
        switch gesture.state {
        case .began:
            shapeUndoSnapshot = canvas.drawing
            onActionBegin?("形状", canvasSnapshot)
            shapeStartCanvas = point
            updateShapePreview(from: point, to: point)
        case .changed:
            guard let start = shapeStartCanvas else { return }
            updateShapePreview(from: start, to: point)
        case .ended, .cancelled, .failed:
            let start = shapeStartCanvas
            shapeStartCanvas = nil
            shapePreviewLayer?.removeFromSuperlayer()
            shapePreviewLayer = nil
            wetHost?.clear()
            guard let start else { return }
            commitShape(from: start, to: point)
            onActionEnd?()
        default:
            break
        }
    }

    private func updateShapePreview(from: CGPoint, to: CGPoint) {
        let layer: CAShapeLayer
        if let existing = shapePreviewLayer {
            layer = existing
        } else {
            let created = CAShapeLayer()
            created.strokeColor = UIColor.systemBlue.withAlphaComponent(0.9).cgColor
            created.fillColor = UIColor.clear.cgColor
            created.lineWidth = 1.5
            created.lineDashPattern = [5, 4]
            self.layer.addSublayer(created)
            shapePreviewLayer = created
            layer = created
        }
        let path = UIBezierPath()
        let a = pagePoint(fromCanvas: from)
        let b = pagePoint(fromCanvas: to)
        switch shapeKind {
        case .line:
            path.move(to: a)
            path.addLine(to: b)
        case .rect:
            path.append(UIBezierPath(rect: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))))
        case .ellipse:
            path.append(UIBezierPath(ovalIn: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))))
        case .arrow:
            path.move(to: a)
            path.addLine(to: b)
            for head in arrowHeadPoints(from: a, to: b) {
                path.move(to: b)
                path.addLine(to: head)
            }
        }
        // v0.28.0:形状预览同样走全局湿墨层,跨页时不会被邻页遮住。
        if let wetHost {
            wetHost.show(PencilWetStroke(
                pageIndex: pageIndex,
                path: path,
                color: UIColor.systemBlue.withAlphaComponent(0.9),
                lineWidth: 1.5,
                filled: false,
                clipOutsidePage: false,
                dashed: true
            ))
        } else {
            layer.path = path.cgPath
        }
    }

    private func commitShape(from: CGPoint, to: CGPoint) {
        let points = shapeStrokePoints(from: from, to: to)
        guard points.count >= 2 else {
            DiagLog.log("pencil: shape skipped (too small)")
            return
        }
        let ink = PKInk(.pen, color: shapeColor)
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: ink, path: path, transform: .identity, mask: nil)
        canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [stroke])
        if let undo = canvas.undoManager, let snapshot = shapeUndoSnapshot {
            undo.registerUndo(withTarget: self) { target in
                target.canvas.drawing = snapshot
            }
        }
        shapeUndoSnapshot = nil
        flushSave()
        // v0.30.0:形状越过页边的那部分由干墨跨页层直接画出来,不需要切分/搬迁。
        notifyDrawingChanged()
        DiagLog.log("pencil: shape \(shapeKind.rawValue) committed points=\(points.count)")
    }

    private func pagePoint(fromCanvas p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - InkGeometry.pageLeftX()) / InkGeometry.scale,
                y: (p.y - InkGeometry.pageTopY()) / InkGeometry.scale)
    }

    private func shapeStrokePoints(from a: CGPoint, to b: CGPoint) -> [PKStrokePoint] {
        let pageA = pagePoint(fromCanvas: a)
        let pageB = pagePoint(fromCanvas: b)
        var locations: [CGPoint] = []
        let step: CGFloat = 3

        func sample(_ p0: CGPoint, _ p1: CGPoint) {
            let length = hypot(p1.x - p0.x, p1.y - p0.y)
            let count = max(Int(length / step), 2)
            for i in 0...count {
                let t = CGFloat(i) / CGFloat(count)
                locations.append(CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t))
            }
        }

        switch shapeKind {
        case .line:
            sample(pageA, pageB)
        case .rect:
            let rect = CGRect(x: min(pageA.x, pageB.x), y: min(pageA.y, pageB.y),
                              width: abs(pageB.x - pageA.x), height: abs(pageB.y - pageA.y))
            let corners = [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.minY)
            ]
            for i in 0..<4 { sample(corners[i], corners[i + 1]) }
        case .ellipse:
            let rect = CGRect(x: min(pageA.x, pageB.x), y: min(pageA.y, pageB.y),
                              width: abs(pageB.x - pageA.x), height: abs(pageB.y - pageA.y))
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let rx = rect.width / 2, ry = rect.height / 2
            let count = 96
            for i in 0...count {
                let angle = CGFloat(i) / CGFloat(count) * .pi * 2
                locations.append(CGPoint(x: center.x + cos(angle) * rx, y: center.y + sin(angle) * ry))
            }
        case .arrow:
            sample(pageA, pageB)
            for head in arrowHeadPoints(from: pageA, to: pageB) { sample(pageB, head) }
        }

        let width = max(shapeWidth, 0.8)
        return locations.enumerated().map { index, location in
            PKStrokePoint(
                location: CGPoint(x: location.x * InkGeometry.scale + InkGeometry.pageLeftX(),
                                  y: location.y * InkGeometry.scale + InkGeometry.pageTopY()),
                timeOffset: TimeInterval(index) * 0.004,
                size: CGSize(width: width * InkGeometry.scale, height: width * InkGeometry.scale),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2,
                secondaryScale: 1
            )
        }
    }

    private func arrowHeadPoints(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let length = max(hypot(b.x - a.x, b.y - a.y), 1)
        let headLength = min(max(length * 0.18, 8), 28)
        let spread = CGFloat.pi / 7
        return [
            CGPoint(x: b.x - cos(angle - spread) * headLength, y: b.y - sin(angle - spread) * headLength),
            CGPoint(x: b.x - cos(angle + spread) * headLength, y: b.y - sin(angle + spread) * headLength)
        ]
    }

    private func activateMarking() {
        guard window != nil else { return }
        superview?.bringSubviewToFront(self)   // v0.13.3:确保叠层在最上方(墨水可见、命中优先)
        // v0.32.0:进入书写时向 provider 取一次当前笔具,保证「选中什么笔就画什么笔」
        if let tool = toolProvider?.currentTool { canvas.tool = tool }
        canvas.becomeFirstResponder()
        DiagLog.log("pencil: activate page=\(pageIndex) size=\(Int(bounds.width))x\(Int(bounds.height)) super=\(superview.map { String(describing: type(of: $0)) } ?? "-")")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, marking {
            activateMarking()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // v0.17.0:画布始终是页面 ×InkGeometry.scale,再压回页面大小
        // v0.20.0:高度额外加 bleed,让笔尖可以越过页底继续写(抬笔后切到下一页)
        // v0.23.2:顶部也加 bleedTop,支持从下一页往回写到上一页
        let target = InkGeometry.canvasBounds(for: bounds.size)
        if target.width > 1, canvas.bounds != target {
            canvas.bounds = target
            // 页面顶部 = 画布 y bleedTop×scale:画布整体上移 bleedTop,内容坐标不用迁移
            canvas.layer.position = InkGeometry.canvasOrigin
            canvas.transform = InkGeometry.inverseTransform
            canvas.contentSize = target.size
        }
        // 诊断:叠加层尺寸(真机核对"是否随缩放变换"的关键一行)
        if bounds.size != lastLoggedSize, bounds.width > 1 {
            lastLoggedSize = bounds.size
            DiagLog.log("pencil: page \(pageIndex) overlay \(Int(bounds.width))x\(Int(bounds.height)) canvas \(Int(target.width))x\(Int(target.height))")
        }
    }

    // MARK: - 存取(防抖 0.8s;停笔/翻页/收尾落盘)

    private func loadInk() {
        defer { loaded = true }
        guard let record = inkStore?.drawing(docSha: docSha, page: pageIndex), !record.data.isEmpty else { return }
        guard var drawing = try? PKDrawing(data: record.data) else { return }
        // v0.17.0:老数据(scale=1)按当前超采样倍数放大并回写,避免每次打开重算
        let target = Double(InkGeometry.scale)
        if record.scale > 0.001, abs(record.scale - target) > 0.001 {
            let factor = CGFloat(target / record.scale)
            drawing.transform(using: CGAffineTransform(scaleX: factor, y: factor))
            inkStore?.save(
                docSha: docSha,
                page: pageIndex,
                data: drawing.dataRepresentation(),
                scale: target
            )
            DiagLog.log("pencil: page \(pageIndex) ink migrated \(record.scale)x -> \(Int(target))x")
        }
        // v0.23.2:存储坐标 = 页面坐标(无四周出血);画布左上角外扩,载入时整体内移
        drawing.transform(using: InkGeometry.canvasFromPage)
        canvas.drawing = drawing
        DiagLog.log("pencil: page \(pageIndex) ink loaded \(canvas.drawing.strokes.count) strokes (scale \(Int(target))x)")
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        scheduleSave()
        // v0.30.0:内容一变就同步干墨跨页层 —— 抬笔瞬间页外那段立即由它接上,
        // 不再等"切分 + 搬邻页"。
        notifyDrawingChanged()
        schedulePostProcess()
    }

    // v0.14.0:落笔回调(撤销目标)+ 真机诊断
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        strokeInProgress = true
        onCanvasBecameActive?(canvasView)
        // v0.27.0:动作开始 —— 此刻 drawing 还不含这一笔,正好是"之前"的快照
        onActionBegin?("笔画", canvasSnapshot)
        // v0.24.0:记下本次落笔的下标 —— 抬笔后精确处理"这一笔",不再靠 creationDate 的 3 秒窗口
        strokeIndexAtBegin = canvasView.drawing.strokes.count
        DiagLog.log("pencil: tool BEGIN page=\(pageIndex) strokes=\(canvasView.drawing.strokes.count)")
        NSLog("[yuewen/pencil] tool begin page=%d", pageIndex)
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        strokeInProgress = false
        DiagLog.log("pencil: tool END page=\(pageIndex) strokes=\(canvasView.drawing.strokes.count)")
        NSLog("[yuewen/pencil] tool end page=%d strokes=%d", pageIndex, canvasView.drawing.strokes.count)
        let beginIndex = strokeIndexAtBegin
        strokeIndexAtBegin = nil
        // v0.25.1:PencilKit 是在本代理**返回之后**才把这一笔并进 `canvas.drawing` 的,
        // 所以直线吸附要延后一拍,由 `drawingDidChange` / 0.10s 兜底触发。
        pendingPostProcessStart = beginIndex
        schedulePostProcess()
        // v0.27.0:动作结束(真正入栈要等吸附完成后再拍"之后"的快照)
        onActionEnd?()
    }

    /// 后处理(直线吸附)的防抖调度:同一笔在 drawing 更新前后可能被触发多次,只保留最后一次。
    private func schedulePostProcess() {
        // v0.27.0:撤销/重做装回快照后短时间内不做后处理
        guard CFAbsoluteTimeGetCurrent() >= postProcessSuppressUntil else { return }
        guard !strokeInProgress else { return }
        postProcessWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let start = self.pendingPostProcessStart
            self.pendingPostProcessStart = nil
            self.snapStraightIfNeeded(at: start)
            self.logIfInkHitCanvasEdge()
        }
        postProcessWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
    }

    /// v0.30.0:墨迹顶到画布边界 = 超出出血区,再写就会被裁掉。只用于诊断日志。
    private func logIfInkHitCanvasEdge() {
        guard let last = canvas.drawing.strokes.last, bounds.width > 1 else { return }
        if InkGeometry.touchesCanvasEdge(last, pageSize: bounds.size) {
            DiagLog.log("pencil: page \(pageIndex) stroke hit canvas edge (bleed exhausted) — 墨迹已被画布边界裁掉")
        }
    }

    /// v0.21.0:直线吸附 —— 一笔画得足够直(长 > 60 页面点、最大偏差 < 2%)时拉成直线。
    /// 只处理刚刚画完的那一笔;手写字母通常长度不够,不会被误伤。
    /// v0.24.0:按"本次落笔下标"定位,不再用 creationDate 的 3 秒窗口(慢写长笔会被漏掉)。
    private func snapStraightIfNeeded(at index: Int?) {
        let enabled = (UserDefaults.standard.object(forKey: "pencilLineSnap") as? Bool) ?? true
        guard enabled else { return }
        let strokes = canvas.drawing.strokes
        let fallback: Int? = strokes.isEmpty ? nil : strokes.count - 1
        guard let idx = index ?? fallback, idx < strokes.count else { return }
        let target = strokes[idx]
        guard target.path.count >= 4 else { return }
        let points = Array(target.path)
        guard let first = points.first, let lastPoint = points.last else { return }
        let start = first.location
        let end = lastPoint.location
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 60 * InkGeometry.scale else { return }
        var maxDeviation: CGFloat = 0
        for point in points {
            let deviation = abs(dy * (point.location.x - start.x) - dx * (point.location.y - start.y)) / length
            maxDeviation = max(maxDeviation, deviation)
        }
        let tolerance = max(1.2 * InkGeometry.scale, length * 0.02)
        guard maxDeviation < tolerance else { return }
        guard let snapped = PencilStrokeTools.makeStroke(
            points: [first, lastPoint], template: target, creationDate: target.path.creationDate
        ) else { return }
        var updated = strokes
        updated[idx] = snapped
        canvas.drawing = PKDrawing(strokes: updated)
        notifyDrawingChanged()
        DiagLog.log("pencil: line snap page \(pageIndex) len=\(Int(length / InkGeometry.scale))pt dev=\(String(format: "%.1f", maxDeviation / InkGeometry.scale))pt")
    }


    /// v0.27.0:当前画布画面的值快照(`PKDrawing` 写时复制,取快照零成本)
    var canvasSnapshot: PKDrawing { canvas.drawing }

    /// v0.30.0:程序化改动画布后同步干墨跨页层(代理回调不保证覆盖所有路径)。
    private func notifyDrawingChanged() {
        onDrawingChanged?(canvas.drawing)
    }

    /// v0.27.0:撤销/重做装回快照后,短暂关闭直线吸附后处理
    func suppressInkPostProcessing(for seconds: TimeInterval) {
        postProcessSuppressUntil = CFAbsoluteTimeGetCurrent() + seconds
    }

    /// v0.32.0:撤销/重做后的冷却窗口内,provider 的跨页搬页也要停手 ——
    /// 否则装回的"整笔跨页墨迹"会被立刻重新切开,看起来像撤销无效。
    var inkPostProcessingSuppressed: Bool {
        CFAbsoluteTimeGetCurrent() < postProcessSuppressUntil
    }

    /// v0.27.0:把快照装回画布(撤销/重做用)
    func applyCanvasSnapshot(_ drawing: PKDrawing) {
        canvas.drawing = drawing
        notifyDrawingChanged()
    }

    /// v0.23.0:清空整页手写(登记一条撤销,可恢复)
    func clearInk() {
        let snapshot = canvas.drawing
        guard !snapshot.strokes.isEmpty else { return }
        onActionBegin?("清空本页", canvasSnapshot)
        canvas.drawing = PKDrawing()
        notifyDrawingChanged()
        if let undo = canvas.undoManager {
            undo.registerUndo(withTarget: self) { target in
                target.canvas.drawing = snapshot
            }
        }
        flushSave()
        onActionEnd?()
        DiagLog.log("pencil: page \(pageIndex) cleared \(snapshot.strokes.count) strokes")
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        saveNow()
    }

    private func saveNow() {
        guard loaded, let inkStore, !docSha.isEmpty else { return }
        // v0.23.2:画布坐标含四周出血偏移,落库前换回页面坐标
        var stored = canvas.drawing
        stored.transform(using: InkGeometry.pageFromCanvas)
        let data = stored.dataRepresentation()
        inkStore.save(docSha: docSha, page: pageIndex, data: data, scale: Double(InkGeometry.scale))
        DiagLog.log("pencil: page \(pageIndex) ink saved \(canvas.drawing.strokes.count) strokes")
    }
}
