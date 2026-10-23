import UIKit
import PDFKit

/// v0.46.0:自研墨迹引擎的宿主层 —— 把 `InkMetalCanvasView` 接到 PDFView 上。
///
/// 职责边界:
/// - **坐标**:PDFView 会把页面缩放/平移,这里每次布局重算「每页在屏幕上的矩形」,
///   把每页墨迹(页面坐标)映射成视图坐标后交给渲染器 → 渲染器永远按设备像素画,
///   不存在位图放大,所以任意倍率都锐利;
/// - **页边硬裁剪**:`clipRects` = 每页在屏幕上的矩形,墨迹越出即被丢弃(D2-A);
/// - **落库**:一笔结束按页矩形换算回页面坐标,写回该页。
final class MetalInkHost: UIView {

    private weak var pdfView: PDFView?
    private var pageRects: [(index: Int, rect: CGRect, scale: CGFloat)] = []
    private let canvas = InkMetalCanvasView()
    private var store: PencilInkStore?
    private var docSha: String = ""
    private var pages: [Int: InkPage] = [:]

    var isDrawingEnabled: Bool {
        get { canvas.isDrawingEnabled }
        set { canvas.isDrawingEnabled = newValue }
    }

    /// 宿主自己不吃触摸,触摸交给内部画布(选词模式下整体关闭)
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard canvas.isDrawingEnabled else { return nil }
        return super.hitTest(point, with: event)
    }

    // MARK: - 挂载

    func attach(to pdfView: PDFView, store: PencilInkStore?, docSha: String) {
        self.pdfView = pdfView
        self.store = store
        self.docSha = docSha
        backgroundColor = .clear
        canvas.frame = bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.pageTransform = .identity
        canvas.onStrokeCommitted = { [weak self] stroke in self?.commit(stroke) }
        addSubview(canvas)
        pdfView.addSubview(self)
        frame = pdfView.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.bringSubviewToFront(self)
        refresh()
        DiagLog.log("metal ink: attached")
    }

    // MARK: - 工具

    func applyTool(color: UIColor, baseWidth: CGFloat) {
        canvas.inkColor = color
        canvas.baseWidth = max(0.8, baseWidth)
    }

    // MARK: - 布局

    /// 重算每页屏幕矩形 + 重新映射墨迹(缩放结束/翻页/换排布时调用)
    func refresh() {
        guard let pdfView, let document = pdfView.document, document.pageCount > 0 else { return }
        frame = pdfView.bounds
        let current = pdfView.currentPage.map { document.index(for: $0) } ?? 0
        let lo = max(0, current - 1), hi = min(document.pageCount - 1, current + 1)

        var rects: [(Int, CGRect, CGFloat)] = []
        for index in lo...max(lo, hi) {
            guard let page = document.page(at: index) else { continue }
            let viewRect = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
            let pageWidth = page.bounds(for: pdfView.displayBox).width
            guard pageWidth > 1 else { continue }
            rects.append((index, viewRect, viewRect.width / pageWidth))
        }
        pageRects = rects
        canvas.clipRects = rects.map { $0.1 }
        canvas.frame = bounds

        // 每页墨迹 → 视图坐标
        var viewStrokes: [InkStroke] = []
        for entry in rects {
            let page = pageDrawing(entry.index) ?? InkPage()
            for stroke in page.strokes {
                var mapped = stroke
                mapped.points = stroke.points.map { p in
                    let v = CGPoint(x: p.x, y: p.y)
                        .applying(CGAffineTransform(scaleX: entry.scale, y: entry.scale))
                        .applying(CGAffineTransform(translationX: entry.rect.minX, y: entry.rect.minY))
                    var q = p; q.x = Double(v.x); q.y = Double(v.y)
                    q.width = p.width * Double(entry.scale)
                    return q
                }
                viewStrokes.append(mapped)
            }
        }
        canvas.pageStrokes = viewStrokes
        DiagLog.log("metal ink: refresh pages=\(rects.count) strokes=\(viewStrokes.count)")
    }

    // MARK: - 落库

    private func pageDrawing(_ index: Int) -> InkPage? {
        if let cached = pages[index] { return cached }
        guard let store, !docSha.isEmpty, let record = store.drawing(docSha: docSha, page: index) else { return nil }
        // 新引擎数据:JSON;旧数据:二进制 PKDrawing(交给迁移)
        if let page = InkPage.decode(record.data) { pages[index] = page; return page }
        if let legacy = try? PKDrawing(data: record.data) {
            let scale = max(1, record.scale)
            let page = InkPage(strokes: InkLegacyMigration.strokes(from: legacy, scale: CGFloat(scale)))
            pages[index] = page
            DiagLog.log("metal ink: migrated page \(index) strokes=\(page.strokes.count)")
            return page
        }
        return nil
    }

    private func commit(_ stroke: InkStroke) {
        guard let first = stroke.points.first else { return }
        let point = CGPoint(x: first.x, y: first.y)
        guard let entry = pageRects.first(where: { $0.1.contains(point) }) else {
            DiagLog.log("metal ink: drop out-of-page stroke")
            return
        }
        // 视图坐标 → 页面坐标
        var pageStroke = stroke
        pageStroke.points = stroke.points.map { p in
            var q = p
            q.x = (p.x - Double(entry.rect.minX)) / Double(entry.scale)
            q.y = (p.y - Double(entry.rect.minY)) / Double(entry.scale)
            q.width = p.width / Double(entry.scale)
            return q
        }
        var page = pages[entry.index] ?? InkPage()
        page.append(pageStroke)
        pages[entry.index] = page
        store?.save(docSha: docSha, page: entry.index, data: page.data(),
                    scale: 1)
        DiagLog.log("metal ink: saved page \(entry.index) strokes=\(page.strokes.count)")
    }
}
