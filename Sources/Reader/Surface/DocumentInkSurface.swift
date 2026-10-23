import UIKit
import PDFKit
import PencilKit

/// v0.41.0:**文档级墨迹 + 滑动窗口画布**。
///
/// ## 两次失败的教训
/// - 每页一块画布:页矩形就是裁切框,越界那截墨不在任何画布里 → 跨页**必然间断**,
///   抬笔切分搬页 → **必然闪**;
/// - 一整块铺满全文档:221 页横排并集 290000×5569 点,×3 超采样后 87 万×1.7 万点,
///   PencilKit 的 tiled renderer 栅格化不了 → 真机**所有工具都不出墨**
///   (日志 `surface: attached size=290663x5569`)。
///
/// ## 现在的模型(墨迹在文档坐标系,画布是一扇窗口)
/// - 墨迹存 **文档坐标**(`docDrawing`,单位 = docView 点 × scale),与窗口无关;
/// - 画布只覆盖 **当前页 ±1 页**(一笔跨 3 页够用),典型 2000×2400 点,可栅格化;
/// - 窗口内容 = 文档级墨迹**平移**到窗口原点后的副本,窗口外的笔迹落在 bounds 外被裁掉;
/// - 抬笔把窗口画布回写成文档级墨迹并落库;翻页只换窗口原点,不搬墨迹、不切分;
/// - 因此在窗口内,"一笔跨页"始终是**同一条 `PKStroke`** —— 无接缝、无复制、无闪烁。
final class DocumentInkSurface: UIView {

    /// 墨迹坐标 = **页面点**(1:1)。v0.43.0 去掉 ×3 超采样:
    /// 那是用「bounds 比 frame 大」实现的隐式缩放,叠上 PDFView 的非整数缩放后
    /// 有效变换是分数 → PencilKit 实时笔画亚像素对不齐 = 真机「轻微抖动」。
    static let scale: CGFloat = 1

    // MARK: - 对外

    /// 文档级墨迹(文档坐标 = docView 点 × scale)
    private(set) var docDrawing = PKDrawing()
    /// 墨迹变化(抬笔/擦除/撤销后)→ 调用方负责落库
    var onDrawingChanged: ((PKDrawing) -> Void)?
    /// 落库防抖(秒)
    var saveDebounce: TimeInterval = 0.8

    /// 文档级墨迹 = 画布墨迹(绝对坐标 = docView 点 × scale),窗口只换取景原点
    var drawing: PKDrawing {
        get { canvas.drawing }
        set { canvas.drawing = newValue }
    }

    /// 窗口原点(docView 坐标,单位=点)
    private(set) var windowOrigin: CGPoint = .zero

    // MARK: - 内部

    private(set) var canvas = PKCanvasView()
    private weak var pdfView: PDFView?
    private var suppressNotify = 0
    private var saveTask: Task<Void, Never>?
    private var observationTokens: [NSKeyValueObservation] = []
    /// 书写模式才让画布吃触摸;选词模式整层穿透
    private var drawingEnabled = false

