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
        guard let doc = PDFDocument(url: url) else { return }
        let total = doc.pageCount
        for i in 0..<total {
            if Task.isCancelled { return }
            progress(i, total)
            guard let page = doc.page(at: i) else { continue }
            let words = recognize(page: page)
            store.save(docSha: docSha, page: i, words: words)
        }
        progress(total, total)
        store.markDone(docSha: docSha)
    }

    // MARK: - 单页识别

    /// 渲染页面(约 180 DPI)→ Vision 逐行识别 → 正则切词 → 逐词取包围框。
    static func recognize(page: PDFPage) -> [OCRWord] {
        let pageBounds = page.bounds(for: .mediaBox)
        guard pageBounds.width > 1, pageBounds.height > 1 else { return [] }
        let scale: CGFloat = 2.5
        let target = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
        guard let cgImage = page.thumbnail(of: target, for: .mediaBox).cgImage else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]

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

    /// 页坐标点 → 词索引(容差:水平 ±15%、垂直 ±35%;多个候选取中心最近者)。
    static func wordIndex(at pagePoint: CGPoint, in words: [OCRWord], pageBounds: CGRect) -> Int? {
        guard !words.isEmpty, pageBounds.width > 1, pageBounds.height > 1 else { return nil }
        let nx = Double((pagePoint.x - pageBounds.minX) / pageBounds.width)
        let nyTop = Double(1 - (pagePoint.y - pageBounds.minY) / pageBounds.height)
        var best: (idx: Int, d: Double)?
        for (i, word) in words.enumerated() {
            let padX = word.w * 0.15
            let padY = word.h * 0.35
            let inside = nx >= word.x - padX && nx <= word.x + word.w + padX
                && nyTop >= word.y - padY && nyTop <= word.y + word.h + padY
            guard inside else { continue }
            let dx = nx - (word.x + word.w / 2)
            let dy = nyTop - (word.y + word.h / 2)
            let d = dx * dx + dy * dy
            if best == nil || d < (best?.d ?? .infinity) { best = (i, d) }
        }
        return best?.idx
    }

    /// 归一化词框 → 页坐标矩形(PDF 坐标,左下原点;含 pageBounds 原点偏移)。
    static func pageRect(from word: OCRWord, pageBounds: CGRect) -> CGRect {
        CGRect(
            x: pageBounds.minX + CGFloat(word.x) * pageBounds.width,
            y: pageBounds.minY + CGFloat(1 - word.y - word.h) * pageBounds.height,
            width: CGFloat(word.w) * pageBounds.width,
            height: CGFloat(word.h) * pageBounds.height
        )
    }
}
