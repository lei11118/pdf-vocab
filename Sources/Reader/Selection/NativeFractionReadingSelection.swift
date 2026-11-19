import Foundation
import PDFKit

/// Connects one verified native fraction layout to exact PDFKit source selections
/// and a parser-verified reading result. It does not infer missing glyphs.
struct NativeFractionReadingSelection {
    enum Scope {
        case whole
        case row(NativeFractionLayout.RowPosition)
        case glyph(row: NativeFractionLayout.RowPosition, sourceIndex: Int)
    }

    struct Detail {
        let scope: Scope
        let selection: PDFSelection
        let sourceRanges: [NSRange]
        let sourceText: String
        let readingResult: MathReadingResult?
    }

    private struct GlyphDetail {
        let row: NativeFractionLayout.RowPosition
        let sourceIndex: Int
        let detail: Detail
    }

    let whole: Detail
    private let numerator: Detail
    private let denominator: Detail
    private let glyphs: [GlyphDetail]
    private let subrows: [[Int]: Detail]

    static func geometryResult(for fraction: NativeFractionLayout.Fraction) -> MathReadingResult? {
        guard let numerator = parserInput(for: fraction.numerator),
              let denominator = parserInput(for: fraction.denominator),
              let parsed = MathReadingService.resolve("\\frac{\(numerator)}{\(denominator)}"),
              parsed.status == .parsedText, isSingleCompleteFraction(parsed.ast) else { return nil }
        return MathReadingResult(sourceText: "(\(surface(of: fraction.numerator)))/(\(surface(of: fraction.denominator)))",
                                 latex: parsed.latex, unicode: parsed.unicode, explanation: parsed.explanation,
                                 status: parsed.status, ast: parsed.ast)
    }

    static func geometryDetail(for hit: NativeFractionLayout.Hit,
                               fraction: NativeFractionLayout.Fraction) -> FormulaCircleDetail? {
        let row: NativeFractionLayout.Row
        switch hit {
        case .fraction, .rule:
            guard let result = geometryResult(for: fraction) else { return nil }
            return FormulaCircleDetail(region: fraction.region, result: result)
        case .glyph(let sourceIndex, _):
            guard let glyph = fraction.orderedGlyphs.first(where: { $0.sourceIndex == sourceIndex })?.glyph
            else { return nil }
            return FormulaCircleDetail(region: glyph.rect, result: MathSymbolReading.detail(glyph.text), isGlyph: true)
        case .row(let position):
            row = position == .numerator ? fraction.numerator : fraction.denominator
        case .subrow(let indices):
            guard let found = (descendants(of: fraction.numerator) + descendants(of: fraction.denominator))
                .first(where: { $0.glyphs.map(\.sourceIndex) == indices }) else { return nil }
            row = found
        }
        guard let parser = parserInput(for: row),
              let result = rowResult(sourceText: surface(of: row), parserText: parser) else { return nil }
        return FormulaCircleDetail(region: row.region, result: result)
    }

