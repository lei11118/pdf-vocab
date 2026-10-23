import UIKit
import PDFKit
import PencilKit

/// v0.44.0:**按页存墨 + 抬笔沿页边切割**(矢量笔迹,零压缩)。
///
/// ## 为什么这样存
/// - 墨迹本来就是**矢量**(`PKStroke` = 控制点 + 笔宽 + 压力/方位/倾角),PKDrawing 序列化
///   只是把这些数值编码成二进制,**不做有损压缩**,所以缩放不会越放越糊;
/// - 但"渲染"会糊:用 `bounds ≠ frame` 伪造超采样会引入分数缩放,实时笔画亚像素抖动。
///   现在 `bounds == frame`(恒等变换),`contentOffset/contentSize` 只做取景窗平移;
/// - 墨迹坐标按**每一页自己的坐标系**(页面点、左上原点)记录 → 换排布(纵向⇄横向)时
///   每页墨迹跟着该页走,不会游走;
/// - 抬笔后按页矩形切割:跨页的一笔被切成两半,各自留在所属页原位(用户接受的口径)。
final class DocumentInkSurface: UIView {

    static let scale: CGFloat = 1

    // MARK: - 对外

    /// 每页墨迹(页面坐标,左上原点,单位=页面点)
    private(set) var pageDrawings: [Int: PKDrawing] = [:]
    /// 某页墨迹变化 → 落库
    var onPageInkChanged: ((Int, PKDrawing) -> Void)?
    /// 懒加载某页墨迹(从库里读)
    var pageDrawingProvider: ((Int) -> PKDrawing?)?

    private(set) var canvas = PKCanvasView()
    private weak var pdfView: PDFView?
    private var windowOrigin: CGPoint = .zero
    /// 当前窗口包含的页及其在画布坐标里的矩形
    private var windowPages: [(index: Int, rect: CGRect)] = []
    private var drawingEnabled = false
    private var saveTask: Task<Void, Never>?
    /// 重组画布内容时不要回写(否则自己触发自己)
    private var suppressArchive = false
    private var observationTokens: [NSKeyValueObservation] = []

