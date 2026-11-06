import Foundation
import NaturalLanguage

enum SentenceContextKind: Equatable, Sendable {
    case completeSentence
    case fragment
}

/// A single-line sentence candidate tied to the exact OCR source and display
/// ranges that produced it. Source spans retain the caller-provided UTF-16
/// coordinate system; display spans are relative to `displayLineText`.
struct SentenceContext: Equatable, Sendable {
    let documentSHA256: String
    let pageIndex: Int
    let blockID: String
    let text: String
    let displayLineText: String
    let displaySentenceText: String
    let sourceSpan: UTF16Span
    let displaySpan: UTF16Span
    let selectedSourceSpans: [UTF16Span]
    let selectedDisplaySpans: [UTF16Span]
    let kind: SentenceContextKind
}

/// Builds a sentence candidate only when the fast display line can be mapped
/// to the original line without changing, dropping, or adding non-whitespace
/// composed characters.
enum SentenceContextBuilder {
    private struct Grapheme {
        let span: UTF16Span
        let surface: String
    }

    /// `sourceStartUTF16Offset` and every selected source span must use the
    /// same caller-defined UTF-16 coordinate system. This builder does not
    /// infer page-wide offsets. `ContextOCRSelectionSource` exposes line-local
    /// spans, so pass 0 when building from its OCR line text.
    static func build(sourceText: String,
                      sourceStartUTF16Offset: Int,
                      displayText: String,
                      selectedSourceSpans: [UTF16Span],
                      documentSHA256: String,
                      pageIndex: Int,
                      blockID: String) -> SentenceContext? {
        guard !sourceText.isEmpty, !displayText.isEmpty,
              sourceStartUTF16Offset >= 0,
              !documentSHA256.isEmpty, pageIndex >= 0, !blockID.isEmpty,
              !containsLineBreak(sourceText), !containsLineBreak(displayText),
              !selectedSourceSpans.isEmpty else { return nil }

        let sourceUTF16Length = (sourceText as NSString).length
        let displayUTF16Length = (displayText as NSString).length
        guard sourceUTF16Length <= OCRCharacterAligner.maximumUTF16Units,
              displayUTF16Length <= OCRCharacterAligner.maximumUTF16Units else { return nil }
        let (_, sourceEndOverflow) = sourceStartUTF16Offset.addingReportingOverflow(sourceUTF16Length)
        guard !sourceEndOverflow else { return nil }

        guard let sourceGraphemes = graphemes(in: sourceText),
              let displayGraphemes = graphemes(in: displayText) else { return nil }

        guard case .aligned(let alignment) = OCRCharacterAligner.align(source: sourceText,
                                                                        fast: displayText),
              let maps = exactBidirectionalMaps(alignment,
                                                sourceGraphemes: sourceGraphemes,
                                                displayGraphemes: displayGraphemes) else { return nil }

        let localSelections: [UTF16Span] = selectedSourceSpans.compactMap { providedSpan in
            guard let providedEnd = providedSpan.endExclusive,
                  providedSpan.length > 0,
                  providedSpan.location >= sourceStartUTF16Offset,
                  providedEnd <= sourceStartUTF16Offset + sourceUTF16Length else { return nil }
            let local = UTF16Span(location: providedSpan.location - sourceStartUTF16Offset,
                                  length: providedSpan.length)
            guard local.composedCharacterRange(in: sourceText) != nil else { return nil }
            return local
        }
        guard localSelections.count == selectedSourceSpans.count,
              localSelections.allSatisfy({ mappedDisplayRange(for: $0,
                                                               sourceGraphemes: sourceGraphemes,
                                                               displayGraphemes: displayGraphemes,
                                                               sourceToDisplay: maps.sourceToDisplay) != nil }) else { return nil }

        let sentenceRanges = sentenceRanges(in: sourceText)
        let containing = sentenceRanges.filter { range in
            localSelections.allSatisfy { contains(range, $0) }
        }
        guard containing.count == 1,
              let tokenizedRange = containing.first,
              let coreRange = trimmedRange(tokenizedRange,
                                           graphemes: sourceGraphemes,
                                           in: sourceText),
              localSelections.allSatisfy({ contains(coreRange, $0) }),
              let sourceCore = UTF16Span(range: coreRange, in: sourceText),
              let displayCore = mappedDisplayRange(for: sourceCore,
                                                   sourceGraphemes: sourceGraphemes,
                                                   displayGraphemes: displayGraphemes,
                                                   sourceToDisplay: maps.sourceToDisplay),
              let text = sourceCore.substring(in: sourceText),
              let displaySurface = displayCore.substring(in: displayText) else { return nil }

        let sourceSpan = UTF16Span(location: sourceStartUTF16Offset + sourceCore.location,
                                   length: sourceCore.length)
        let selectedDisplay = localSelections.compactMap {
            mappedDisplayRange(for: $0,
                               sourceGraphemes: sourceGraphemes,
                               displayGraphemes: displayGraphemes,
                               sourceToDisplay: maps.sourceToDisplay)
        }
        guard selectedDisplay.count == localSelections.count,
              sourceSpan.endExclusive != nil else { return nil }

        return SentenceContext(documentSHA256: documentSHA256,
                               pageIndex: pageIndex,
                               blockID: blockID,
                               text: text,
                               displayLineText: displayText,
                               displaySentenceText: displaySurface,
                               sourceSpan: sourceSpan,
                               displaySpan: displayCore,
                               selectedSourceSpans: selectedSourceSpans,
                               selectedDisplaySpans: selectedDisplay,
                               kind: isCompleteSentence(text) ? .completeSentence : .fragment)
    }

