import PDFKit

struct FormulaCircleDetail {
    let selection: PDFSelection?
    let region: CGRect
    let readingResult: MathReadingResult?
    let fractionDetail: NativeFractionReadingSelection.Detail?
    let isGlyph: Bool

    init(selection: PDFSelection?, region: CGRect,
         readingResult: MathReadingResult?, fractionDetail: NativeFractionReadingSelection.Detail?, isGlyph: Bool) {
        self.selection = selection
        self.region = region
        self.readingResult = readingResult
        self.fractionDetail = fractionDetail
        self.isGlyph = isGlyph
    }

    init(region: CGRect, result: MathReadingResult, isGlyph: Bool = false) {
        self.init(selection: nil, region: region,
                  readingResult: result, fractionDetail: nil, isGlyph: isGlyph)
    }

    init(fraction: NativeFractionReadingSelection.Detail, region: CGRect, isGlyph: Bool = false) {
        self.init(selection: fraction.selection, region: region,
                  readingResult: fraction.readingResult, fractionDetail: fraction, isGlyph: isGlyph)
    }

    init(fraction: NativeFractionReadingSelection.Detail, layout: NativeFractionLayout.Fraction, on page: PDFPage) {
        switch fraction.scope {
        case .whole:
            self.init(fraction: fraction, region: layout.region)
        case .row:
            self.init(fraction: fraction, region: SelectionGeometry.placedBounds(of: fraction.selection, on: page))
        case .glyph(_, let sourceIndex):
            let region = layout.orderedGlyphs.first { $0.sourceIndex == sourceIndex }?.glyph.rect
                ?? fraction.selection.bounds(for: page)
            self.init(fraction: fraction, region: region, isGlyph: true)
        }
    }
}

/// A single visual equation assembled from exact PDF glyphs and stacked fraction bars.
struct NativeEquationCircleSelection {
    private struct FractionPart {
        let layout: NativeFractionLayout.Fraction
        let result: MathReadingResult
    }

    let whole: FormulaCircleDetail
    private let fractions: [FractionPart]
    private let inlineGlyphs: [PDFTextLayout.Glyph]

    static func build(glyphs: [PDFTextLayout.Glyph], enclosedIndices: Set<Int>,
                      fractions: [NativeFractionLayout.Fraction]) -> Self? {
        guard !fractions.isEmpty, enclosedIndices.count <= 64 else { return nil }
        let fractionIndices = fractions.flatMap { $0.orderedGlyphs.map(\.sourceIndex) }
        let claimed = Set(fractionIndices)
        guard claimed.count == fractionIndices.count, claimed.isSubset(of: enclosedIndices) else { return nil }
        let inline = enclosedIndices.subtracting(claimed).map { glyphs[$0] }.sorted { $0.rect.midX < $1.rect.midX }
        // A sentence period after a stacked fraction is outside the equation.
        var equationGlyphs = inline
        if let period = inline.last, period.text == ".",
           let finalFractionEdge = fractions.map(\.region.maxX).max(),
           let precedingGlyph = inline.dropLast().last,
           precedingGlyph.rect.maxX <= finalFractionEdge, finalFractionEdge <= period.rect.midX {
            equationGlyphs.removeLast()
        }
        guard let equal = equationGlyphs.first(where: { $0.text == "=" }),
              let layout = inlineLayout(equationGlyphs, baseline: equal.baseline.y, fontHeight: equal.rect.height),
              fractions.allSatisfy({ fraction in
                  let barY = (fraction.rule.start.y + fraction.rule.end.y) / 2
                  return abs(barY - equal.rect.midY) <= max(2, equal.rect.height * 0.45)
              }) else { return nil }

        let parts = fractions.compactMap { fraction in
            NativeFractionReadingSelection.geometryResult(for: fraction).map {
                FractionPart(layout: fraction, result: $0)
            }
        }
        guard parts.count == fractions.count else { return nil }
        var components = parts.enumerated().map {
            (x: $0.element.layout.region.midX, glyph: nil as PDFTextLayout.Glyph?, fraction: $0.offset)
        }
        components += layout.map { (x: $0.rect.midX, glyph: $0, fraction: -1) }
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
            let reading = parts[component.fraction].result
            guard let fractionLatex = reading.latex else { return nil }
            surface += reading.sourceText
            latex += fractionLatex
        }
        if !fragment.isEmpty {
            guard let converted = NativeFractionReadingSelection.safeParserText(fragment) else { return nil }
            surface += fragment
            latex += converted
        }
        guard let result = MathReadingService.resolve(latex), result.status == .parsedText else { return nil }

