import UIKit
import PDFKit

/// A conservative geometry-only candidate for a simple, vertically stacked fraction.
/// It preserves PDFTextLayout's source glyphs and indices; it does not infer math meaning.
struct NativeFractionLayout {
    enum RowPosition: Equatable {
        case numerator
        case denominator
    }

    struct GlyphReference {
        let sourceIndex: Int
        let glyph: PDFTextLayout.Glyph
    }

    struct Row {
        let region: CGRect
        /// Original glyphs ordered left-to-right, with their positions in the scanned page.
        let glyphs: [GlyphReference]
    }

    enum Hit {
        case glyph(sourceIndex: Int, row: RowPosition)
        case row(row: RowPosition)
        case rule
        case fraction
    }

    struct Fraction {
        let region: CGRect
        let rule: PDFTextLayout.HorizontalRule
        let numerator: Row
        let denominator: Row
        fileprivate let ruleRegion: CGRect
        fileprivate let ruleY: CGFloat

        /// Visual reading order; every item still refers to its untouched source glyph.
        var orderedGlyphs: [GlyphReference] { numerator.glyphs + denominator.glyphs }

        /// Hit testing stays inside exact PDF geometry. Where text boxes overlap vertically,
        /// the point's side of the bar selects the numerator or denominator.
        func hitTest(_ pagePoint: CGPoint) -> Hit? {
            guard pagePoint.x.isFinite, pagePoint.y.isFinite, region.contains(pagePoint) else { return nil }
            if ruleRegion.contains(pagePoint) { return .rule }

            let position: RowPosition
            let row: Row
            if pagePoint.y > ruleY {
                position = .numerator
                row = numerator
            } else if pagePoint.y < ruleY {
                position = .denominator
                row = denominator
            } else {
                return .fraction
            }

            guard row.region.contains(pagePoint) else { return .fraction }
            let matchingGlyphs = row.glyphs.filter { $0.glyph.rect.contains(pagePoint) }
            if matchingGlyphs.count == 1, let glyph = matchingGlyphs.first {
                return .glyph(sourceIndex: glyph.sourceIndex, row: position)
            }
            return .row(row: position)
        }
    }

    private struct PositionedGlyph {
        let reference: GlyphReference
        var rect: CGRect { reference.glyph.rect }
        var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
        var baseline: CGPoint { reference.glyph.baseline }
    }

    private struct RowCandidate {
        let row: Row
    }

    private static let maximumGlyphsPerRow = 12
    private static let maximumNearbyGlyphsPerRule = 64
    private static let maximumHorizontalSliceGlyphs = 4_096
    private static let allowedSymbols = Set("+-−×·÷=*/^_(),.[]{}<>≤≥≠≈±")

    /// Finds only isolated horizontal rules with one unambiguous, compact row on each side.
    static func detect(in scan: PDFTextLayout.PageScan) -> [Fraction] {
        let glyphs = scan.glyphs.enumerated().compactMap { index, glyph -> PositionedGlyph? in
            guard validRect(glyph.rect),
                  glyph.baseline.x.isFinite, glyph.baseline.y.isFinite,
                  isSimpleMathToken(glyph.text) else { return nil }
            return PositionedGlyph(reference: GlyphReference(sourceIndex: index, glyph: glyph))
        }.sorted { $0.center.x < $1.center.x }

        var candidates: [Fraction] = []
        for rule in scan.horizontalRules {
            guard let geometry = ruleGeometry(rule) else { continue }
            guard let localGlyphs = nearbyGlyphs(glyphs, rule: geometry) else { continue }
            guard let numerator = rowCandidates(localGlyphs, side: 1, rule: geometry),
                  let denominator = rowCandidates(localGlyphs, side: -1, rule: geometry),
                  numerator.count == 1,
                  denominator.count == 1 else { continue }

            let top = numerator[0].row
            let bottom = denominator[0].row
            let usedIndices = Set(top.glyphs.map(\.sourceIndex))
            guard bottom.glyphs.allSatisfy({ !usedIndices.contains($0.sourceIndex) }) else { continue }

            let region = top.region.union(bottom.region).union(geometry.rect)
            candidates.append(Fraction(region: region,
                                       rule: rule,
                                       numerator: top,
                                       denominator: bottom,
                                       ruleRegion: geometry.rect,
                                       ruleY: geometry.y))
        }

        candidates.sort {
            let left = ($0.rule.start.x + $0.rule.end.x) * 0.5
            let right = ($1.rule.start.x + $1.rule.end.x) * 0.5
            return left < right
        }

        // Do not let neighboring rules claim the same source glyph. Such geometry is ambiguous.
        var claimCounts: [Int: Int] = [:]
        for candidate in candidates {
            for index in Set(candidate.orderedGlyphs.map(\.sourceIndex)) {
                claimCounts[index, default: 0] += 1
            }
        }
        return candidates.filter { candidate in
            candidate.orderedGlyphs.allSatisfy { claimCounts[$0.sourceIndex] == 1 }
        }
    }

