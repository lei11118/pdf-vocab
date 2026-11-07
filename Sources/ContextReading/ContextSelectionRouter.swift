import CryptoKit
import Foundation
import PDFKit

/// Joins a trusted PDFKit selection seed to source tokens. It never grows a
/// seed to a neighbouring token when the tokenizer and visual selection differ.
enum ContextSelectionRouter {
    private struct CacheKey: Hashable {
        let documentSHA256: String
        let pageIndex: Int
        let sourceDigest: String
        let geometryRevision: String
    }

    private static let cacheLock = NSLock()
    private static var contentCache: [CacheKey: CanonicalContent] = [:]
    private static var cacheOrder: [CacheKey] = []
    private static let cacheLimit = 8

    static func route(selection: PDFSelection,
                      page: PDFPage,
                      documentSHA256: String,
                      pageIndex: Int,
                      displaySurface: String,
                      geometryQuality: SourceGeometryQuality,
                      generation: Int,
                      verifiedPhraseGroupSpan: UTF16Span? = nil) -> ContextualSelection? {
        guard selection.pages.count == 1,
              selection.pages.first === page,
              let sourceText = page.string else { return nil }
        let ranges = SelectionGeometry.sourceRanges(of: selection, on: page)
        guard !ranges.isEmpty else { return nil }
        let sourceSpans = ranges.compactMap { UTF16Span(range: $0, in: sourceText) }
        guard sourceSpans.count == ranges.count else { return nil }

        let sourceRows = NativeSentenceContextBuilder.physicalLineSpans(in: sourceText)
        let selectedRowIndices = sourceSpans.compactMap { selected -> Int? in
            guard let selectedEnd = selected.endExclusive else { return nil }
            return sourceRows.firstIndex { row in
                guard let rowEnd = row.endExclusive else { return false }
                return row.length > 0 && selected.location >= row.location && selectedEnd <= rowEnd
            }
        }
        let seedRowIndex: Int?
        if selectedRowIndices.count == sourceSpans.count,
           let first = selectedRowIndices.first,
           selectedRowIndices.allSatisfy({ $0 == first }) {
            seedRowIndex = first
        } else {
            seedRowIndex = nil
        }
        var lineBoundsCache: [Int: CGRect] = [:]
        var checkedLineBounds = Set<Int>()
        func boundsForRow(_ rowIndex: Int) -> CGRect? {
            if checkedLineBounds.contains(rowIndex) { return lineBoundsCache[rowIndex] }
            guard sourceRows.indices.contains(rowIndex) else { return nil }
            checkedLineBounds.insert(rowIndex)
            let bounds = lineBounds(for: sourceRows[rowIndex], sourceText: sourceText, page: page)
            if let bounds { lineBoundsCache[rowIndex] = bounds }
            return bounds
        }

        func trustedSourceBlock() -> TrustedSourceBlock? {
            guard let seedRowIndex, !sourceRows.isEmpty else { return nil }
            var nearbyBounds = [CGRect?](repeating: nil, count: sourceRows.count)
            let lower = max(0, seedRowIndex - 9)
            let upper = min(sourceRows.count - 1, seedRowIndex + 9)
            for rowIndex in lower...upper {
                nearbyBounds[rowIndex] = boundsForRow(rowIndex)
            }
            return NativeSentenceContextBuilder.trustedSourceBlock(sourceText: sourceText,
                                                                    selectedSourceSpans: sourceSpans,
                                                                    lineBounds: nearbyBounds)
        }

        func candidateHasTrustedLineGeometry(_ candidate: SentenceContext) -> Bool {
            guard let seedRowIndex,
                  let candidateEnd = candidate.sourceSpan.endExclusive else { return false }
            let candidateRows = sourceRows.indices.filter { rowIndex in
                guard let rowEnd = sourceRows[rowIndex].endExclusive else { return false }
                return sourceRows[rowIndex].length > 0 &&
                    sourceRows[rowIndex].location < candidateEnd && rowEnd > candidate.sourceSpan.location
            }
            guard candidateRows.count >= 2,
                  candidateRows.allSatisfy({ abs($0 - seedRowIndex) <= 9 }) else { return false }
            let lineBoxes = candidateRows.compactMap(boundsForRow)
            guard lineBoxes.count == candidateRows.count else { return false }
            return isTrustedMultilineLayout(sourceText: sourceText,
                                            candidate: candidate,
                                            lineBounds: lineBoxes)
        }

        let canonical = canonicalContent(sourceText: sourceText,
                                        documentSHA256: documentSHA256,
                                        pageIndex: pageIndex,
                                        geometryRevision: SelectionGeometry.contextGeometryRevision(for: page))
        guard var contextual = resolve(canonical: canonical,
                                       sourceSpans: sourceSpans,
                                       displaySurface: displaySurface,
                                       geometryQuality: geometryQuality,
                                       generation: generation,
                                       allowsMultilineSentenceContext: true,
                                       verifiedPhraseGroupSpan: verifiedPhraseGroupSpan) else { return nil }
        var shouldUseTrustedFallback = contextual.sentenceContext == nil
        if let candidate = contextual.sentenceContext {
            if let rawCandidate = candidate.sourceSpan.substring(in: sourceText) {
                if containsLineBreak(rawCandidate) {
                    shouldUseTrustedFallback = !candidateHasTrustedLineGeometry(candidate)
                }
            } else {
                shouldUseTrustedFallback = true
            }
        }
        if shouldUseTrustedFallback {
            contextual.sentenceContext = nil
            if let block = trustedSourceBlock(),
               let fallback = resolve(canonical: canonical,
                                      sourceSpans: sourceSpans,
                                      displaySurface: displaySurface,
                                      geometryQuality: geometryQuality,
                                      generation: generation,
                                      allowsMultilineSentenceContext: true,
                                      verifiedPhraseGroupSpan: verifiedPhraseGroupSpan,
                                      trustedSourceBlock: block) {
                contextual = fallback
            }
        }
        if let verifiedPhraseGroupSpan {
            guard let sentenceContext = contextual.sentenceContext,
                  contextual.sourceSpans == [verifiedPhraseGroupSpan],
                  sentenceContext.selectedSourceSpans == [verifiedPhraseGroupSpan],
                  contextual.tokens.count >= 2,
                  contextual.tokens.allSatisfy({ $0.kind == .word }),
                  isWhitespaceSeparatedWordGroup(contextual.tokens,
                                                  span: verifiedPhraseGroupSpan,
                                                  in: sourceText) else { return nil }
            contextual.verifiedPhraseGroupSpan = verifiedPhraseGroupSpan
        }
        return contextual
    }

