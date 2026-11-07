import Foundation
import NaturalLanguage

enum SentenceContextKind: Equatable, Sendable {
    case completeSentence
    case fragment
    case layoutBlock
}

/// Maps an exact source span in one OCR line to its position in a bounded
/// multi-line context. OCR selection spans stay line-local outside this map.
struct SentenceContextSpanMapping: Equatable, Sendable {
    let lineIndex: Int
    let sourceSpan: UTF16Span
    let contextSpan: UTF16Span
}

/// A sentence candidate tied to its exact source and display ranges. Source
/// spans retain the caller-provided UTF-16 coordinate system; display spans
/// are relative to `displayLineText`.
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
    var sourceSpanMappings: [SentenceContextSpanMapping] = []
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

    static func isCompleteSentence(_ text: String) -> Bool {
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

struct TrustedSourceBlock: Equatable, Sendable {
    let sourceSpan: UTF16Span
    let leadingEdgeTruncated: Bool
    let trailingEdgeTruncated: Bool
}

/// Builds a native PDF sentence from the page's exact source ranges. PDFKit
/// ranges stay page-relative; only CR/LF characters are changed to equal-width
/// spaces in the text sent to the sentence service.
enum NativeSentenceContextBuilder {
    static let maximumSentenceUTF16Units = 2_048

    static func build(sourceText: String,
                      selectedSourceSpans: [UTF16Span],
                      displaySurface: String,
                      documentSHA256: String,
                      pageIndex: Int,
                      allowsLineBreaks: Bool = false,
                      trustedSourceBlock: TrustedSourceBlock? = nil) -> SentenceContext? {
        let source = sourceText as NSString
        guard source.length > 0,
              !documentSHA256.isEmpty, pageIndex >= 0,
              !selectedSourceSpans.isEmpty,
              !displaySurface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let orderedSpans = selectedSourceSpans.sorted {
            $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
        }
        var previousEnd = -1
        for span in orderedSpans {
            guard span.length > 0,
                  let end = span.endExclusive,
                  end <= source.length,
                  span.composedCharacterRange(in: sourceText) != nil,
                  span.location >= previousEnd else { return nil }
            previousEnd = end
        }

        guard selectionMatchesDisplay(orderedSpans,
                                      sourceText: sourceText,
                                      displaySurface: displaySurface),
              let selectedStart = orderedSpans.first?.location,
              let selectedEnd = orderedSpans.compactMap(\.endExclusive).max(),
              selectedEnd - selectedStart <= maximumSentenceUTF16Units else { return nil }

        guard let paragraphRange = paragraphRange(around: orderedSpans, in: sourceText) else {
            return reject("selection-crosses-blank-line")
        }
        let contextRange: NSRange
        if let trustedSourceBlock {
            guard let trustedRange = trustedSourceBlock.sourceSpan.nsRange(in: sourceText),
                  trustedRange.length > 0,
                  orderedSpans.allSatisfy({ contains(trustedRange, $0) }) else { return nil }
            let intersectionStart = max(paragraphRange.location, trustedRange.location)
            let intersectionEnd = min(NSMaxRange(paragraphRange), NSMaxRange(trustedRange))
            guard intersectionStart < intersectionEnd else { return nil }
            contextRange = NSRange(location: intersectionStart, length: intersectionEnd - intersectionStart)
        } else {
            contextRange = paragraphRange
        }
        let contextEnd = NSMaxRange(contextRange)
        let windowStart = max(contextRange.location,
                              max(0, selectedStart - maximumSentenceUTF16Units))
        let (unboundedEnd, overflow) = selectedEnd.addingReportingOverflow(maximumSentenceUTF16Units)
        guard !overflow else { return nil }
        let windowEnd = min(contextEnd, unboundedEnd)
        guard let windowRange = composedRange(from: windowStart,
                                              to: windowEnd,
                                              in: sourceText),
              windowRange.length > 0 else { return nil }
        let rawWindow = source.substring(with: windowRange)
        let windowText = replacingLineBreaks(in: rawWindow)
        let windowNSString = windowText as NSString
        let localSelections = orderedSpans.map {
            UTF16Span(location: $0.location - windowRange.location, length: $0.length)
        }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = windowText
        var sentenceRanges: [NSRange] = []
        tokenizer.enumerateTokens(in: windowText.startIndex..<windowText.endIndex) { tokenRange, _ in
            let range = NSRange(tokenRange, in: windowText)
            if range.location != NSNotFound, range.length > 0 {
                sentenceRanges.append(range)
            }
            return true
        }
        let containing = sentenceRanges.filter { range in
            localSelections.allSatisfy { contains(range, $0) }
        }
        guard containing.count == 1,
              let tokenizedRange = containing.first,
              !(tokenizedRange.location == 0 && windowRange.location > contextRange.location),
              !(NSMaxRange(tokenizedRange) == windowNSString.length && NSMaxRange(windowRange) < contextEnd),
              let coreRange = trimmedRange(tokenizedRange, in: windowText),
              localSelections.allSatisfy({ contains(coreRange, $0) }) else {
            return reject("sentence-boundary-ambiguous")
        }

        let globalCoreRange = NSRange(location: windowRange.location + coreRange.location,
                                      length: coreRange.length)
        guard globalCoreRange.length <= maximumSentenceUTF16Units,
              let sourceSpan = UTF16Span(range: globalCoreRange, in: sourceText),
              let rawSentence = sourceSpan.substring(in: sourceText) else { return nil }

        let sourceContainsLineBreak = rawSentence.unicodeScalars.contains {
            CharacterSet.newlines.contains($0)
        }
        guard !sourceContainsLineBreak || allowsLineBreaks else {
            return reject("multiline-needs-geometry")
        }

        let normalizedSentence = windowNSString.substring(with: coreRange)
        let leadingTrustedEdgeWasCapped = trustedSourceBlock?.leadingEdgeTruncated == true &&
            contextRange.location > paragraphRange.location
        let trailingTrustedEdgeWasCapped = trustedSourceBlock?.trailingEdgeTruncated == true &&
            contextEnd < NSMaxRange(paragraphRange)
        let touchesTrustedBoundary =
            (leadingTrustedEdgeWasCapped && globalCoreRange.location == contextRange.location) ||
            (trailingTrustedEdgeWasCapped && NSMaxRange(globalCoreRange) == contextEnd)

        let selectedDisplaySpans = selectedSourceSpans.compactMap { span -> UTF16Span? in
            guard span.location >= globalCoreRange.location,
                  let end = span.endExclusive,
                  end <= NSMaxRange(globalCoreRange) else { return nil }
            return UTF16Span(location: span.location - globalCoreRange.location,
                             length: span.length)
        }
        guard selectedDisplaySpans.count == selectedSourceSpans.count else { return nil }

        let displaySpan = UTF16Span(location: 0, length: globalCoreRange.length)
        return SentenceContext(documentSHA256: documentSHA256,
                               pageIndex: pageIndex,
                               blockID: "native-page-\(pageIndex)",
                               text: normalizedSentence,
                               displayLineText: normalizedSentence,
                               displaySentenceText: normalizedSentence,
                               sourceSpan: sourceSpan,
                               displaySpan: displaySpan,
                               selectedSourceSpans: selectedSourceSpans,
                               selectedDisplaySpans: selectedDisplaySpans,
                               kind: !touchesTrustedBoundary && SentenceContextBuilder.isCompleteSentence(normalizedSentence)
                                ? .completeSentence : .fragment)
    }

    private static func paragraphRange(around spans: [UTF16Span], in sourceText: String) -> NSRange? {
        let source = sourceText as NSString
        guard let selectedStart = spans.map(\.location).min(),
              let selectedEnd = spans.compactMap(\.endExclusive).max(),
              selectedEnd > selectedStart else { return nil }
        var paragraphStart = 0
        var paragraphEnd = source.length
        var lineStart = 0

        while lineStart < source.length {
            var lineEnd = lineStart
            while lineEnd < source.length {
                let unit = source.character(at: lineEnd)
                if unit == 0x000A || unit == 0x000D { break }
                lineEnd += 1
            }
            var breakEnd = lineEnd
            if breakEnd < source.length {
                let unit = source.character(at: breakEnd)
                breakEnd += 1
                if unit == 0x000D, breakEnd < source.length, source.character(at: breakEnd) == 0x000A {
                    breakEnd += 1
                }
            }
            let lineText = source.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            let isBlankLine = lineText.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
            }
            if isBlankLine, breakEnd > lineEnd {
                if lineStart < selectedEnd && breakEnd > selectedStart {
                    return nil
                }
                if lineStart < selectedStart {
                    paragraphStart = breakEnd
                } else if lineStart >= selectedEnd {
                    paragraphEnd = lineStart
                    break
                }
            }
            if lineEnd == source.length { break }
            lineStart = breakEnd
        }

        guard paragraphStart <= selectedStart,
              selectedEnd <= paragraphEnd,
              paragraphEnd > paragraphStart else { return nil }
        return NSRange(location: paragraphStart, length: paragraphEnd - paragraphStart)
    }

    private static func reject(_ category: String) -> SentenceContext? {
        DiagLog.log("context.native.reject=\(category)")
        return nil
    }

    /// True only when each extracted source row is geometrically adjacent to
    /// the previous row and remains in the same horizontal column.
    static func hasTrustedAdjacentLineGeometry(_ lineBounds: [CGRect]) -> Bool {
        guard lineBounds.count >= 2,
              lineBounds.allSatisfy(isValidGeometry) else { return false }
        for pair in zip(lineBounds, lineBounds.dropFirst()) {
            let previous = pair.0
            let next = pair.1
            let minimumHeight = min(previous.height, next.height)
            let maximumHeight = max(previous.height, next.height)
            guard minimumHeight > 0,
                  maximumHeight / minimumHeight <= 1.8 else { return false }
            let downwardBaselineDelta = previous.midY - next.midY
            guard downwardBaselineDelta > minimumHeight * 0.3,
                  downwardBaselineDelta <= maximumHeight * 2.4 else { return false }

            let minimumWidth = min(previous.width, next.width)
            let horizontalOverlap = max(0, min(previous.maxX, next.maxX) - max(previous.minX, next.minX))
            let overlapRatio = horizontalOverlap / minimumWidth
            let leftEdgeDrift = abs(previous.minX - next.minX)
            guard overlapRatio >= 0.25,
                  leftEdgeDrift <= maximumHeight * 2 || overlapRatio >= 0.6 else {
                return false
            }
        }
        return true
    }

    /// Returns a page-relative source block around one selected physical row.
    /// `lineBounds` has one entry per source row; nil entries mark blank or
    /// PDFKit-unverifiable rows and stop expansion. The caller must derive each
    /// bound from that exact row's PDFKit selection on the same page.
    static func trustedSourceBlock(sourceText: String,
                                   selectedSourceSpans: [UTF16Span],
                                   lineBounds: [CGRect?],
                                   maximumNeighborRows: Int = 8) -> TrustedSourceBlock? {
        guard !selectedSourceSpans.isEmpty,
              (0...8).contains(maximumNeighborRows) else { return nil }
        let rows = physicalLineSpans(in: sourceText)
        guard rows.count == lineBounds.count else { return nil }
        let source = sourceText as NSString
        let selectedRows = selectedSourceSpans.compactMap { selected -> Int? in
            guard let selectedEnd = selected.endExclusive else { return nil }
            return rows.firstIndex { row in
                guard let rowEnd = row.endExclusive else { return false }
                return row.length > 0 && selected.location >= row.location && selectedEnd <= rowEnd
            }
        }
        guard selectedRows.count == selectedSourceSpans.count,
              let selectedRow = selectedRows.first,
              selectedRows.allSatisfy({ $0 == selectedRow }),
              let seedBounds = lineBounds[selectedRow],
              isValidGeometry(seedBounds),
              !isBlank(rows[selectedRow], in: source) else { return nil }

        func canJoin(_ earlierRow: Int, _ laterRow: Int) -> Bool {
            guard let earlierBounds = lineBounds[earlierRow],
                  let laterBounds = lineBounds[laterRow],
                  !isBlank(rows[earlierRow], in: source),
                  !isBlank(rows[laterRow], in: source) else { return false }
            return hasTrustedAdjacentLineGeometry([earlierBounds, laterBounds])
        }

        var first = selectedRow
        var last = selectedRow
        var expanded = 0
        while first > 0, expanded < maximumNeighborRows {
            let neighbor = first - 1
            guard canJoin(neighbor, first) else { break }
            first = neighbor
            expanded += 1
        }
        let leadingEdgeTruncated = expanded == maximumNeighborRows &&
            first > 0 && canJoin(first - 1, first)

        expanded = 0
        while last + 1 < rows.count, expanded < maximumNeighborRows {
            let neighbor = last + 1
            guard canJoin(last, neighbor) else { break }
            last = neighbor
            expanded += 1
        }
        let trailingEdgeTruncated = expanded == maximumNeighborRows &&
            last + 1 < rows.count && canJoin(last, last + 1)
        guard let end = rows[last].endExclusive,
              end > rows[first].location else { return nil }
        return TrustedSourceBlock(sourceSpan: UTF16Span(location: rows[first].location,
                                                        length: end - rows[first].location),
                                  leadingEdgeTruncated: leadingEdgeTruncated,
                                  trailingEdgeTruncated: trailingEdgeTruncated)
    }

    static func physicalLineSpans(in sourceText: String) -> [UTF16Span] {
        let source = sourceText as NSString
        var spans: [UTF16Span] = []
        var start = 0
        var offset = 0
        while offset < source.length {
            let unit = source.character(at: offset)
            guard unit == 0x000A || unit == 0x000D else {
                offset += 1
                continue
            }
            spans.append(UTF16Span(location: start, length: offset - start))
            let isCRLF = unit == 0x000D && offset + 1 < source.length && source.character(at: offset + 1) == 0x000A
            offset += isCRLF ? 2 : 1
            start = offset
        }
        spans.append(UTF16Span(location: start, length: source.length - start))
        return spans
    }

    private static func isBlank(_ span: UTF16Span, in source: NSString) -> Bool {
        guard let end = span.endExclusive, span.length > 0 else { return true }
        return source.substring(with: NSRange(location: span.location, length: end - span.location))
            .unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    static func lineSpans(in sourceText: String, sourceSpan: UTF16Span) -> [UTF16Span]? {
        guard let range = sourceSpan.nsRange(in: sourceText), range.length > 0 else { return nil }
        let source = sourceText as NSString
        let end = NSMaxRange(range)
        var lineStart = range.location
        var offset = lineStart
        var spans: [UTF16Span] = []
        while offset < end {
            let unit = source.character(at: offset)
            guard unit == 0x000A || unit == 0x000D else {
                offset += 1
                continue
            }
            spans.append(UTF16Span(location: lineStart, length: offset - lineStart))
            let isCRLF = unit == 0x000D && offset + 1 < end && source.character(at: offset + 1) == 0x000A
            offset += isCRLF ? 2 : 1
            lineStart = offset
        }
        spans.append(UTF16Span(location: lineStart, length: end - lineStart))
        return spans
    }

    private static func selectionMatchesDisplay(_ spans: [UTF16Span],
                                                sourceText: String,
                                                displaySurface: String) -> Bool {
        let sourceScalars = spans.compactMap { $0.substring(in: sourceText) }
            .flatMap { text in
                text.unicodeScalars
                    .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
                    .map { $0.value }
            }
        let displayScalars = displaySurface.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(\.value)
        return sourceScalars == displayScalars
    }

    private static func replacingLineBreaks(in text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            scalar.value == 0x000A || scalar.value == 0x000D ? Unicode.Scalar(0x20)! : scalar
        }))
    }

    private static func composedRange(from start: Int, to end: Int, in text: String) -> NSRange? {
        let nsText = text as NSString
        guard start >= 0, end > start, end <= nsText.length else { return nil }
        var lower = start
        var upper = end
        if lower > 0, lower < nsText.length {
            lower = nsText.rangeOfComposedCharacterSequence(at: lower).location
        }
        if upper > 0, upper < nsText.length {
            let sequence = nsText.rangeOfComposedCharacterSequence(at: upper - 1)
            upper = NSMaxRange(sequence)
        }
        return upper > lower ? NSRange(location: lower, length: upper - lower) : nil
    }

    private static func trimmedRange(_ range: NSRange, in text: String) -> NSRange? {
        let nsText = text as NSString
        guard range.location >= 0, range.length > 0,
              range.location <= nsText.length,
              range.length <= nsText.length - range.location else { return nil }
        let nonWhitespace = CharacterSet.whitespacesAndNewlines.inverted
        let first = nsText.rangeOfCharacter(from: nonWhitespace, options: [], range: range)
        let last = nsText.rangeOfCharacter(from: nonWhitespace, options: .backwards, range: range)
        guard first.location != NSNotFound, last.location != NSNotFound else { return nil }
        let end = NSMaxRange(last)
        return end > first.location ? NSRange(location: first.location, length: end - first.location) : nil
    }

    private static func contains(_ container: NSRange, _ candidate: UTF16Span) -> Bool {
        guard let candidateEnd = candidate.endExclusive else { return false }
        return container.location <= candidate.location && candidateEnd <= NSMaxRange(container)
    }

    private static func hasBlankLine(in sourceText: String, span: UTF16Span) -> Bool {
        guard let range = span.nsRange(in: sourceText) else { return true }
        let source = (sourceText as NSString).substring(with: range)
        var currentLine: [Unicode.Scalar] = []
        var hasSeenBreak = false
        var previousWasCR = false
        for scalar in source.unicodeScalars {
            if scalar.value == 0x000A || scalar.value == 0x000D {
                if scalar.value == 0x000A && previousWasCR {
                    previousWasCR = false
                    continue
                }
                if hasSeenBreak && currentLine.allSatisfy({ CharacterSet.whitespaces.contains($0) }) {
                    return true
                }
                currentLine.removeAll(keepingCapacity: true)
                hasSeenBreak = true
                previousWasCR = scalar.value == 0x000D
            } else {
                currentLine.append(scalar)
                previousWasCR = false
            }
        }
        return false
    }

    private static func isValidGeometry(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.minX.isFinite && rect.maxX.isFinite
            && rect.minY.isFinite && rect.maxY.isFinite
            && rect.width > 0 && rect.height > 0
    }
}