    // MARK: - 生命周期

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false          // 滚动交给 PDFView
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.drawingPolicy = .pencilOnly        // iPad:Pencil 落墨,手指只滚动/选词
        canvas.delegate = self
        canvas.overrideUserInterfaceStyle = .light
        addSubview(canvas)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        observationTokens.forEach { $0.invalidate() }
        saveTask?.cancel()
    }

    // MARK: - 触摸门控

    /// 切换是否接管触摸。**选词模式必须关掉**,否则会挡住长按选词、拖柄与 Pencil 悬停。
    func setDrawingEnabled(_ enabled: Bool) {
        guard drawingEnabled != enabled else { return }
        drawingEnabled = enabled
        canvas.isUserInteractionEnabled = enabled
        isUserInteractionEnabled = enabled
        DiagLog.log("surface: drawing \(enabled ? "on" : "off")")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard drawingEnabled else { return nil }   // 选词模式:整层不参与命中
        return super.hitTest(point, with: event)
    }

    // MARK: - 挂载

    func attach(to pdfView: PDFView) {
        self.pdfView = pdfView
        installObserversIfNeeded(pdfView)
        ensureAttached()
    }

    /// 文档装载前 `documentView` 是 nil —— 必须可重试(v0.40.2 修)。
    func ensureAttached() {
        guard let pdfView else { return }
        guard let docView = pdfView.documentView else {
            DiagLog.log("surface: waiting for documentView")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.ensureAttached()
            }
            return
        }
        if superview !== docView { docView.addSubview(self) }
        isUserInteractionEnabled = true
        refreshWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refreshWindow()
        }
        DiagLog.log("surface: attached window=\(Int(bounds.width))x\(Int(bounds.height))")
    }

    private func installObserversIfNeeded(_ pdfView: PDFView) {
        guard observationTokens.isEmpty else { return }
        observationTokens.append(pdfView.observe(\.scaleFactor, options: [.new]) { [weak self] _, _ in
            // 只提高栅格化密度(不改几何,不会抖),几何交给 PDFView 的缩放
            guard let self, let pdfView = self.pdfView else { return }
            let target = UIScreen.main.scale * max(1, min(3, pdfView.scaleFactor))
            if self.canvas.contentScaleFactor < target {
                self.canvas.contentScaleFactor = target
                self.canvas.setNeedsDisplay()
            }
        })
        observationTokens.append(pdfView.observe(\.document, options: [.new]) { [weak self] _, _ in
            self?.ensureAttached()
        })
        // ⚠️ 不要监听 bounds:滚动时重算窗口会重设 drawing,打断实时渲染(真机=抖动/写完才出来)
    }

    // MARK: - 窗口

    /// 重新计算窗口(当前页 ±1)并把文档级墨迹平移进来。翻页/缩放/旋转都要调。
    func refreshWindow() {
        guard let pdfView, let docView = pdfView.documentView, let document = pdfView.document else { return }
        guard document.pageCount > 0 else { return }

        let current: Int
        if let page = pdfView.currentPage { current = document.index(for: page) } else { current = 0 }
        let lo = max(0, current - 1)
        let hi = min(document.pageCount - 1, current + 1)

        var windowRect = CGRect.null
        for index in lo...max(lo, hi) {
            guard let page = document.page(at: index) else { continue }
            // PDFPage 不是 UICoordinateSpace:先转进 pdfView 视口坐标,再转进 docView
            let inView = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
            windowRect = windowRect.union(docView.convert(inView, from: pdfView))
        }
        guard !windowRect.isNull, windowRect.width > 1, windowRect.height > 1 else { return }

        // 出血:笔尖贴窗口边缘时不被裁
        windowRect = windowRect.insetBy(dx: -InkGeometry.bleedTop, dy: -InkGeometry.bleedTop)

        let needsResize = abs(windowRect.width * Self.scale - bounds.width) > 1 ||
                          abs(windowRect.height * Self.scale - bounds.height) > 1
        let moved = abs(windowRect.minX - windowOrigin.x) > 0.5 ||
                    abs(windowRect.minY - windowOrigin.y) > 0.5
        guard needsResize || moved else { return }

        // ⚠️ 只改滚动窗口,绝不重设 canvas.drawing,也不让 bounds ≠ frame:
        // 隐式缩放会让实时笔画亚像素抖动(Apple: 放大绘制区要用 contentSize/contentOffset)。
        windowOrigin = windowRect.origin
        frame = windowRect
        bounds = CGRect(x: 0, y: 0, width: windowRect.width, height: windowRect.height)
        canvas.frame = CGRect(origin: .zero, size: bounds.size)
        canvas.bounds = CGRect(origin: .zero, size: bounds.size)     // 恒等变换
        let origin = CGPoint(x: windowRect.minX * Self.scale, y: windowRect.minY * Self.scale)
        canvas.contentSize = CGSize(width: origin.x + bounds.width * Self.scale,
                                    height: origin.y + bounds.height * Self.scale)
        canvas.contentOffset = origin
        // PDFKit 翻页会重建页视图并压到上层 —— 每次换窗口都重新置顶
        if let superview { superview.bringSubviewToFront(self) }
        DiagLog.log("surface: window page \(lo)...\(hi) size=\(Int(canvas.bounds.width))x\(Int(canvas.bounds.height))")
    }

    // MARK: - 文档 ↔ 窗口

    private func renderDocIntoCanvas() {
        suppressNotify += 1
        var copy = docDrawing
        copy.transform(using: CGAffineTransform(translationX: -windowOrigin.x * Self.scale,
                                                y: -windowOrigin.y * Self.scale))
        canvas.drawing = copy
        suppressNotify -= 1
    }

    private func commitCanvasToDoc() {
        var copy = canvas.drawing
        copy.transform(using: CGAffineTransform(translationX: windowOrigin.x * Self.scale,
                                                y: windowOrigin.y * Self.scale))
        docDrawing = copy
    }

    // MARK: - 工具

    func applyTool(_ tool: PKTool) {
        canvas.tool = tool
        // 赋值会重建内部手势识别器,重开后要再开一次绘制手势
        canvas.drawingGestureRecognizer.isEnabled = true
    }

    // MARK: - 撤销

    func undo() { if canvas.undoManager?.canUndo == true { canvas.undoManager?.undo() } }
    func redo() { if canvas.undoManager?.canRedo == true { canvas.undoManager?.redo() } }
    var canUndo: Bool { canvas.undoManager?.canUndo ?? false }
    var canRedo: Bool { canvas.undoManager?.canRedo ?? false }

    // MARK: - 持久化

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = canvas.drawing
        saveTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.saveDebounce
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self.onDrawingChanged?(snapshot) }
        }
    }
}

extension DocumentInkSurface: PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard suppressNotify == 0 else { return }
        scheduleSave()
    }
}