    static func resolve(canonical: CanonicalContent,
                        sourceSpans: [UTF16Span],
                        displaySurface: String,
                        geometryQuality: SourceGeometryQuality,
                        generation: Int,
                        allowsMultilineSentenceContext: Bool = false,
                        verifiedPhraseGroupSpan: UTF16Span? = nil,
                        trustedSourceBlock: TrustedSourceBlock? = nil) -> ContextualSelection? {
        guard !sourceSpans.isEmpty,
              !displaySurface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let overlaps = canonical.tokens.filter { token in
            sourceSpans.contains { token.span.intersects($0) }
        }
        let contained = overlaps.filter { token in
            sourceSpans.contains { contains($0, token.span) }
        }

        let selectedTokens: [SourceToken]
        if let verifiedPhraseGroupSpan {
            guard sourceSpans == [verifiedPhraseGroupSpan],
                  contained.count == overlaps.count,
                  contained.count >= 2,
                  contained.allSatisfy({ $0.kind == .word }),
                  isWhitespaceSeparatedWordGroup(contained,
                                                 span: verifiedPhraseGroupSpan,
                                                 in: canonical.sourceText) else { return nil }
            selectedTokens = contained.map { $0.withGeometryQuality(geometryQuality) }
        } else if geometryQuality == .approximate {
            // A drag may include several whole tokens. A partial token overlap
            // is ambiguous, so let the existing selection path own that case.
            guard !contained.isEmpty, contained.count == overlaps.count else { return nil }
            selectedTokens = contained.map { $0.withGeometryQuality(.approximate) }
        } else {
            // A double-tap/press supplies one visually verified seed. If the
            // reading tokenizer splits or extends it, retain exactly the seed.
            guard sourceSpans.count == 1, let seed = sourceSpans.first,
                  let rawSeed = seed.substring(in: canonical.sourceText),
                  let token = (contained.count == 1 && contained.count == overlaps.count)
                    ? contained.first : nil,
                  nonWhitespaceContent(of: rawSeed) == nonWhitespaceContent(of: token.sourceSurface) else {
                return fallbackToken(canonical: canonical,
                                     sourceSpans: sourceSpans,
                                     displaySurface: displaySurface,
                                     geometryQuality: geometryQuality,
                                     generation: generation,
                                     allowsMultilineSentenceContext: allowsMultilineSentenceContext,
                                     trustedSourceBlock: trustedSourceBlock)
            }
            selectedTokens = [token.withGeometryQuality(geometryQuality)]
        }

        let sentenceContext = NativeSentenceContextBuilder.build(
            sourceText: canonical.sourceText,
            selectedSourceSpans: sourceSpans,
            displaySurface: displaySurface,
            documentSHA256: canonical.documentSHA256,
            pageIndex: canonical.pageIndex,
            allowsLineBreaks: allowsMultilineSentenceContext,
            trustedSourceBlock: trustedSourceBlock
        )
        return ContextualSelection(documentSHA256: canonical.documentSHA256,
                                   pageIndex: canonical.pageIndex,
                                   sourceSpans: sourceSpans,
                                   tokens: selectedTokens,
                                   displaySurface: displaySurface,
                                   generation: generation,
                                   sentenceContext: sentenceContext)
    }

