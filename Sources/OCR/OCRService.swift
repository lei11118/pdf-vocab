import Foundation
import PDFKit
import Vision

/// OCR 词框(M6,v0.11.0):归一化坐标(**top-left 原点**,相对整页),按行分组。
struct OCRWord: Sendable {
    let text: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    let line: Int
}

/// 扫描版(无文字层)PDF 的 Vision OCR 管线:整本按页识别 → 词级包围框 → 存库;
/// 阅读时按页取词框做命中检测与范围选择(由 ReaderCoordinator 接到统一取词交互上)。
///
/// 关键 API 核实(2026-10):`VNRecognizedText.boundingBox(for:)` 在 `.accurate` 级别下
/// 返回**词级**包围框("word precision")——正则切出整词范围后取框,正好逐词可用。
enum OCRService {

    // MARK: - 扫描版判定

    /// Mixed PDFs need page-level inspection; a text cover says nothing about later scans.
    static func needsOCR(page: PDFPage) -> Bool {
        (page.string ?? "").filter { !$0.isWhitespace }.count < 12
    }

    /// 采样前 4 页:多数页无文字层 → 判为扫描版。
    static func isScanned(document: PDFDocument) -> Bool {
        let count = document.pageCount
        guard count > 0 else { return false }
        let sample = min(count, 4)
        var empty = 0
        for i in 0..<sample {
            guard let page = document.page(at: i) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count < 12 { empty += 1 }
        }
        return empty * 2 > sample
    }

    // MARK: - 整本识别(后台;按页落库;可取消——取消则不标记完成,下次打开续跑)

    static func run(url: URL, docSha: String, store: OCRStore, progress: @escaping (Int, Int) -> Void) async {
        guard var doc = PDFDocument(url:url) else { return }
        let total=doc.pageCount
        for i in 0..<total {
            if Task.isCancelled { return }
            progress(i, total)
            if i>0 && i%32==0, let fresh=PDFDocument(url:url) { doc=fresh }
            autoreleasepool {
                guard let page=doc.page(at:i) else { return }
                let words = needsOCR(page: page) ? recognize(page: page) : []
                if !Task.isCancelled { store.save(docSha:docSha,page:i,words:words) }
            }
        }
        guard !Task.isCancelled else { return }
        progress(total, total)
        store.markDone(docSha: docSha)
    }

    // MARK: - 单页识别