    /// Maps all fraction glyphs from a verified glyph midpoint, then checks that
    /// both rows map back to exact source coverage before parsing the fraction.
    static func build(fraction: NativeFractionLayout.Fraction,
                      on page: PDFPage) -> NativeFractionReadingSelection? {
        let ordered = fraction.orderedGlyphs
        guard let anchorGlyph = ordered.first else { return nil }

        let anchorPoint = CGPoint(x: anchorGlyph.glyph.rect.midX, y: anchorGlyph.glyph.rect.midY)
        let pointIndex = page.characterIndex(at: anchorPoint)
        let areaIndex = page.selection(for: fraction.region).flatMap { selection -> Int? in
            guard selection.numberOfTextRanges(on: page) > 0 else { return nil }
            return selection.range(at: 0, on: page).location
        }
        let anchors = [pointIndex, areaIndex ?? NSNotFound].filter { $0 >= 0 && $0 != NSNotFound }
        let glyphsForMapping = ordered.map(\.glyph)
        guard let mapping = anchors.lazy.compactMap({
            NativeMathGlyphSelection.map(glyphsForMapping, on: page, anchoredAt: $0,
                                         allowingInterveningWhitespace: true)
        }).first,
              mapping.entries.count == ordered.count,
              mapping.entries.enumerated().allSatisfy({ $0.offset == $0.element.glyphIndex }) else {
            return nil
        }

        let numeratorCount = fraction.numerator.glyphs.count
        guard numeratorCount > 0,
              numeratorCount < mapping.entries.count else { return nil }
        let numeratorEntries = Array(mapping.entries.prefix(numeratorCount))
        let denominatorEntries = Array(mapping.entries.dropFirst(numeratorCount))
        let numeratorText = surface(of: fraction.numerator)
        let denominatorText = surface(of: fraction.denominator)
        guard let numeratorInput = parserInput(for: fraction.numerator),
              let denominatorInput = parserInput(for: fraction.denominator) else { return nil }

        guard let result = geometryResult(for: fraction),
              let numeratorDetail = makeDetail(scope: .row(.numerator),
                                               entries: numeratorEntries,
                                               sourceText: numeratorText,
                                               readingResult: rowResult(sourceText: numeratorText,
                                                                        parserText: numeratorInput),
                                               on: page),
              let denominatorDetail = makeDetail(scope: .row(.denominator),
                                                 entries: denominatorEntries,
                                                 sourceText: denominatorText,
                                                 readingResult: rowResult(sourceText: denominatorText,
                                                                          parserText: denominatorInput),
                                                 on: page) else { return nil }

        let whole = Detail(scope: .whole,
                           selection: mapping.mergedSelection,
                           sourceRanges: mapping.ranges,
                           sourceText: result.sourceText,
                           readingResult: result)

        var glyphDetails: [GlyphDetail] = []
        for entry in mapping.entries {
            let reference = ordered[entry.glyphIndex]
            let row: NativeFractionLayout.RowPosition = entry.glyphIndex < numeratorCount
                ? .numerator : .denominator
            guard let detail = makeDetail(scope: .glyph(row: row, sourceIndex: reference.sourceIndex),
                                          entries: [entry],
                                          sourceText: reference.glyph.text,
                                          readingResult: nil,
                                          on: page) else { return nil }
            glyphDetails.append(GlyphDetail(row: row,
                                            sourceIndex: reference.sourceIndex,
                                            detail: detail))
        }

        let entriesByIndex = Dictionary(uniqueKeysWithValues: zip(ordered.map(\.sourceIndex), mapping.entries))
        var subrows: [[Int]: Detail] = [:]
        for (position, row) in [(NativeFractionLayout.RowPosition.numerator, fraction.numerator),
                                (.denominator, fraction.denominator)] {
            for nested in descendants(of: row) {
                let indices = nested.glyphs.map(\.sourceIndex)
                let entries = indices.compactMap { entriesByIndex[$0] }
                guard entries.count == indices.count, let parser = parserInput(for: nested) else { return nil }
                let text = surface(of: nested)
                guard let detail = makeDetail(scope: .row(position), entries: entries,
                                              sourceText: text, readingResult: rowResult(sourceText: text, parserText: parser),
                                              on: page) else { return nil }
                subrows[indices] = detail
            }
        }
        return NativeFractionReadingSelection(whole: whole,
                                              numerator: numeratorDetail,
                                              denominator: denominatorDetail,
                                              glyphs: glyphDetails,
                                              subrows: subrows)
    }

    /// Preserves the distinction needed by the reader: full fraction, one row,
    /// or one exact source glyph. Rule hits address the full fraction text.
    func detail(for hit: NativeFractionLayout.Hit) -> Detail? {
        switch hit {
        case .fraction, .rule:
            return whole
        case .row(.numerator):
            return numerator
        case .row(.denominator):
            return denominator
        case .subrow(let indices):
            return subrows[indices]
        case .glyph(let sourceIndex, let row):
            return glyphs.first {
                $0.row == row && $0.sourceIndex == sourceIndex
            }?.detail
        }
    }