    private struct RuleGeometry {
        let minX: CGFloat
        let maxX: CGFloat
        let x: CGFloat
        let y: CGFloat
        let length: CGFloat
        let width: CGFloat
        let rect: CGRect
    }

    private static func ruleGeometry(_ rule: PDFTextLayout.HorizontalRule) -> RuleGeometry? {
        guard rule.start.x.isFinite, rule.start.y.isFinite,
              rule.end.x.isFinite, rule.end.y.isFinite,
              rule.lineWidth.isFinite, rule.lineWidth > 0 else { return nil }
        let minX = min(rule.start.x, rule.end.x)
        let maxX = max(rule.start.x, rule.end.x)
        let length = maxX - minX
        let y = (rule.start.y + rule.end.y) * 0.5
        let width = rule.lineWidth
        guard length > 0, abs(rule.end.y - rule.start.y) <= max(width, 0.5) else { return nil }
        return RuleGeometry(minX: minX,
                            maxX: maxX,
                            x: (minX + maxX) * 0.5,
                            y: y,
                            length: length,
                            width: width,
                            rect: CGRect(x: minX, y: y - width * 0.5, width: length, height: width))
    }

    private static func nearbyGlyphs(_ glyphs: [PositionedGlyph],
                                     rule: RuleGeometry) -> [PositionedGlyph]? {
        // A valid row can extend at most 2.5 rule lengths and remain centered within
        // 0.35 rule lengths. The 1.65-length radius also covers glyph-height padding
        // under the later minimum line-to-glyph scale check.
        let padding = rule.length * 1.65
        let lower = lowerBound(glyphs, centerX: rule.minX - padding)
        let upper = upperBound(glyphs, centerX: rule.maxX + padding)
        guard upper - lower <= maximumHorizontalSliceGlyphs else { return nil }
        return Array(glyphs[lower..<upper])
    }

