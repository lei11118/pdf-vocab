import UIKit
import PencilKit
import PDFKit

/// v0.29.0:笔迹越过页面的哪一条边(跨页搬运的方向)。
enum OverflowSide: String {
    case below, above, right, left
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
            overlay = InkOverlayView(pageIndex: index, docSha: docSha, inkStore: inkStore, markMode: markMode, tool: currentTool, rulerActive: rulerActive)
            let size = page.bounds(for: view.displayBox).size
            overlay.frame = CGRect(origin: .zero, size: size)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.onCanvasBecameActive = { [weak self] canvas in
                self?.activeCanvas = canvas
            }
            // v0.29.0:跨页书写 —— 越过任一页边的段交给目标页(上下左右都走同一条管道)
            overlay.onMoveOverflow = { [weak self] index, side, stroke in
                self?.moveOverflow(from: index, side: side, stroke: stroke) ?? false
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

    /// v0.14.0:把当前笔具套用到全部页画布(幂等)。
    func setTool(_ tool: PKTool?) {
        currentTool = tool
        guard let tool else { return }
        for (_, overlay) in overlays {
            overlay.canvas.tool = tool
        }
    }

    /// v0.16.0:直尺开关同步到所有已创建页画布(新页在创建时继承)。
    func setRulerActive(_ active: Bool) {
        rulerActive = active
        for (_, overlay) in overlays {
            overlay.setRulerActive(active)
        }
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

    // MARK: - v0.29.0 跨页搬运(上下左右统一)

    /// 把越过页边的段搬到**几何上相邻**的那一页。
    ///
    /// v0.29.0 修正了三处结构性错误:
    /// 1. **不再用 `index ± 1` 猜邻页** —— 双页并排时 index+1 在右边,竖排时在下面;
    ///    横向连续时更根本没有"下面"。现在按页在 PDFView 里的实际位置找最近邻页,
    ///    所以纵向 / 横向 / 双页三种排布都成立。
    /// 2. **不再用「页高 × scale」硬算位移** —— 改用两页在视图里的实际 origin 差换算
    ///    (含页宽不同、页高不同、页与页之间有间距的情况),落点才严丝合缝。
    /// 3. 横向排布支持 x 轴切分(以前只有 y 轴,左右翻页必断)。
    ///
    /// 目标页叠层可能还没创建(PDFKit 只为可见页建叠层)—— 这时直接写进目标页的墨迹库,
    /// 叠层创建时 `loadInk` 自然带出来,不丢墨、不错位。
    private func moveOverflow(from index: Int, side: OverflowSide, stroke: PKStroke) -> Bool {
        guard overlays[index] != nil else { return false }
        guard let pdfView, let document = pdfView.document else {
            DiagLog.log("pencil: overflow \(side) dropped (no document)")
            return false
        }
        guard let target = neighborIndex(of: index, side: side, pdfView: pdfView, document: document) else {
            DiagLog.log("pencil: overflow \(side) dropped (page \(index) has no neighbour)")
            return false
        }
        let scaleFactor = pdfView.scaleFactor > 0.01 ? pdfView.scaleFactor : 1
        let dx: CGFloat
        let dy: CGFloat
        if let src = pageRect(index, pdfView: pdfView, document: document),
           let dst = pageRect(target, pdfView: pdfView, document: document),
           src.width > 1, dst.width > 1 {
            // 页面坐标位移 × 超采样倍数;用视图坐标差做基准,页高/页宽不同也对得上。
            dx = (src.minX - dst.minX) * InkGeometry.scale / scaleFactor
            dy = (src.minY - dst.minY) * InkGeometry.scale / scaleFactor
        } else {
            // 兜底:按边长的算术解(与 v0.28.0 相同)
            let srcSize = overlays[index]?.bounds.size
                ?? document.page(at: index)?.bounds(for: pdfView.displayBox).size
                ?? .zero
            let dstSize = document.page(at: target)?.bounds(for: pdfView.displayBox).size ?? srcSize
            switch side {
            case .below: dx = 0; dy = -srcSize.height * InkGeometry.scale
            case .above: dx = 0; dy = dstSize.height * InkGeometry.scale
            case .right: dx = -srcSize.width * InkGeometry.scale; dy = 0
            case .left: dx = dstSize.width * InkGeometry.scale; dy = 0
            }
        }
        guard let moved = PencilStrokeTools.shifted(stroke, dx: dx, dy: dy) else { return false }
        // 两页都要进同一个撤销组(先拍"动作前"快照,再改)
        notePagesInAction([index, target])

        if let next = overlays[target] {
            // 目标页自己的 drawingDidChange 会再排一次跨页检查 —— 先静一会儿,
            // 否则刚搬过来的段会被当成“新笔”再切一次。
            next.suppressInkPostProcessing(for: 0.5)
            next.canvas.drawing = PKDrawing(strokes: next.canvas.drawing.strokes + [moved])
            next.flushSave()
            if abs(dx) > abs(dy) {
                DiagLog.log("pencil: overflow moved page \(index) -> \(target) \(side) dx=\(Int(dx))")
            } else {
                DiagLog.log("pencil: overflow moved page \(index) -> \(target) \(side) dy=\(Int(dy))")
            }
            // 一笔跨两页以上:只有挪过去的这一段**仍然越出目标页**时才排队再切一次。
            // (否则笔来回折返时会变成两页之间无限乒乓搬运。)
            let dstSize = document.page(at: target)?.bounds(for: pdfView.displayBox).size
                ?? next.bounds.size
            if overflowsAnyEdge(moved, pageSize: dstSize) {
                next.recheckOverflow(rangeStart: next.canvas.drawing.strokes.count - 1, after: 0.6)
            }
        } else if appendToStore(page: target, canvasStroke: moved) {
            DiagLog.log("pencil: overflow stored page \(index) -> \(target) \(side) (overlay not ready)")
        } else {
            DiagLog.log("pencil: overflow \(side) dropped (page \(target) unavailable)")
            return false
        }
        overlays[index]?.flushSave()
        return true
    }

    /// 这一笔在目标页的画布里是否还越出页边(用于判断要不要继续多跳切分)。
    private func overflowsAnyEdge(_ stroke: PKStroke, pageSize: CGSize) -> Bool {
        guard pageSize.width > 1, pageSize.height > 1 else { return false }
        let rect = InkGeometry.pageRectInCanvas(pageSize: pageSize)
        let eps: CGFloat = 1
        for point in stroke.path {
            let p = point.location
            if p.x < rect.minX - eps || p.x > rect.maxX + eps
                || p.y < rect.minY - eps || p.y > rect.maxY + eps {
                return true
            }
        }
        return false
    }

    /// 一页在 PDFView 视图坐标里的矩形(未显示的页也能算,PDFKit 按文档版面换算)。
    private func pageRect(_ index: Int, pdfView: PDFView, document: PDFDocument) -> CGRect? {
        guard index >= 0, index < document.pageCount, let page = document.page(at: index) else { return nil }
        let rect = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
        return rect.width > 1 && rect.height > 1 ? rect : nil
    }

    /// 按「页中心相对方向」找最近的邻页。纵向连续 → 上下;横向连续 → 左右;
    /// 双页并排 → 右边是 +1、下面是 +2。全部由真实版面决定,不再假设 index 相邻。
    private func neighborIndex(of index: Int, side: OverflowSide,
                               pdfView: PDFView, document: PDFDocument) -> Int? {
        guard let mine = pageRect(index, pdfView: pdfView, document: document) else { return nil }
        let myCenter = CGPoint(x: mine.midX, y: mine.midY)
        var best: (index: Int, distance: CGFloat)?
        let lower = max(0, index - 6)
        let upper = min(document.pageCount - 1, index + 6)
        guard lower <= upper else { return nil }
        for candidate in lower...upper where candidate != index {
            guard let rect = pageRect(candidate, pdfView: pdfView, document: document) else { continue }
            let dx = rect.midX - myCenter.x
            let dy = rect.midY - myCenter.y
            let matches: Bool
            switch side {
            case .below: matches = dy > 1 && dy >= abs(dx) * 0.6
            case .above: matches = dy < -1 && -dy >= abs(dx) * 0.6
            case .right: matches = dx > 1 && dx >= abs(dy) * 0.6
            case .left: matches = dx < -1 && -dx >= abs(dy) * 0.6
            }
            guard matches else { continue }
            let distance = hypot(dx, dy)
            if best == nil || distance < best!.distance {
                best = (candidate, distance)
            }
        }
        return best?.index
    }

    /// v0.24.0:叠层还没创建时,把画布坐标的一笔直接并进目标页的墨迹库(库内是页面坐标)。
    private func appendToStore(page: Int, canvasStroke: PKStroke) -> Bool {
        guard let inkStore, page >= 0 else { return false }
        guard let stored = PencilStrokeTools.shifted(canvasStroke, dx: -InkGeometry.pageLeftX(), dy: -InkGeometry.pageTopY()) else { return false }

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
        drawing = PKDrawing(strokes: drawing.strokes + [stored])
        inkStore.save(
            docSha: docSha,
            page: page,
            data: drawing.dataRepresentation(),
            scale: Double(InkGeometry.scale)
        )
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
    /// (跨页书写因此只需要撤销一次)。等 0.35s 是为了让跨页切分/直线吸附先完成。
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
    /// v0.29.0:笔迹越过页边(上下左右)→ 把溢出段交给 provider 搬到相邻页(返回是否搬成功)
    var onMoveOverflow: ((Int, OverflowSide, PKStroke) -> Bool)?
    /// v0.27.0:一次用户动作(落笔/橡皮/形状/清空)的开始与结束 —— provider 用它把
    /// 涉及到的所有页(含跨页时的相邻页)合成**一条**撤销记录。
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

    // MARK: - v0.28.0 全局湿墨层 / 跨页切分

    /// v0.28.0:全局湿墨层(由 provider 注入)。形状预览画在这里,跨页时不被邻页遮住。
    weak var wetHost: PencilWetInkHost?
    /// v0.25.1:跨页检查的调度状态(见 `scheduleOverflowCheck`)
    private var overflowCheckWork: DispatchWorkItem?
    /// v0.27.0:在这个时刻之前,不做跨页切分/直线吸附(撤销装回快照后要静一会儿)
    private var postProcessSuppressUntil: CFAbsoluteTime = 0
    /// v0.28.0:本次动作新增笔迹的**起始下标**(形状一次可能生成多笔 / 切分后可能变多段),
    private var pendingOverflowStart: Int?
    /// 防止「切分 → 写回 drawing → drawingDidChange → 再切分」的递归
    private var transferring = false
    /// v0.28.0:PencilKit 正在书写时不做后处理(避免把进行中的一笔中途切开)
    private var strokeInProgress = false

    private var marking = false
    private var loaded = false
    private var saveWork: DispatchWorkItem?
    private var lastLoggedSize = CGSize.zero
    /// v0.24.0:本次落笔开始时已有的笔数(= 新笔在 drawing 里的下标)。
    /// 以前靠 `creationDate` 的 3 秒窗口判断"刚刚画完的一笔" —— 慢慢写超过 3 秒的长笔
    /// (尤其跨页那一笔)会直接漏切/漏吸附,这正是"页缝衔接不对"的根因之一。
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

    /// v0.28.0:一次装填整份模式状态。与逐项 setXxxMode 的差别是:
    /// 只算一次手势状态、只打一行日志,并且形状参数在**同一次调用**里就位。
    func applyModeState(_ state: PencilToolState) {
        let wasLaser = laserActive
        let wasShape = shapeActive
        if canvas.isRulerActive != state.rulerActive {
            canvas.isRulerActive = state.rulerActive
        }
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
        // v0.25.1:形状也可能跨页,交给统一的跨页检查
        pendingOverflowStart = canvas.drawing.strokes.count - 1
        scheduleOverflowCheck()
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
        // v0.25.1:PencilKit 在代理回调之后才把这一笔写进 drawing —— 每次 drawing 变化都补一次跨页检查,
        // 这样"抬笔瞬间 drawing 还没更新"就不会再把跨页那一段漏掉。
        scheduleOverflowCheck()
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
        // v0.20.0:跨页书写 —— 抬笔后检查这一笔是否越界
        // v0.21.0:先做直线吸附,再做跨页切分
        // v0.25.1:以前这里是 `DispatchQueue.main.async` 里立刻查 drawing —— 但 PencilKit 是在
        // `canvasViewDidEndUsingTool` **返回之后**才把这一笔并进 `canvas.drawing` 的,于是
        // `idx < strokes.count` 常常不成立 → 跨页那一段永远搬不走(真机"页缝上半段消失")。
        // 现在只记下下标,由 `scheduleOverflowCheck()`(drawing 变化 / 0.1s 兜底)去执行。
        pendingOverflowStart = beginIndex
        scheduleOverflowCheck()
        // v0.27.0:动作结束(真正入栈要等跨页切分/吸附完成后再拍"之后"的快照)
        onActionEnd?()
    }

    /// 跨页检查的防抖调度:同一笔在 drawing 更新前后可能被触发多次,只保留最后一次。
    private func scheduleOverflowCheck() {
        // v0.27.0:撤销/重做装回快照后短时间内不做后处理,否则「撤销跨页一笔」会被立刻重新切开
        guard CFAbsoluteTimeGetCurrent() >= postProcessSuppressUntil else { return }
        // v0.28.0:书写中 drawing 可能含半成品,先不切;抬笔后的 END 会重新排一次。
        guard !strokeInProgress else { return }
        overflowCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let start = self.pendingOverflowStart
            self.pendingOverflowStart = nil
            self.snapStraightIfNeeded(at: start)
            self.transferOverflowIfNeeded(rangeStart: start)
        }
        overflowCheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
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
        DiagLog.log("pencil: line snap page \(pageIndex) len=\(Int(length / InkGeometry.scale))pt dev=\(String(format: "%.1f", maxDeviation / InkGeometry.scale))pt")
    }

    /// v0.29.0:把越过**任一页边**的段切下来交给相邻页。
    ///
    /// 变化(相对 v0.28.0):
    /// - 四边都检查:下 / 上 / 右 / 左。以前只查 y,横向排布时越过页左/页右的墨永远搬不走,
    ///   抬笔后就从画布边界被裁掉 —— 这就是「左右排序必断」。
    /// - 一笔可能同时越过两条边(写在页角)—— 循环最多 4 次,每次处理越界最多的那条边。
    /// - 切分点用画布里的**页面矩形**(x0/y0/x1/y1),不是只靠页高。
    func transferOverflowIfNeeded(rangeStart: Int?) {
        guard bounds.width > 1, bounds.height > 1, !transferring else { return }
        var strokes = canvas.drawing.strokes
        guard !strokes.isEmpty else { return }
        let pageSize = bounds.size
        let rect = InkGeometry.pageRectInCanvas(pageSize: pageSize)

        // 本次动作新增笔迹的起点;拿不到有效起点时只回看最后一笔(避免误伤旧墨)。
        let lowerBound: Int
        if let start = rangeStart, start >= 0, start < strokes.count {
            lowerBound = start
        } else {
            lowerBound = max(0, strokes.count - 1)
        }

        transferring = true
        defer { transferring = false }

        var changed = false
        var index = strokes.count - 1
        while index >= lowerBound {
            let original = strokes[index]
            if InkGeometry.touchesCanvasEdge(original, pageSize: pageSize) {
                DiagLog.log("pencil: page \(pageIndex) stroke hit canvas edge (bleed exhausted) — 墨迹已被画布边界裁掉")
            }
            // 一笔可能连续跨多条边(页角 / 长笔画):每轮把仍在页外的部分搬走,
            // 剩下的内侧片段下一轮再查。最多 4 轮,纯属防御。
            var pending: [PKStroke] = [original]
            var didMove = false
            var hops = 0
            while hops < 4 {
                var remaining: [PKStroke] = []
                var movedThisHop = false
                for stroke in pending {
                    // 页角上的一笔可能同时越过两条边;而某条边在这个排布里可能**没有邻页**
                    // (竖排的左右、横排的上下)。按越界量从大到小逐条边试,第一条能搬走的为准
                    // —— 否则写在右下角的一笔会先试右边、右边没页、整笔放弃,页底那一段就永远不搬。
                    var moved = false
                    for candidate in overflowCandidates(of: stroke, pageRect: rect) {
                        guard candidate.parts.outside.count >= 2,
                              let outside = PencilStrokeTools.makeStroke(
                                  points: candidate.parts.outside, template: stroke,
                                  creationDate: stroke.path.creationDate
                              ),
                              onMoveOverflow?(pageIndex, candidate.side, outside) == true else {
                            continue
                        }
                        moved = true
                        movedThisHop = true
                        if let kept = PencilStrokeTools.makeStroke(
                            points: candidate.parts.prefix, template: stroke,
                            creationDate: stroke.path.creationDate
                        ) { remaining.append(kept) }
                        if let kept = PencilStrokeTools.makeStroke(
                            points: candidate.parts.suffix, template: stroke,
                            creationDate: stroke.path.creationDate
                        ) { remaining.append(kept) }
                        break
                    }
                    if !moved { remaining.append(stroke) }
                }
                pending = remaining
                guard movedThisHop else { break }
                didMove = true
                hops += 1
            }
            if didMove {
                strokes.remove(at: index)
                strokes.insert(contentsOf: pending, at: index)
                changed = true
                DiagLog.log("pencil: page \(pageIndex) overflow trimmed idx=\(index) kept=\(pending.count) hops=\(hops)")
            }
            index -= 1
        }

        if changed {
            canvas.drawing = PKDrawing(strokes: strokes)
            flushSave()
        }
    }

    /// 列出这一笔**所有**越界的边,按越界量从大到小。
    /// 切分点用插值出来的边界点,两半在页缝处共享同一个点。
    /// 返回候选而不是单一结果:某条边在当前排布里可能没有邻页(竖排的左右、横排的上下),
    /// 调用方按顺序试,直到某条边真的搬走。
    private func overflowCandidates(of stroke: PKStroke, pageRect rect: CGRect)
        -> [(side: OverflowSide, parts: PencilStrokeTools.Parts)] {
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for point in stroke.path {
            minX = min(minX, point.location.x)
            maxX = max(maxX, point.location.x)
            minY = min(minY, point.location.y)
            maxY = max(maxY, point.location.y)
        }
        let overshoots: [(OverflowSide, CGFloat)] = [
            (.below, maxY - rect.maxY),
            (.above, rect.minY - minY),
            (.right, maxX - rect.maxX),
            (.left, rect.minX - minX)
        ]
        let overflowing = overshoots.filter { $0.1 > 0.5 }.sorted { $0.1 > $1.1 }
        return overflowing.map { item -> (side: OverflowSide, parts: PencilStrokeTools.Parts) in
            switch item.0 {
            case .below: return (.below, PencilStrokeTools.splitBelow(stroke, atY: rect.maxY))
            case .above: return (.above, PencilStrokeTools.splitAbove(stroke, atY: rect.minY))
            case .right: return (.right, PencilStrokeTools.splitRight(stroke, atX: rect.maxX))
            case .left: return (.left, PencilStrokeTools.splitLeft(stroke, atX: rect.minX))
            }
        }
    }

    /// v0.29.0:一笔跨两页以上时,等抑制期过后再检查一次(由搬运方在目标页上调用)。
    func recheckOverflow(rangeStart: Int, after seconds: TimeInterval) {
        pendingOverflowStart = rangeStart
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let start = self.pendingOverflowStart
            self.pendingOverflowStart = nil
            self.transferOverflowIfNeeded(rangeStart: start)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// v0.27.0:当前画布画面的值快照(`PKDrawing` 写时复制,取快照零成本)
    var canvasSnapshot: PKDrawing { canvas.drawing }

    /// v0.27.0:撤销/重做装回快照后,短暂关闭跨页切分与直线吸附后处理
    func suppressInkPostProcessing(for seconds: TimeInterval) {
        postProcessSuppressUntil = CFAbsoluteTimeGetCurrent() + seconds
    }

    /// v0.27.0:把快照装回画布(撤销/重做用)
    func applyCanvasSnapshot(_ drawing: PKDrawing) {
        canvas.drawing = drawing
    }

    /// v0.23.0:清空整页手写(登记一条撤销,可恢复)
    func clearInk() {
        let snapshot = canvas.drawing
        guard !snapshot.strokes.isEmpty else { return }
        onActionBegin?("清空本页", canvasSnapshot)
        canvas.drawing = PKDrawing()
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