        let region = equationGlyphs.reduce(fractions.reduce(CGRect.null) { $0.union($1.region) }) { $0.union($1.rect) }
        let original = MathReadingResult(sourceText: surface, latex: result.latex, unicode: result.unicode,
                                         explanation: result.explanation, status: result.status, ast: result.ast)
        return Self(whole: FormulaCircleDetail(region: region, result: original), fractions: parts, inlineGlyphs: equationGlyphs)
    }

    // Large parentheses may be drawn as two glyphs, and ordinary digits can be
    // raised by a separate PDF text matrix. Preserve their source boxes for taps.
    private static func inlineLayout(_ glyphs: [PDFTextLayout.Glyph], baseline: CGFloat,
                                     fontHeight: CGFloat) -> [PDFTextLayout.Glyph]? {
        let baselineTolerance = max(1.5, fontHeight * 0.20)
        let digits = Dictionary(uniqueKeysWithValues: zip("0123456789", "⁰¹²³⁴⁵⁶⁷⁸⁹"))
        var pending = glyphs.sorted { $0.rect.midX < $1.rect.midX }
        var output: [PDFTextLayout.Glyph] = []
        while let first = pending.first {
            pending.removeFirst()
            let text: String
            var bounds = first.rect
            if ["⎛", "⎝", "⎞", "⎠"].contains(first.text) {
                let isLeft = first.text == "⎛" || first.text == "⎝"
                let isUpper = first.text == "⎛" || first.text == "⎞"
                let mate = isLeft ? (isUpper ? "⎝" : "⎛") : (isUpper ? "⎠" : "⎞")
                guard let next = pending.first, next.text == mate,
                      abs(next.rect.midX - first.rect.midX) <= max(0.7, first.rect.width * 0.2),
                      (isUpper ? first.rect.midY > next.rect.midY : first.rect.midY < next.rect.midY),
                      abs(next.rect.midY - first.rect.midY) <= fontHeight * 1.25 else { return nil }
                pending.removeFirst()
                bounds = bounds.union(next.rect)
                text = isLeft ? "(" : ")"
            } else if abs(first.baseline.y - baseline) <= baselineTolerance {
                text = first.text
            } else {
                let rise = first.baseline.y - baseline
                guard let last = output.last, let base = last.text.last,
                      base.isLetter || base.isNumber || ")]".contains(base),
                      rise > baselineTolerance, rise <= fontHeight * 0.9,
                      first.rect.height <= fontHeight * 0.95,
                      first.rect.minX - last.rect.maxX <= fontHeight * 0.36,
                      let digit = first.text.first, first.text.count == 1,
                      let superscript = digits[digit] else { return nil }
                text = String(superscript)
            }
            output.append(.init(text: text, rect: bounds, baseline: first.baseline))
        }
        return output
    }

    func detail(at point: CGPoint) -> FormulaCircleDetail? {
        let glyphs = inlineGlyphs.filter { $0.rect.contains(point) }
        if let glyph = glyphs.first, glyphs.count == 1 {
            return FormulaCircleDetail(region: glyph.rect, result: MathSymbolReading.detail(glyph.text), isGlyph: true)
        }
        let candidates = fractions.filter { $0.layout.region.contains(point) }
        guard candidates.count == 1, let part = candidates.first, let hit = part.layout.hitTest(point) else { return nil }
        return NativeFractionReadingSelection.geometryDetail(for: hit, fraction: part.layout)
    }
}
