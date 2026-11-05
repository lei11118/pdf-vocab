import CryptoKit
import Foundation

/// Coordinate and duplicate handling shared by Vision ingestion and tests.
enum ContextOCRGeometry {
    /// Vision normalized boxes use a lower-left origin. Rendering uses the
    /// unrotated media-box CTM, so mapping is a translation and scale only.
    static func pageRect(fromVisionNormalized rect: CGRect, in region: CGRect) -> SourceRect? {
        let tolerance: CGFloat = 0.000_001
        guard rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0,
              rect.minX >= -tolerance, rect.minY >= -tolerance,
              rect.maxX <= 1 + tolerance, rect.maxY <= 1 + tolerance,
              region.minX.isFinite, region.minY.isFinite,
              region.width.isFinite, region.height.isFinite,
              region.width > 0, region.height > 0 else { return nil }
        let minX = min(1, max(0, rect.minX))
        let minY = min(1, max(0, rect.minY))
        let maxX = min(1, max(0, rect.maxX))
        let maxY = min(1, max(0, rect.maxY))
        guard maxX > minX, maxY > minY else { return nil }
        let mapped = CGRect(x: region.minX + minX * region.width,
                            y: region.minY + minY * region.height,
                            width: (maxX - minX) * region.width,
                            height: (maxY - minY) * region.height)
        return SourceRect(rect: mapped)
    }

    static func stableBlockID(documentSHA256: String,
                              pageIndex: Int,
                              sourceText: String,
                              pageRect: SourceRect?,
                              regionRect: SourceRect,
                              observationOrdinal: Int) -> String {
        let location = pageRect.map(quantizedIdentity) ?? "region:\(quantizedIdentity(regionRect)):\(observationOrdinal)"
        let textHash = SHA256.hash(data: Data(sourceText.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let identity = "ocr-block-v1|\(documentSHA256)|\(pageIndex)|\(location)|\(textHash)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "ocr-\(digest)"
    }

    /// Removes only same-text rows with strong spatial overlap. Identical
    /// text in separate columns remains separate because the boxes do not
    /// overlap sufficiently.
    static func deduplicatedLines(_ lines: [OCRLine]) -> [OCRLine] {
        let ordered = lines.sorted(by: stableReadingOrder)
        var result: [OCRLine] = []
        for candidate in ordered {
            guard let rect = candidate.pageRect?.cgRect else {
                result.append(candidate)
                continue
            }
            if let index = result.firstIndex(where: { existing in
                guard existing.sourceText == candidate.sourceText,
                      let other = existing.pageRect?.cgRect else { return false }
                let intersection = rect.intersection(other)
                guard !intersection.isNull, !intersection.isInfinite else { return false }
                let smallerArea = min(rect.width * rect.height, other.width * other.height)
                guard smallerArea.isFinite, smallerArea > 0 else { return false }
                return intersection.width * intersection.height / smallerArea >= 0.65
            }) {
                if candidate.confidence > result[index].confidence {
                    result[index] = candidate
                }
            } else {
                result.append(candidate)
            }
        }
        return result.sorted(by: stableReadingOrder)
    }

    private static func stableReadingOrder(_ lhs: OCRLine, _ rhs: OCRLine) -> Bool {
        switch (lhs.pageRect, rhs.pageRect) {
        case let (left?, right?):
            if left.y != right.y { return left.y > right.y } // PDF media coordinates start at bottom-left.
            if left.x != right.x { return left.x < right.x }
            if left.height != right.height { return left.height > right.height }
            if left.width != right.width { return left.width > right.width }
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): break
        }
        if lhs.sourceText != rhs.sourceText { return lhs.sourceText < rhs.sourceText }
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        return lhs.blockID < rhs.blockID
    }

    private static func quantizedIdentity(_ rect: SourceRect) -> String {
        [rect.x, rect.y, rect.width, rect.height].map { value in
            let scaled = value * 10
            if scaled.isFinite, abs(scaled) < Double(Int64.max) {
                return String(Int64(scaled.rounded(.toNearestOrAwayFromZero)))
            }
            return String(value.bitPattern, radix: 16)
        }.joined(separator: ",")
    }
}