    private static func graphemes(in text: String) -> [Grapheme]? {
        let nsText = text as NSString
        var output: [Grapheme] = []
        var offset = 0
        while offset < nsText.length {
            let range = nsText.rangeOfComposedCharacterSequence(at: offset)
            guard range.location == offset,
                  range.length > 0,
                  range.length <= nsText.length - offset,
                  let span = UTF16Span(composedRange: range, in: text) else {
                return nil
            }
            output.append(Grapheme(span: span, surface: nsText.substring(with: range)))
            guard output.count <= OCRCharacterAligner.maximumGraphemes else {
                return nil
            }
            offset += range.length
        }
        return output
    }

    private static func exactBidirectionalMaps(_ alignment: OCRCharacterAlignment,
                                               sourceGraphemes: [Grapheme],
                                               displayGraphemes: [Grapheme])
        -> (sourceToDisplay: [Int?], displayToSource: [Int?])? {
        let sourceIndexBySpan = Dictionary(uniqueKeysWithValues: sourceGraphemes.enumerated().map { ($0.element.span, $0.offset) })
        let displayIndexBySpan = Dictionary(uniqueKeysWithValues: displayGraphemes.enumerated().map { ($0.element.span, $0.offset) })
        var sourceToDisplay = Array<Int?>(repeating: nil, count: sourceGraphemes.count)
        var displayToSource = Array<Int?>(repeating: nil, count: displayGraphemes.count)

        for match in alignment.matches {
            guard let sourceIndex = sourceIndexBySpan[match.sourceSpan],
                  let displayIndex = displayIndexBySpan[match.fastSpan],
                  sourceToDisplay[sourceIndex] == nil,
                  displayToSource[displayIndex] == nil,
                  rawUTF16(sourceGraphemes[sourceIndex].surface)
                    .elementsEqual(rawUTF16(displayGraphemes[displayIndex].surface)) else { return nil }
            sourceToDisplay[sourceIndex] = displayIndex
            displayToSource[displayIndex] = sourceIndex
        }

        for (index, grapheme) in sourceGraphemes.enumerated() where !isWhitespace(grapheme.surface) {
            guard sourceToDisplay[index] != nil else { return nil }
        }
        for (index, grapheme) in displayGraphemes.enumerated() where !isWhitespace(grapheme.surface) {
            guard displayToSource[index] != nil else { return nil }
        }
        return (sourceToDisplay, displayToSource)
    }