    static func clearCache() {
        cacheLock.lock()
        contentCache.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
        cacheLock.unlock()
    }

    static func isTrustedMultilineLayout(sourceText: String,
                                         candidate: SentenceContext,
                                         lineBounds: [CGRect]) -> Bool {
        guard let rawCandidate = candidate.sourceSpan.substring(in: sourceText),
              containsLineBreak(rawCandidate),
              let lineSpans = NativeSentenceContextBuilder.lineSpans(in: sourceText,
                                                                    sourceSpan: candidate.sourceSpan),
              lineSpans.count == lineBounds.count else { return false }
        return NativeSentenceContextBuilder.hasTrustedAdjacentLineGeometry(lineBounds)
    }

    private static func canonicalContent(sourceText: String,
                                         documentSHA256: String,
                                         pageIndex: Int,
                                         geometryRevision: String) -> CanonicalContent {
        let sourceDigest = SHA256.hash(data: Data(sourceText.utf8)).map { String(format: "%02x", $0) }.joined()
        let key = CacheKey(documentSHA256: documentSHA256,
                           pageIndex: pageIndex,
                           sourceDigest: sourceDigest,
                           geometryRevision: geometryRevision)

        cacheLock.lock()
        if let cached = contentCache[key] {
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let content = SemanticTokenizer.canonicalize(sourceText,
                                                     documentSHA256: documentSHA256,
                                                     pageIndex: pageIndex)
        cacheLock.lock()
        contentCache[key] = content
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > cacheLimit {
            let expired = cacheOrder.removeFirst()
            contentCache.removeValue(forKey: expired)
        }
        cacheLock.unlock()
        return content
    }

    private static func fallbackToken(canonical: CanonicalContent,
                                      sourceSpans: [UTF16Span],
                                      displaySurface: String,
                                      geometryQuality: SourceGeometryQuality,
                                      generation: Int,
                                      allowsMultilineSentenceContext: Bool,
                                      trustedSourceBlock: TrustedSourceBlock?) -> ContextualSelection? {
        guard sourceSpans.count == 1,
              let span = sourceSpans.first,
              let composedRange = span.composedCharacterRange(in: canonical.sourceText),
              let composedSpan = UTF16Span(composedRange: composedRange, in: canonical.sourceText),
              let rawSurface = composedSpan.substring(in: canonical.sourceText) else { return nil }

        let seed = SourceToken(documentSHA256: canonical.documentSHA256,
                               pageIndex: canonical.pageIndex,
                               span: composedSpan,
                               sourceSurface: rawSurface,
                               kind: SemanticTokenizer.kind(of: displaySurface),
                               geometryQuality: geometryQuality)
        let sentenceContext = NativeSentenceContextBuilder.build(
            sourceText: canonical.sourceText,
            selectedSourceSpans: sourceSpans,
            displaySurface: displaySurface,
            documentSHA256: canonical.documentSHA256,
            pageIndex: canonical.pageIndex,
            allowsLineBreaks: allowsMultilineSentenceContext,
            trustedSourceBlock: trustedSourceBlock
        )
        return ContextualSelection(documentSHA256: canonical.documentSHA256,
                                   pageIndex: canonical.pageIndex,
                                   sourceSpans: sourceSpans,
                                   tokens: [seed],
                                   displaySurface: displaySurface,
                                   generation: generation,
                                   sentenceContext: sentenceContext)
    }

    private static func contains(_ container: UTF16Span, _ candidate: UTF16Span) -> Bool {
        guard let containerEnd = container.endExclusive,
              let candidateEnd = candidate.endExclusive else { return false }
        return container.location <= candidate.location && candidateEnd <= containerEnd
    }

    private static func nonWhitespaceContent(of source: String) -> String {
        String(source.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    private static func lineBounds(for lineSpan: UTF16Span,
                                   sourceText: String,
                                   page: PDFPage) -> CGRect? {
        guard let range = lineSpan.nsRange(in: sourceText), range.length > 0 else { return nil }
        guard let selection = page.selection(for: range) else { return nil }
        guard selection.pages.count == 1,
              selection.pages.first === page,
              SelectionGeometry.sourceRanges(of: selection, on: page) == [range] else { return nil }
        let lineSelections = selection.selectionsByLine()
        // A source row that wraps into several visual rows is ambiguous here;
        // retain the word selection and omit sentence context.
        guard lineSelections.count == 1 else { return nil }
        let bounds = lineSelections[0].bounds(for: page)
        return SelectionGeometry.isValid(bounds) ? bounds : nil
    }

    private static func containsLineBreak(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
    }

    private static func isWhitespaceSeparatedWordGroup(_ tokens: [SourceToken],
                                                       span: UTF16Span,
                                                       in sourceText: String) -> Bool {
        let ordered = tokens.sorted { $0.span.location < $1.span.location }
        guard ordered.count >= 2,
              ordered.allSatisfy({ $0.kind == .word }),
              ordered.first?.span.location == span.location,
              ordered.last?.span.endExclusive == span.endExclusive else { return false }
        for pair in zip(ordered, ordered.dropFirst()) {
            guard let leftEnd = pair.0.span.endExclusive,
                  pair.1.span.location > leftEnd,
                  let gapText = UTF16Span(location: leftEnd,
                                          length: pair.1.span.location - leftEnd).substring(in: sourceText),
                  !gapText.isEmpty,
                  gapText.unicodeScalars.allSatisfy({
                      CharacterSet.whitespaces.contains($0) && !CharacterSet.newlines.contains($0)
                  }) else { return false }
        }
        return true
    }
}
