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
        points = [touch.location(in: view)]
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
    static func recognize(in image: CGImage, outline: CGPath, pageCrop: CGRect) -> MathReadingResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return review()
        }
        let lines = (request.results ?? []).filter { line in
            let box = line.boundingBox
            let center = CGPoint(x: pageCrop.minX + box.midX * pageCrop.width,
                                 y: pageCrop.minY + box.midY * pageCrop.height)
            return outline.contains(center, using: .evenOdd)
        }
        guard lines.count == 1, let line = lines.first,
              let best = line.topCandidates(1).first, best.confidence >= 0.5 else {
            return review()
        }
        let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return review() }
        return review(text)
    }

    private static func review(_ text: String? = nil) -> MathReadingResult {
        let explanation = text == nil
            ? "扫描图中的符号或结构仍待确认。可对照圈内原图。"
            : "这是扫描图的候选文字，大小写、上下标和分式结构请以原图为准。"
        return MathReadingResult(sourceText: text ?? "圈选的扫描公式", latex: nil, unicode: nil,
                                 explanation: explanation, status: .needsReview, ast: nil)
    }
}