    // MARK: - 生命周期

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.drawingPolicy = .pencilOnly     // iPad:Pencil 落墨,手指滚动/选词
        canvas.delegate = self
        canvas.overrideUserInterfaceStyle = .light
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observationTokens.forEach { $0.invalidate() }
        saveTask?.cancel()
    }

    // MARK: - 触摸门控

    func setDrawingEnabled(_ enabled: Bool) {
        guard drawingEnabled != enabled else { return }
        drawingEnabled = enabled
        canvas.isUserInteractionEnabled = enabled
        isUserInteractionEnabled = enabled
        DiagLog.log("surface: drawing \(enabled ? "on" : "off")")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard drawingEnabled else { return nil }
        return super.hitTest(point, with: event)
    }

    // MARK: - 挂载与窗口

    func attach(to pdfView: PDFView) {
        self.pdfView = pdfView
        installObserversIfNeeded(pdfView)
        ensureAttached()
    }

    func ensureAttached() {
        guard let pdfView else { return }
        guard let docView = pdfView.documentView else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.ensureAttached() }
            return
        }
        if superview !== docView { docView.addSubview(self) }
        isUserInteractionEnabled = true
        refreshWindow()
    }

    private func installObserversIfNeeded(_ pdfView: PDFView) {
        guard observationTokens.isEmpty else { return }
        observationTokens.append(pdfView.observe(\.scaleFactor, options: [.new]) { [weak self] _, _ in
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
    }

    /// 重算窗口(当前页 ±1)并按页重组墨迹
    func refreshWindow() {
        guard let pdfView, let docView = pdfView.documentView, let document = pdfView.document,
              document.pageCount > 0 else { return }

        let current = pdfView.currentPage.map { document.index(for: $0) } ?? 0
        let lo = max(0, current - 1), hi = min(document.pageCount - 1, current + 1)

        var rects: [(Int, CGRect)] = []
        var windowRect = CGRect.null
        for index in lo...max(lo, hi) {
            guard let page = document.page(at: index) else { continue }
            let inView = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
            let inDoc = docView.convert(inView, from: pdfView)
            rects.append((index, inDoc))
            windowRect = windowRect.union(inDoc)
        }
        guard !windowRect.isNull, windowRect.width > 1, windowRect.height > 1 else { return }
        windowRect = windowRect.insetBy(dx: -InkGeometry.bleedTop, dy: -InkGeometry.bleedTop)

        let changed = abs(windowRect.minX - windowOrigin.x) > 0.5
            || abs(windowRect.minY - windowOrigin.y) > 0.5
            || abs(windowRect.width - bounds.width) > 1
            || abs(windowRect.height - bounds.height) > 1
        guard changed else { return }

        windowOrigin = windowRect.origin
        windowPages = rects.map { (index: $0.0, rect: $0.1) }
        frame = windowRect
        bounds = CGRect(origin: .zero, size: windowRect.size)
        canvas.frame = bounds
        canvas.bounds = CGRect(origin: .zero, size: bounds.size)   // 恒等变换,不抖
        canvas.contentSize = CGSize(width: windowRect.maxX, height: windowRect.maxY)
        canvas.contentOffset = windowRect.origin
        if let superview { superview.bringSubviewToFront(self) }
        recompose()
        DiagLog.log("surface: window page \(lo)...\(hi) size=\(Int(windowRect.width))x\(Int(windowRect.height))")
    }

    /// 窗口换页后,从每页墨迹重新拼出画布内容(只在换窗口时做,不在书写中做)
    private func recompose() {
        var strokes: [PKStroke] = []
        for entry in windowPages {
            var pageDrawing = pageDrawings[entry.index] ?? .init()
            if pageDrawings[entry.index] == nil, let loaded = pageDrawingProvider?(entry.index) {
                pageDrawing = loaded
                pageDrawings[entry.index] = loaded
            }
            guard !pageDrawing.strokes.isEmpty else { continue }
            let shift = entry.rect.origin
            for stroke in pageDrawing.strokes {
                strokes.append(Self.translated(stroke, by: shift))
            }
        }
        suppressArchive = true
        canvas.drawing = PKDrawing(strokes: strokes)
        suppressArchive = false
        DiagLog.log("surface: composed strokes=\(strokes.count) pages=\(windowPages.count)")
    }

    // MARK: - 抬笔:按页切割并归档

    private func archive(_ drawing: PKDrawing) -> Bool {
        guard !windowPages.isEmpty else { return false }
        // 每个页面先清空,再由这次的完整绘制重建(切割是幂等的)
        for entry in windowPages { pageDrawings[entry.index] = PKDrawing() }

        var changedPages = Set<Int>()
        for stroke in drawing.strokes {
            // 画布坐标 → 文档坐标
            let inDoc = Self.translated(stroke, by: windowOrigin)
            let points = Array(inDoc.path)
            guard points.count >= 2 else { continue }

            var runPage: Int?
            var runPoints: [PKStrokePoint] = []
            func flush() {
                guard let page = runPage, runPoints.count >= 2,
                      let entry = windowPages.first(where: { $0.index == page }) else { return }
                let local = runPoints.map { Self.moved($0, by: CGPoint(x: -entry.rect.minX, y: -entry.rect.minY)) }
                let path = PKStrokePath(controlPoints: local, creationDate: stroke.path.creationDate)
                let piece = PKStroke(ink: stroke.ink, path: path, transform: .identity, mask: stroke.mask)
                var bucket = pageDrawings[page] ?? PKDrawing()
                var strokes = bucket.strokes
                strokes.append(piece)
                bucket = PKDrawing(strokes: strokes)
                pageDrawings[page] = bucket
                changedPages.insert(page)
            }

            for point in points {
                let owner = windowPages.first { $0.rect.contains(point.location) }?.index
                if owner != runPage {
                    flush()
                    runPage = owner
                    runPoints = owner == nil ? [] : [point]
                } else if owner != nil {
                    runPoints.append(point)
                }
            }
            runPage = nil
            runPoints = []
            flush()   // 收尾:最后一段也要落页
        }
        for page in changedPages { if let d = pageDrawings[page] { onPageInkChanged?(page, d) } }
        return !changedPages.isEmpty
    }

    // MARK: - 工具 / 撤销

    func applyTool(_ tool: PKTool) {
        canvas.tool = tool
        canvas.drawingGestureRecognizer.isEnabled = true
    }

    func undo() { if canvas.undoManager?.canUndo == true { canvas.undoManager?.undo() } }
    func redo() { if canvas.undoManager?.canRedo == true { canvas.undoManager?.redo() } }

    // MARK: - 几何工具

    private static func translated(_ stroke: PKStroke, by delta: CGPoint) -> PKStroke {
        PKStroke(ink: stroke.ink, path: stroke.path,
                 transform: stroke.transform.concatenating(
                    CGAffineTransform(translationX: delta.x, y: delta.y)),
                 mask: stroke.mask)
    }

    private static func moved(_ point: PKStrokePoint, by delta: CGPoint) -> PKStrokePoint {
        PKStrokePoint(location: CGPoint(x: point.location.x + delta.x, y: point.location.y + delta.y),
                      timeOffset: point.timeOffset, size: point.size, opacity: point.opacity,
                      force: point.force, azimuth: point.azimuth, altitude: point.altitude,
                      secondaryScale: point.secondaryScale)
    }
}

extension DocumentInkSurface: PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !suppressArchive else { return }
        archive(canvasView.drawing)
    }
}