    /// 渲染页面(约 180 DPI)→ Vision 逐行识别 → 正则切词 → 逐词取包围框。
    static func renderingSize(for bounds: CGRect) -> CGSize {
        guard bounds.width.isFinite,bounds.height.isFinite,bounds.width>1,bounds.height>1 else { return .zero }
        let density=min(2.5,min(4096/max(bounds.width,bounds.height),sqrt(6_000_000/(bounds.width*bounds.height))))
        return CGSize(width:floor(bounds.width*density),height:floor(bounds.height*density))
    }
    // Render in canonical, unrotated PDF media coordinates. PDFKit thumbnails
    // rotate the image; OCR boxes must instead share the exact page-space CTM.
    static func recognitionImage(page: PDFPage, size: CGSize, region: CGRect? = nil) -> CGImage? {
        let bounds = region ?? page.bounds(for: .mediaBox)
        guard let ref = page.pageRef, bounds.width > 1, bounds.height > 1,
              size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: size.width / bounds.width, y: size.height / bounds.height)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.drawPDFPage(ref)
        return context.makeImage()
    }

    /// Overlapping tiles preserve small glyphs without allocating a whole oversized page.
    static func regions(for bounds: CGRect) -> [CGRect] {
        guard bounds.width > 1, bounds.height > 1 else { return [] }
        return (0..<2).flatMap { row in (0..<2).map { column in
            CGRect(x: bounds.minX + CGFloat(column) * bounds.width * 0.5,
                   y: bounds.minY + CGFloat(row) * bounds.height * 0.5,
                   width: bounds.width * 0.5, height: bounds.height * 0.5)
                .insetBy(dx: -16, dy: -16).intersection(bounds)
        } }
    }

    static func recognize(page: PDFPage) -> [OCRWord] {
        let bounds = page.bounds(for: .mediaBox)
        var words: [OCRWord] = []
        for region in regions(for: bounds) {
            if Task.isCancelled { return [] }
            let local = autoreleasepool { recognizeRegion(page: page, region: region) }
            for word in local {
                let rect = pageRect(from: word, pageBounds: region)
                let mapped = OCRWord(text: word.text,
                    x: Double((rect.minX-bounds.minX)/bounds.width),
                    y: Double((bounds.maxY-rect.maxY)/bounds.height),
                    w: Double(rect.width/bounds.width), h: Double(rect.height/bounds.height), line: 0)
                let duplicate = words.contains { other in
                    let box = pageRect(from: other, pageBounds: bounds)
                    let overlap = box.intersection(rect)
                    return !overlap.isNull && overlap.width*overlap.height > min(box.width*box.height,rect.width*rect.height)*0.65
                }
                if !duplicate { words.append(mapped) }
            }
        }
        // Restore reading order and line IDs after tile merging.
        words.sort { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        var line = -1, baseline: Double = -1, height: Double = 0
        let ordered = words.map { word in
            if baseline < 0 || abs(word.y-baseline) > min(height,word.h)*0.45 {
                line += 1; baseline=word.y; height=word.h
            }
            return OCRWord(text:word.text,x:word.x,y:word.y,w:word.w,h:word.h,line:line)
        }
    return ordered.sorted { $0.line == $1.line ? $0.x < $1.x : $0.line < $1.line }
    }

    private static func recognizeRegion(page: PDFPage, region: CGRect) -> [OCRWord] {
        let pageBounds = region
        guard pageBounds.width > 1, pageBounds.height > 1 else { return [] }
        let factor = min(4.2, min(4096/max(pageBounds.width,pageBounds.height),sqrt(6_000_000/(pageBounds.width*pageBounds.height))))
        let target = CGSize(width:floor(pageBounds.width*factor),height:floor(pageBounds.height*factor))
        guard target.width>1,target.height>1 else { return [] }
        guard let cgImage = recognitionImage(page: page, size: target, region: region) else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        var out: [OCRWord] = []
        let regex = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z'’\\-]*")
        for (lineIdx, observation) in (request.results ?? []).enumerated() {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            let ns = text as NSString
            let matches = regex?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
            for match in matches {
                guard let range = Range(match.range, in: text),
                      let boxObs = try? candidate.boundingBox(for: range) else { continue }
                let bb = boxObs.boundingBox   // 归一化,左下原点
                out.append(OCRWord(
                    text: String(text[range]),
                    x: Double(bb.minX),
                    y: Double(1 - bb.maxY),
                    w: Double(bb.width),
                    h: Double(bb.height),
                    line: lineIdx
                ))
            }
        }
        return out
    }

    // MARK: - 命中与几何

    /// Exact word boxes outrank padded neighbours; padding is bounded by line height.
    static func wordIndex(at pagePoint: CGPoint, in words: [OCRWord], pageBounds: CGRect) -> Int? {
        guard !words.isEmpty, pageBounds.width > 1, pageBounds.height > 1 else { return nil }
        var best: (idx: Int, exact: Bool, distance: CGFloat)?
        for (i, word) in words.enumerated() {
            let rect = pageRect(from: word, pageBounds: pageBounds)
            guard SelectionGeometry.isValid(rect) else { continue }
            let padX = min(rect.width * 0.15, rect.height * 0.35)
            let padY = rect.height * 0.35
            guard rect.insetBy(dx: -padX, dy: -padY).contains(pagePoint) else { continue }
            let exact = rect.contains(pagePoint)
            let dx = max(rect.minX - pagePoint.x, 0, pagePoint.x - rect.maxX)
            let dy = max(rect.minY - pagePoint.y, 0, pagePoint.y - rect.maxY)
            let distance = dx * dx + dy * dy
            if best == nil || (exact && !best!.exact)
                || (exact == best!.exact && distance < best!.distance) {
                best = (i, exact, distance)
            }
        }
        return best?.idx
    }

    /// Normalized top-left OCR coordinates to PDF media-box coordinates.
    static func pageRect(from word: OCRWord, pageBounds: CGRect) -> CGRect {
        CGRect(
            x: pageBounds.minX + CGFloat(word.x) * pageBounds.width,
            y: pageBounds.minY + CGFloat(1 - word.y - word.h) * pageBounds.height,
            width: CGFloat(word.w) * pageBounds.width,
            height: CGFloat(word.h) * pageBounds.height
        )
    }
}
