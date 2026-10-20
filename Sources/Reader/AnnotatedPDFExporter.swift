import Foundation
import PDFKit
import PencilKit
import UIKit

/// P2(v0.12.0,M7):导出「批注版 PDF」——把生词高亮与 Pencil 手写**烧录**进新 PDF 文件
/// (逐页 2x 栅格合成;**原 PDF 不被修改**)。注:输出为图片化页面(丢失文字层),用于分发/打印。
enum AnnotatedPDFExporter {

    static func export(url: URL, docSha: String, vocab: VocabStore, ink: PencilInkStore) throws -> URL {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            throw ExportError.cannotOpen
        }
        // 高亮按页分组(页坐标 = 与阅读器一致的口径;PDFView 默认 displayBox = cropBox)
        var byPage: [Int: [(rect: CGRect, color: String)]] = [:]
        for row in vocab.highlights(docSha: docSha) {
            for rect in row.rects {
                byPage[row.page, default: []].append((rect, row.color))
            }
        }

        let firstBounds = doc.page(at: 0)?.bounds(for: .cropBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: firstBounds)
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("跃文-批注版-\(Int(Date().timeIntervalSince1970)).pdf")
        try? FileManager.default.removeItem(at: outURL)

        let scale: CGFloat = 2
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true

        /// 读某页手写并归一化到**页面坐标(y 向下,页面点,左上原点)**。
        /// v0.30.0:墨迹归属落笔页,可能越出页面矩形;导出时把相邻页的越界段补画回来。
        func loadPageInk(_ index: Int) -> PKDrawing? {
            guard let record = ink.drawing(docSha: docSha, page: index),
                  var drawing = try? PKDrawing(data: record.data),
                  !drawing.strokes.isEmpty else { return nil }
            if record.scale > 0.001, abs(record.scale - 1) > 0.001 {
                let factor = CGFloat(1 / record.scale)
                drawing.transform(using: CGAffineTransform(scaleX: factor, y: factor))
            }
            return drawing
        }

        try renderer.writePDF(to: outURL) { context in
            for i in 0..<doc.pageCount {
                autoreleasepool {
                    guard let page = doc.page(at: i) else { return }
                    let pageBounds = page.bounds(for: .cropBox)
                    guard pageBounds.width > 1, pageBounds.height > 1 else { return }
                    let pixelSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
                    let base = page.thumbnail(of: pixelSize, for: .cropBox)
                    let composed = UIGraphicsImageRenderer(size: pixelSize, format: fmt).image { imageContext in
                        base.draw(in: CGRect(origin: .zero, size: pixelSize))
                        // 高亮(页坐标左下原点 → 图片坐标左上原点)
                        for (rect, colorName) in byPage[i] ?? [] {
                            let mapped = CGRect(
                                x: (rect.minX - pageBounds.minX) * scale,
                                y: (pageBounds.maxY - rect.maxY) * scale,
                                width: rect.width * scale,
                                height: rect.height * scale
                            )
                            VocabStore.highlightColor(named: colorName).withAlphaComponent(0.4).setFill()
                            imageContext.cgContext.fill(mapped)
                        }
                        // Pencil 手写(导出前归一化到页面坐标)
                        if let own = loadPageInk(i) {
                            let inkImage = own.image(from: CGRect(origin: .zero, size: pageBounds.size), scale: scale)
                            inkImage.draw(in: CGRect(origin: .zero, size: pixelSize))
                        }
                        // v0.30.0:上一页写在页底之外的墨 → 本页顶部
                        if i > 0, let prev = loadPageInk(i - 1),
                           let prevPage = doc.page(at: i - 1) {
                            let pb = prevPage.bounds(for: .cropBox)
                            guard pb.width > 1, pb.height > 1 else { return }
                            let strip = prev.image(
                                from: CGRect(x: 0, y: pb.height, width: pb.width, height: InkGeometry.bleed),
                                scale: scale
                            )
                            strip.draw(in: CGRect(x: 0, y: 0,
                                                  width: pb.width * scale,
                                                  height: InkGeometry.bleed * scale))
                        }
                        // v0.30.0:下一页写在页顶之外的墨 → 本页底部
                        if i + 1 < doc.pageCount, let next = loadPageInk(i + 1),
                           let nextPage = doc.page(at: i + 1) {
                            let nb = nextPage.bounds(for: .cropBox)
                            guard nb.width > 1, nb.height > 1 else { return }
                            let strip = next.image(
                                from: CGRect(x: 0, y: -InkGeometry.bleedTop, width: nb.width, height: InkGeometry.bleedTop),
                                scale: scale
                            )
                            strip.draw(in: CGRect(x: 0, y: pageBounds.height * scale,
                                                  width: nb.width * scale,
                                                  height: InkGeometry.bleedTop * scale))
                        }
                    }
                    context.beginPage(withBounds: pageBounds, pageInfo: [:])
                    composed.draw(in: pageBounds)
                }
            }
        }
        DiagLog.log("annotated pdf: exported pages=\(doc.pageCount)")
        return outURL
    }

    enum ExportError: LocalizedError {
        case cannotOpen

        var errorDescription: String? {
            switch self {
            case .cannotOpen: return "无法打开 PDF"
            }
        }
    }
}
