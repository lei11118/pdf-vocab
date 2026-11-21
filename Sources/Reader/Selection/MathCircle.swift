import PDFKit
import UIKit
import Vision

struct MathCircle {
    let path: CGPath
    var bounds: CGRect { path.boundingBoxOfPath }

    /// The original screen samples are validated before projection to the page.
    static func accepts(_ samples: [CGPoint]) -> Bool {
        guard samples.count >= 8, let first = samples.first, let last = samples.last,
              samples.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let outline = MathCircle(samples)
        let box = outline.bounds
        let diagonal = hypot(box.width, box.height)
        guard min(box.width, box.height) >= 10, diagonal <= 1_600,
              hypot(first.x - last.x, first.y - last.y) <= min(44, max(13, diagonal * 0.32)) else { return false }
        let twiceArea = zip(samples, samples.dropFirst() + [first]).reduce(CGFloat.zero) { total, pair in
            total + ((pair.0.x - first.x) * (pair.1.y - first.y)
                - (pair.1.x - first.x) * (pair.0.y - first.y))
        }
        return abs(twiceArea) >= box.width * box.height * 0.8
    }

    init(_ samples: [CGPoint]) {
        let outline = CGMutablePath()
        outline.addLines(between: samples)
        outline.closeSubpath()
        path = outline
    }

    func contains(_ point: CGPoint) -> Bool {
        path.contains(point, using: .evenOdd)
    }

    func enclosesCenter(of box: CGRect) -> Bool {
        contains(CGPoint(x: box.midX, y: box.midY))
    }
}

/// Dedicated input recognizer for the active formula tool. Its view is the
/// viewport, so the trace is separate from PDF annotations and saved ink.
final class MathCircleGesture: UIGestureRecognizer {
    var didBegin: ((CGPoint) -> Void)?
    var didTrace: (([CGPoint]) -> Void)?
    var didFinish: (([CGPoint]) -> Void)?
    private var points: [CGPoint] = []
    private var tracked: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, touches.count == 1, let touch = touches.first,
              let view else {
            state = state == .possible ? .failed : .cancelled
            return
        }
        tracked = touch
        let start = touch.location(in: view)
        points = [start]
        didBegin?(start)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked), let view else { return }
        for sample in event.coalescedTouches(for: tracked) ?? [tracked] {
            append(sample.location(in: view))
        }
        guard points.count > 1 else { return }
        state = state == .possible ? .began : .changed
        didTrace?(points)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked), let view else { return }
        append(tracked.location(in: view))
        guard state == .began || state == .changed else { state = .failed; return }
        let trace = points
        state = .ended
        // Applying a selection may disable this gesture in the next view update.
        didFinish?(trace)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        tracked = nil
        points.removeAll(keepingCapacity: true)
        didTrace?([])
    }

    private func append(_ point: CGPoint) {
        guard let previous = points.last, hypot(previous.x - point.x, previous.y - point.y) >= 1.5 else { return }
        if points.count == 512 {
            points = stride(from: 0, to: points.count, by: 2).map { points[$0] }
        }
        points.append(point)
    }
}

/// Vision is used only for one visible line from an image crop. Its output
/// is presented as OCR to check against the original raster; an ambiguous
/// stacked layout never gets reconstructed as a linear expression.
enum ScannedFormulaReading {
    enum Candidate: Sendable {
        case oneLine(String)
        case uncertain
    }

    static func recognize(in image: CGImage) -> Candidate? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return .uncertain
        }
        let lines = request.results ?? []
        guard lines.count == 1, let line = lines.first, let best = line.topCandidates(1).first,
              best.confidence >= 0.5 else { return visibleInkHeight(image) > 0 ? .uncertain : nil }
        // Vision can return just the easier middle row of a stacked formula.
        // Require the observation to account for the vertical ink extent.
        let inkHeight = visibleInkHeight(image)
        guard inkHeight > 0 else { return nil }
        guard inkHeight <= max(1.45 * line.boundingBox.height, line.boundingBox.height + 0.12)
        else { return .uncertain }
        let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .uncertain }
        return .oneLine(text)
    }

    static func readingResult(for candidate: Candidate) -> MathReadingResult {
        let text: String?
        switch candidate {
        case .uncertain: text = nil
        case .oneLine(let line):
            text = line
            if let parsed = MathReadingService.resolve(line), parsed.status == .parsedText {
                return MathReadingResult(sourceText: line, latex: parsed.latex, unicode: parsed.unicode,
                    explanation: "这是扫描识别的候选排版。请对照原图核对字母大小写、上下标和符号。",
                    status: .parsedOCR, ast: parsed.ast)
            }
        }
        let explanation = text == nil
            ? "扫描图中的符号或结构仍待确认。可对照圈内原图。"
            : "这是扫描图的候选文字，大小写、上下标和分式结构请以原图为准。"
        return MathReadingResult(sourceText: text ?? "圈选的扫描公式", latex: nil, unicode: nil,
                                 explanation: explanation, status: .needsReview, ast: nil)
    }

    private static func visibleInkHeight(_ image: CGImage) -> CGFloat {
        let width = min(384, image.width)
        let height = min(160, image.height)
        guard width > 0, height > 0 else { return 0 }
        var gray = [UInt8](repeating: 255, count: width * height)
        return gray.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 1 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var first: Int?
            var last = 0
            for row in 0..<height {
                let start = row * width
                guard bytes[start..<(start + width)].lazy.filter({ $0 < 180 }).prefix(3).count == 3 else { continue }
                first = first ?? row
                last = row
            }
            guard let first else { return 0 }
            return CGFloat(last - first + 1) / CGFloat(height)
        }
    }
}

