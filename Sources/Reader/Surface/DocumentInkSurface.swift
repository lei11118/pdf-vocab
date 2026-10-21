import UIKit
import PDFKit
import PencilKit

/// v0.40.0:**文档级单画布**(替代"每页一块 PKCanvasView")。
///
/// ## 为什么必须换架构
/// 旧实现把每页的页矩形当成一块 `PKCanvasView` 的裁切框。笔一旦越过页边界,
/// 越界的那截墨**不在任何画布里**,于是必然"间断";抬笔后再切分/搬页补回来,
/// 于是必然"闪一下"。这不是参数问题,是容器问题 —— 一页一个墨迹容器,
/// 就不可能画出一条跨页连续的墨。
///
/// ## 新模型
/// - 整个文档只有 **1 块** `PKCanvasView`,挂在 `PDFView.documentView` 里,
///   frame 覆盖全部页(1:1 页面点),`bounds` 放大 3 倍用于超采样(与旧 ink 存储同比例);
/// - 墨迹坐标 = **文档坐标系**(全文档统一,与页码无关),存一次就够,不需要按页切/搬;
/// - PDFKit 只负责**渲染页面与取词**,不再承载任何墨迹;
/// - 一笔就是一笔:跨 1、2、3、N 页都是同一条 `PKStroke`,不切分 → 无接缝、无闪烁;
/// - 撤销用画布原生 `undoManager`,笔级粒度,不需要页级撤销栈。
///
/// ## 与 PDFView 的坐标关系
/// 画布是 `documentView` 的子视图:`documentView` 已被 PDFView 的 scrollView 缩放,
/// 所以画布只需关心**内容坐标**(1:1 页面点),缩放由父视图完成。
/// 页面点 `(px, py)`(文档左上原点、y 向下)→ 画布坐标 `(px*scale, py*scale)`。
final class DocumentInkSurface: UIView {

    // MARK: - 常量

    /// 与历史 ink 数据一致的超采样倍率(旧数据 3x)
    static let scale: CGFloat = 3

    // MARK: - 对外

    /// 墨迹变化(抬笔/擦除/撤销后)→ 调用方负责落库
    var onDrawingChanged: ((PKDrawing) -> Void)?
    /// 落库防抖(秒)
    var saveDebounce: TimeInterval = 0.8

    /// 文档级墨迹(画布坐标 = 页面点 × scale)
    var drawing: PKDrawing {
        get { canvas.drawing }
        set {
            guard newValue != canvas.drawing else { return }
            suppressNotify += 1
            canvas.drawing = newValue
            suppressNotify -= 1
            layoutIfNeeded()
        }
    }

    /// 页面点 → 画布坐标
    static func canvasPoint(fromPagePoint p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale, y: p.y * scale)
    }

    /// 画布坐标 → 页面点
    static func pagePoint(fromCanvasPoint p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / scale, y: p.y / scale)
    }

    // MARK: - 内部

    private(set) var canvas: PKCanvasView
    private weak var pdfView: PDFView?
    private var suppressNotify = 0
    private var saveTask: Task<Void, Never>?
    private var observationTokens: [NSKeyValueObservation] = []

    deinit {
        observationTokens.forEach { $0.invalidate() }
        saveTask?.cancel()
    }

    // MARK: - 生命周期

    init() {
        canvas = PKCanvasView(frame: .zero)
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false        // 容器不吃事件,只做布局
        isOpaque = false

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.isScrollEnabled = false          // 滚动交给 PDFView
        canvas.drawingPolicy = .anyInput
        canvas.delegate = self
        canvas.overrideUserInterfaceStyle = .light
        addSubview(canvas)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 挂到 PDFView:画布成为 documentView 的子视图,铺满整份文档。
    func attach(to pdfView: PDFView) {
        self.pdfView = pdfView
        guard let docView = pdfView.documentView else {
            DiagLog.log("surface: attach failed (no documentView)")
            return
        }
        if superview !== docView { docView.addSubview(self) }
        isUserInteractionEnabled = false
        layoutSurface()
        // 缩放/滚动都会改变文档内容在 docView 里的位置,跟着重新对齐
        observationTokens.append(pdfView.observe(\.scaleFactor, options: [.new]) { [weak self] _, _ in
            self?.layoutSurface()
        })
        observationTokens.append(pdfView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            self?.layoutSurface()
        })
        DiagLog.log("surface: attached size=\(Int(bounds.width))x\(Int(bounds.height))")
    }

    /// 页面/缩放变化后重新对齐(由协调器在 layout 观察者里调用)
    func layoutSurface() {
        guard let pdfView, let docView = pdfView.documentView else { return }

        // 文档内容矩形:PDFView 的所有页在 **docView 坐标系**里的并集
        // (pdfView.convert 给的是视口坐标,必须再转进 docView,否则滚动/缩放后整体错位)
        var docRect = CGRect.null
        if let document = pdfView.document {
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let inView = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
                let inDoc = docView.convert(inView, from: pdfView)
                docRect = docRect.union(inDoc)
            }
        }
        if docRect.isNull { docRect = docView.bounds }
        docRect = docRect.insetBy(dx: -InkGeometry.bleedTop, dy: -InkGeometry.bleedTop)

        frame = docRect
        // bounds 放大 scale 倍:画布内部按 3x 页面点绘制,显示时缩回 1x
        bounds = CGRect(x: 0, y: 0,
                        width: max(1, docRect.width * Self.scale),
                        height: max(1, docRect.height * Self.scale))
        canvas.frame = bounds

        // 缩放后按新倍率重新栅格化,避免高倍放大发虚
        let factor = UIScreen.main.scale * max(1, pdfView.scaleFactor)
        if canvas.contentScaleFactor < factor {
            canvas.contentScaleFactor = factor
            canvas.setNeedsDisplay()
        }
    }

    // MARK: - 工具

    func applyTool(_ tool: PKTool) {
        canvas.tool = tool
        // PKCanvasView.tool 赋值会重建内部手势识别器,重开后要再关一次选择手势
        canvas.drawingGestureRecognizer.isEnabled = true
    }

    func setEraser(_ eraser: PKEraserTool) {
        canvas.tool = eraser
        canvas.drawingGestureRecognizer.isEnabled = true
    }

    // MARK: - 撤销

    func undo() {
        if canvas.undoManager?.canUndo == true { canvas.undoManager?.undo() }
    }

    func redo() {
        if canvas.undoManager?.canRedo == true { canvas.undoManager?.redo() }
    }

    var canUndo: Bool { canvas.undoManager?.canUndo ?? false }
    var canRedo: Bool { canvas.undoManager?.canRedo ?? false }

    // MARK: - 持久化

    private func scheduleSave() {
        guard suppressNotify == 0 else { return }
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
