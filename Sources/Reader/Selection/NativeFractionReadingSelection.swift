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

    /// Maps all fraction glyphs from a verified glyph midpoint, then checks that
    /// both rows map back to exact source coverage before parsing the fraction.
    static func build(fraction: NativeFractionLayout.Fraction,
                      on page: PDFPage) -> NativeFractionReadingSelection? {
        let ordered = fraction.orderedGlyphs
        guard let anchorGlyph = ordered.first else { return nil }

        let anchor = page.characterIndex(at: CGPoint(x: anchorGlyph.glyph.rect.midX,
                                                     y: anchorGlyph.glyph.rect.midY))
        guard anchor >= 0,
              let mapping = NativeMathGlyphSelection.map(ordered.map(\.glyph),
                                                         on: page,
                                                         anchoredAt: anchor),
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

        let formulaLatex = "\\frac{\(numeratorInput)}{\(denominatorInput)}"
        guard let parsed = MathReadingService.resolve(formulaLatex),
              parsed.status == .parsedText,
              parsed.ast?.isComplete == true,
              isSingleCompleteFraction(parsed.ast),
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

        let displayText = "(\(numeratorText))/(\(denominatorText))"
        let result = MathReadingResult(sourceText: displayText,
                                       latex: parsed.latex,
                                       unicode: parsed.unicode,
                                       explanation: parsed.explanation,
                                       status: parsed.status,
                                       ast: parsed.ast)
        let whole = Detail(scope: .whole,
                           selection: mapping.mergedSelection,
                           sourceRanges: mapping.ranges,
                           sourceText: displayText,
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
        guard let merged = NativeMathGlyphSelection.merge(entries, on: page) else { return nil }
        return Detail(scope: scope,
                      selection: merged.selection,
                      sourceRanges: merged.ranges,
                      sourceText: sourceText,
                      readingResult: readingResult)
    }

    private static func safeParserText(_ displayText: String) -> String? {
        var parserText = ""
        parserText.reserveCapacity(displayText.utf16.count)
        for scalar in displayText.unicodeScalars {
            if scalar.value == 0x2212 { // U+2212 PDF minus; preserve it in sourceText.
                parserText.append("-")
                continue
            }
            guard scalar.value < 128 else { return nil }
            let value = scalar.value
            let isLetter = (65...90).contains(value) || (97...122).contains(value)
            let isDigit = (48...57).contains(value)
            let symbol = Character(scalar)
            guard isLetter || isDigit || "+-*/().[]<>=".contains(symbol) else { return nil }
            parserText.unicodeScalars.append(scalar)
        }
        guard !parserText.isEmpty,
              !hasLongASCIIWord(parserText),
              !hasSentencePunctuation(parserText),
              hasBalancedGroups(parserText) else { return nil }
        return parserText
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
        guard let parsed = MathReadingService.resolve(parserText),
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
        for index in characters.indices where ",;:!?".contains(characters[index]) { return true }
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