    private static func descendants(of row: NativeFractionLayout.Row) -> [NativeFractionLayout.Row] {
        guard let nested = row.nestedFraction else { return [] }
        return [nested.numerator, nested.denominator]
            + descendants(of: nested.numerator) + descendants(of: nested.denominator)
    }

    private static func surface(of row: NativeFractionLayout.Row) -> String {
        if let nested = row.nestedFraction {
            return "(\(surface(of: nested.numerator)))/(\(surface(of: nested.denominator)))"
        }
        return row.glyphs.map { $0.glyph.text }.joined()
    }

    private static func parserInput(for row: NativeFractionLayout.Row) -> String? {
        guard let nested = row.nestedFraction else { return safeParserText(surface(of: row)) }
        guard let numerator = parserInput(for: nested.numerator),
              let denominator = parserInput(for: nested.denominator) else { return nil }
        return "\\frac{\(numerator)}{\(denominator)}"
    }

    private static func makeDetail(scope: Scope,
                                   entries: [NativeMathGlyphSelection.Entry],
                                   sourceText: String,
                                   readingResult: MathReadingResult?,
                                   on page: PDFPage) -> Detail? {
        guard let merged = NativeMathGlyphSelection.merge(entries, on: page, allowingInterveningWhitespace: true)
        else { return nil }
        return Detail(scope: scope,
                      selection: merged.selection,
                      sourceRanges: merged.ranges,
                      sourceText: sourceText,
                      readingResult: readingResult)
    }

    static func safeParserText(_ displayText: String) -> String? {
        guard !hasLongASCIIWord(displayText),
              !hasSentencePunctuation(displayText),
              hasBalancedGroups(displayText) else { return nil }
        return MathReadingService.latexForLayoutFragment(displayText)
    }

    private static func rowResult(sourceText: String, parserText: String) -> MathReadingResult? {
        if parserText.count > 1,
           parserText.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) {
            return MathReadingResult(sourceText: sourceText,
                                     latex: parserText,
                                     unicode: sourceText,
                                     explanation: "数字 \(sourceText)；它在公式中的位置决定它表示常数、系数还是索引。",
                                     status: .parsedText,
                                     ast: .number(parserText))
        }
        guard let parsed = MathReadingService.resolveVerifiedFragment(parserText),
              parsed.status == .parsedText,
              parsed.ast?.isComplete == true else { return nil }
        return MathReadingResult(sourceText: sourceText,
                                 latex: parsed.latex,
                                 unicode: parsed.unicode,
                                 explanation: parsed.explanation,
                                 status: parsed.status,
                                 ast: parsed.ast)
    }

    private static func hasLongASCIIWord(_ text: String) -> Bool {
        var runLength = 0
        for scalar in text.unicodeScalars {
            let isLetter = (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
            runLength = isLetter ? runLength + 1 : 0
            if runLength > 3 { return true }
        }
        return false
    }

    private static func hasSentencePunctuation(_ text: String) -> Bool {
        let characters = Array(text)
        var depth = 0
        for character in characters {
            if "([".contains(character) { depth += 1 }
            if ")]".contains(character) { depth -= 1 }
            if character == ",", depth == 0 { return true }
        }
        for index in characters.indices where characters[index] == "." {
            let beforeIsDigit = index > 0 && characters[index - 1].wholeNumberValue != nil
            let afterIsDigit = index + 1 < characters.count && characters[index + 1].wholeNumberValue != nil
            if !beforeIsDigit || !afterIsDigit { return true }
        }
        return false
    }

    private static func hasBalancedGroups(_ text: String) -> Bool {
        var stack: [Character] = []
        for character in text {
            switch character {
            case "(", "[": stack.append(character)
            case ")", "]":
                guard let opener = stack.popLast() else { return false }
                let expected: Character = opener == "(" ? ")" : "]"
                guard character == expected else { return false }
            default: break
            }
        }
        return stack.isEmpty
    }

    private static func isSingleCompleteFraction(_ node: MathExpressionNode?) -> Bool {
        guard case .sequence(let children) = node,
              children.count == 1,
              case .fraction(let numerator, let denominator, _) = children[0] else { return false }
        return numerator.isComplete && denominator.isComplete
    }
}
