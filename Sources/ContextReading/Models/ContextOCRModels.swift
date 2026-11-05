import Foundation

/// A finite, positive-size rectangle in unrotated PDF media-box coordinates.
struct SourceRect: Codable, Equatable, Hashable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init?(x: Double, y: Double, width: Double, height: Double) {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0,
              (x + width).isFinite, (y + height).isFinite else { return nil }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init?(rect: CGRect) {
        guard !rect.isNull, !rect.isInfinite else { return nil }
        self.init(x: Double(rect.minX), y: Double(rect.minY),
                  width: Double(rect.width), height: Double(rect.height))
    }

    var cgRect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }

    private enum CodingKeys: String, CodingKey { case x, y, width, height }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let x = try values.decode(Double.self, forKey: .x)
        let y = try values.decode(Double.self, forKey: .y)
        let width = try values.decode(Double.self, forKey: .width)
        let height = try values.decode(Double.self, forKey: .height)
        guard let validated = SourceRect(x: x, y: y, width: width, height: height) else {
            throw DecodingError.dataCorruptedError(forKey: .width, in: values,
                                                   debugDescription: "SourceRect must be finite and have positive dimensions")
        }
        self = validated
    }
}

/// Geometry attached to a semantic token. OCR only provides word-level boxes;
/// this model deliberately has no character-box representation.
struct SourceTokenGeometry: Codable, Equatable, Sendable {
    let tokenID: String
    let span: UTF16Span
    let rect: SourceRect?
    let quality: SourceGeometryQuality
}

struct OCRCandidate: Codable, Equatable, Sendable {
    let text: String
    let confidence: Double
}

/// One exact Vision candidate set. `candidates.first` is the unmodified top
/// candidate and token geometry corresponds only to that candidate.
/// `regionRect` identifies the tile used to recognize it; `pageRect` and token
/// boxes are in PDF media coordinates.
struct OCRLine: Codable, Equatable, Sendable {
    let blockID: String
    let candidates: [OCRCandidate]
    let regionRect: SourceRect
    let pageRect: SourceRect?
    let tokens: [SourceToken]
    let tokenGeometry: [SourceTokenGeometry]

    var sourceText: String { candidates.first?.text ?? "" }
    var confidence: Double { candidates.first?.confidence ?? 0 }
}

/// Complete result for one successfully recognized page. An empty `lines`
/// array represents a completed blank page and differs from a missing row.
struct ContextOCRPage: Codable, Equatable, Sendable {
    let documentSHA256: String
    let pageIndex: Int
    let revision: Int
    let mediaBox: SourceRect
    let lines: [OCRLine]
}
