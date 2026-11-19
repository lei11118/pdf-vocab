import PDFKit

/// A single visual equation assembled from exact PDF glyphs and stacked fraction bars.
struct NativeEquationCircleSelection {
    struct Detail {
        let selection: PDFSelection
        let sourceRanges: [NSRange]
        let region: CGRect
        let readingResult: MathReadingResult?
        let fractionDetail: NativeFractionReadingSelection.Detail?
        let isGlyph: Bool
    }

    private struct FractionPart {
        let layout: NativeFractionLayout.Fraction
        let reading: NativeFractionReadingSelection
    }

    let whole: Detail
    private let fractions: [FractionPart]
    private let inlineGlyphs: [NativeMathGlyphSelection.Entry]

    static func build(glyphs: [PDFTextLayout.Glyph], enclosedIndices: Set<Int>,
                      fractions: [NativeFractionLayout.Fraction], on page: PDFPage) -> Self? {
        guard !fractions.isEmpty, enclosedIndices.count <= 64 else { return nil }
        let fractionIndices = fractions.flatMap { $0.orderedGlyphs.map(\.sourceIndex) }
        let claimed = Set(fractionIndices)
        guard claimed.count == fractionIndices.count, claimed.isSubset(of: enclosedIndices) else { return nil }
        let inline = enclosedIndices.subtracting(claimed).map { glyphs[$0] }.sorted { $0.rect.midX < $1.rect.midX }
        guard let equal = inline.first(where: { $0.text == "=" }),
              inline.filter({ $0.text == "=" }).count == 1,
              inline.allSatisfy({ abs($0.baseline.y - equal.baseline.y) <= max(1.5, equal.rect.height * 0.20) }),
              fractions.allSatisfy({ fraction in
                  let barY = (fraction.rule.start.y + fraction.rule.end.y) / 2
                  return abs(barY - equal.rect.midY) <= max(2, equal.rect.height * 0.45)
              }) else { return nil }

        let parts = fractions.compactMap { fraction in
            NativeFractionReadingSelection.build(fraction: fraction, on: page).map {
                FractionPart(layout: fraction, reading: $0)
            }
        }
        guard parts.count == fractions.count else { return nil }
        var components = parts.enumerated().map {
            (x: $0.element.layout.region.midX, glyph: nil as PDFTextLayout.Glyph?, fraction: $0.offset)
        }
        components += inline.map { (x: $0.rect.midX, glyph: $0, fraction: -1) }
        components.sort { $0.x < $1.x }
        var surface = ""
        var latex = ""
        var fragment = ""
        for component in components {
            if let glyph = component.glyph {
                fragment += glyph.text
                continue
            }
            if !fragment.isEmpty {
                guard let converted = NativeFractionReadingSelection.safeParserText(fragment) else { return nil }
                surface += fragment
                latex += converted
                fragment = ""
            }
            guard let reading = parts[component.fraction].reading.whole.readingResult,
                  let fractionLatex = reading.latex else { return nil }
            surface += reading.sourceText
            latex += fractionLatex
        }
        if !fragment.isEmpty {
            guard let converted = NativeFractionReadingSelection.safeParserText(fragment) else { return nil }
            surface += fragment
            latex += converted
        }
        guard let result = MathReadingService.resolve(latex), result.status == .parsedText else { return nil }

        let all = inline + fractions.flatMap { $0.orderedGlyphs.map(\.glyph) }
        let anchor = page.characterIndex(at: CGPoint(x: equal.rect.midX, y: equal.rect.midY))
        guard let mapped = NativeMathGlyphSelection.map(all, on: page, anchoredAt: anchor,
                                                        allowingInterveningWhitespace: true) else { return nil }
        let region = inline.reduce(fractions.reduce(CGRect.null) { $0.union($1.region) }) { $0.union($1.rect) }
        let original = MathReadingResult(sourceText: surface, latex: result.latex, unicode: result.unicode,
                                         explanation: result.explanation, status: result.status, ast: result.ast)
        let whole = Detail(selection: mapped.mergedSelection, sourceRanges: mapped.ranges, region: region,
                           readingResult: original, fractionDetail: nil, isGlyph: false)
        return Self(whole: whole, fractions: parts, inlineGlyphs: Array(mapped.entries.prefix(inline.count)))
    }

    func detail(at point: CGPoint, on page: PDFPage) -> Detail? {
        let glyphs = inlineGlyphs.filter { $0.glyph.rect.contains(point) }
        if let glyph = glyphs.first, glyphs.count == 1 {
            let result = MathCardRouting.resolve(sourceText: glyph.glyph.text, contextReadingEnabled: true,
                                                 mathEnabled: true, isMathDetail: true)
            return Detail(selection: glyph.selection, sourceRanges: [glyph.sourceRange], region: glyph.glyph.rect,
                          readingResult: result, fractionDetail: nil, isGlyph: true)
        }
        let candidates = fractions.filter { $0.layout.region.contains(point) }
        guard candidates.count == 1, let part = candidates.first,
              let hit = part.layout.hitTest(point), let detail = part.reading.detail(for: hit) else { return nil }
        let region: CGRect
        let isGlyph: Bool
        switch detail.scope {
        case .whole:
            region = part.layout.region
            isGlyph = false
        case .row:
            region = SelectionGeometry.placedBounds(of: detail.selection, on: page)
            isGlyph = false
        case .glyph(_, let sourceIndex):
            region = part.layout.orderedGlyphs.first { $0.sourceIndex == sourceIndex }?.glyph.rect
                ?? detail.selection.bounds(for: page)
            isGlyph = true
        }
        return Detail(selection: detail.selection, sourceRanges: detail.sourceRanges, region: region,
                      readingResult: detail.readingResult, fractionDetail: detail, isGlyph: isGlyph)
    }
}