    private static func mappedDisplayRange(for sourceSpan: UTF16Span,
                                           sourceGraphemes: [Grapheme],
                                           displayGraphemes: [Grapheme],
                                           sourceToDisplay: [Int?]) -> UTF16Span? {
        guard let sourceEnd = sourceSpan.endExclusive,
              sourceSpan.length > 0,
              sourceToDisplay.count == sourceGraphemes.count else { return nil }
        var mappedDisplayIndices: [Int] = []
        for (sourceIndex, grapheme) in sourceGraphemes.enumerated() {
            guard grapheme.span.location >= sourceSpan.location,
                  let graphemeEnd = grapheme.span.endExclusive,
                  graphemeEnd <= sourceEnd else { continue }
            if !isWhitespace(grapheme.surface) {
                guard let displayIndex = sourceToDisplay[sourceIndex] else { return nil }
                mappedDisplayIndices.append(displayIndex)
            }
        }
        guard let first = mappedDisplayIndices.min(),
              let last = mappedDisplayIndices.max(),
              first >= 0, last < displayGraphemes.count,
              last >= first,
              displayGraphemes[first].span.location <= displayGraphemes[last].span.location else { return nil }

        let displayStart = displayGraphemes[first].span.location
        guard let displayEnd = displayGraphemes[last].span.endExclusive,
              displayEnd > displayStart else { return nil }
        return UTF16Span(location: displayStart, length: displayEnd - displayStart)
    }

    private static func sentenceRanges(in text: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            let range = NSRange(tokenRange, in: text)
            if range.location != NSNotFound,
               range.length > 0,
               UTF16Span(composedRange: range, in: text) != nil {
                ranges.append(range)
            }
            return true
        }
        return ranges
    }

    private static func trimmedRange(_ range: NSRange,
                                     graphemes: [Grapheme],
                                     in text: String) -> NSRange? {
        guard range.location >= 0, range.length > 0,
              range.location <= (text as NSString).length,
              range.length <= (text as NSString).length - range.location else { return nil }
        let end = range.location + range.length
        let contained = graphemes.filter {
            guard let graphemeEnd = $0.span.endExclusive else { return false }
            return $0.span.location >= range.location && graphemeEnd <= end
        }
        guard let first = contained.first(where: { !isWhitespace($0.surface) }),
              let last = contained.last(where: { !isWhitespace($0.surface) }),
              let lastEnd = last.span.endExclusive,
              lastEnd > first.span.location else { return nil }
        return NSRange(location: first.span.location, length: lastEnd - first.span.location)
    }

    private static func contains(_ container: NSRange, _ candidate: UTF16Span) -> Bool {
        guard let candidateEnd = candidate.endExclusive else { return false }
        let containerEnd = container.location + container.length
        return container.location <= candidate.location && candidateEnd <= containerEnd
    }

    private static func isCompleteSentence(_ text: String) -> Bool {
        guard let first = text.first,
              let initialScalar = first.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(initialScalar) else { return false }

        let terminalPunctuation: Set<String> = [".", "!", "?", "…", "。", "！", "？"]
        let closingMarks: Set<String> = ["\"", "'", "”", "’", "»", ")", "]", "}", "）", "】", "》", "」", "』"]
        for character in text.reversed() {
            let surface = String(character)
            if closingMarks.contains(surface) { continue }
            return terminalPunctuation.contains(surface)
        }
        return false
    }

    private static func containsLineBreak(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
    }

    private static func isWhitespace(_ grapheme: String) -> Bool {
        let scalars = grapheme.unicodeScalars
        return !scalars.isEmpty && scalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func rawUTF16(_ text: String) -> [UInt16] {
        Array(text.utf16)
    }
}