    private static func lowerBound(_ glyphs: [PositionedGlyph], centerX: CGFloat) -> Int {
        var low = 0, high = glyphs.count
        while low < high {
            let middle = low + (high - low) / 2
            if glyphs[middle].center.x < centerX { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func upperBound(_ glyphs: [PositionedGlyph], centerX: CGFloat) -> Int {
        var low = 0, high = glyphs.count
        while low < high {
            let middle = low + (high - low) / 2
            if glyphs[middle].center.x <= centerX { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func rowCandidates(_ glyphs: [PositionedGlyph],
                                      side: CGFloat,
                                      rule: RuleGeometry) -> [RowCandidate]? {
        var nearby: [PositionedGlyph] = []
        for glyph in glyphs {
            let height = glyph.rect.height
            let signedCenter = (glyph.center.y - rule.y) * side
            let xPadding = max(rule.length * 1.65, height * 0.55)
            let inHorizontalWindow = glyph.center.x >= rule.minX - xPadding
                && glyph.center.x <= rule.maxX + xPadding
            let nearRule = signedCenter > 0
                && signedCenter <= height * 1.05 + rule.width * 1.5
            guard inHorizontalWindow, nearRule else { continue }
            guard nearby.count < maximumNearbyGlyphsPerRule else { return nil }
            nearby.append(glyph)
        }
        guard !nearby.isEmpty else { return [] }

        let clusters = baselineClusters(nearby)
        var rows: [RowCandidate] = []
        for cluster in clusters {
            for component in horizontalComponents(cluster, ruleLength: rule.length) {
                if let row = makeRowCandidate(component, side: side, rule: rule) {
                    rows.append(row)
                }
            }
        }
        return rows
    }

    private static func baselineClusters(_ glyphs: [PositionedGlyph]) -> [[PositionedGlyph]] {
        let ordered = glyphs.sorted { $0.baseline.y > $1.baseline.y }
        var clusters: [[PositionedGlyph]] = []
        for glyph in ordered {
            let matching = clusters.indices.min { lhs, rhs in
                abs(glyph.baseline.y - median(clusters[lhs].map(\.baseline.y)))
                    < abs(glyph.baseline.y - median(clusters[rhs].map(\.baseline.y)))
            }
            if let matching {
                let height = min(glyph.rect.height, median(clusters[matching].map { $0.rect.height }))
                let tolerance = max(0.8, height * 0.22)
                if abs(glyph.baseline.y - median(clusters[matching].map(\.baseline.y))) <= tolerance {
                    clusters[matching].append(glyph)
                    continue
                }
            }
            clusters.append([glyph])
        }
        return clusters
    }

    private static func horizontalComponents(_ glyphs: [PositionedGlyph],
                                             ruleLength: CGFloat) -> [[PositionedGlyph]] {
        let ordered = glyphs.sorted { $0.rect.minX < $1.rect.minX }
        guard let first = ordered.first else { return [] }
        var components: [[PositionedGlyph]] = [[first]]
        for glyph in ordered.dropFirst() {
            guard let previous = components[components.count - 1].last else { continue }
            let height = min(glyph.rect.height, previous.rect.height)
            let maximumGap = max(height * 0.8, ruleLength * 0.45)
            if glyph.rect.minX - previous.rect.maxX <= maximumGap {
                components[components.count - 1].append(glyph)
            } else {
                components.append([glyph])
            }
        }
        return components
    }

    private static func makeRowCandidate(_ glyphs: [PositionedGlyph],
                                         side: CGFloat,
                                         rule: RuleGeometry) -> RowCandidate? {
        guard !glyphs.isEmpty, glyphs.count <= maximumGlyphsPerRow else { return nil }
        let ordered = glyphs.sorted { $0.rect.minX < $1.rect.minX }
        guard let first = ordered.first else { return nil }
        let rect = ordered.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        let medianHeight = median(glyphs.map { $0.rect.height })
        guard medianHeight > 0,
              rule.length / medianHeight >= 0.35,
              rule.length / medianHeight <= 4.0,
              rule.width / medianHeight <= 0.25 else { return nil }

        let centerY = median(glyphs.map { $0.center.y })
        let baselineY = median(glyphs.map { $0.baseline.y })
        let signedCenter = (centerY - rule.y) * side
        let minimumSideDistance = max(rule.width * 0.5, medianHeight * 0.06)
        let maximumVerticalDistance = medianHeight * 1.05 + rule.width * 1.5
        guard signedCenter >= minimumSideDistance,
              signedCenter <= maximumVerticalDistance,
              abs(baselineY - rule.y) <= maximumVerticalDistance,
              abs(baselineY - centerY) <= medianHeight * 0.8 + rule.width else { return nil }

        let rowWidth = rect.width
        guard rowWidth > 0,
              rowWidth / rule.length <= 2.5,
              rule.length / rowWidth <= 3.5 else { return nil }
        let overlap = max(0, min(rect.maxX, rule.maxX) - max(rect.minX, rule.minX))
        guard overlap / min(rowWidth, rule.length) >= 0.55 else { return nil }
        let maximumCenterOffset = max(rule.length * 0.35, medianHeight * 0.35)
        guard abs(rect.midX - rule.x) <= maximumCenterOffset else { return nil }

        let references = ordered.map(\.reference)
        let row = Row(region: rect, glyphs: references)
        return RowCandidate(row: row)
    }

    private static func isSimpleMathToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || allowedSymbols.contains(Character(scalar))
        }
    }

    private static func validRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) * 0.5
        }
        return sorted[middle]
    }
}
