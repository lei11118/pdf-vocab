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
                      generation: Int) -> ContextualSelection? {
        guard selection.pages.count == 1,
              selection.pages.first === page,
              let sourceText = page.string else { return nil }
        let ranges = SelectionGeometry.sourceRanges(of: selection, on: page)
        guard !ranges.isEmpty else { return nil }
        let sourceSpans = ranges.compactMap { UTF16Span(range: $0, in: sourceText) }
        guard sourceSpans.count == ranges.count else { return nil }

        let canonical = canonicalContent(sourceText: sourceText,
                                        documentSHA256: documentSHA256,
                                        pageIndex: pageIndex,
                                        geometryRevision: SelectionGeometry.contextGeometryRevision(for: page))
        guard var contextual = resolve(canonical: canonical,
                                       sourceSpans: sourceSpans,
                                       displaySurface: displaySurface,
                                       geometryQuality: geometryQuality,
                                       generation: generation,
                                       allowsMultilineSentenceContext: true) else { return nil }
        guard let candidate = contextual.sentenceContext,
              let rawCandidate = candidate.sourceSpan.substring(in: sourceText),
              containsLineBreak(rawCandidate) else { return contextual }
        guard let lineSpans = NativeSentenceContextBuilder.lineSpans(in: sourceText,
                                                                      sourceSpan: candidate.sourceSpan) else {
            contextual.sentenceContext = nil
            return contextual
        }
        let lineBoxes = lineSpans.compactMap { lineBounds(for: $0, sourceText: sourceText, page: page) }
        guard isTrustedMultilineLayout(sourceText: sourceText,
                                       candidate: candidate,
                                       lineBounds: lineBoxes) else {
            contextual.sentenceContext = nil
            return contextual
        }
        return contextual
    }

    static func resolve(canonical: CanonicalContent,
                        sourceSpans: [UTF16Span],
                        displaySurface: String,
                        geometryQuality: SourceGeometryQuality,
                        generation: Int,
                        allowsMultilineSentenceContext: Bool = false) -> ContextualSelection? {
        guard !sourceSpans.isEmpty,
              !displaySurface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let overlaps = canonical.tokens.filter { token in
            sourceSpans.contains { token.span.intersects($0) }
        }
        let contained = overlaps.filter { token in
            sourceSpans.contains { contains($0, token.span) }
        }

        let selectedTokens: [SourceToken]
        if geometryQuality == .approximate {
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
                                     allowsMultilineSentenceContext: allowsMultilineSentenceContext)
            }
            selectedTokens = [token.withGeometryQuality(geometryQuality)]
        }

        let sentenceContext = NativeSentenceContextBuilder.build(
            sourceText: canonical.sourceText,
            selectedSourceSpans: sourceSpans,
            displaySurface: displaySurface,
            documentSHA256: canonical.documentSHA256,
            pageIndex: canonical.pageIndex,
            allowsLineBreaks: allowsMultilineSentenceContext
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
                                      allowsMultilineSentenceContext: Bool) -> ContextualSelection? {
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
            allowsLineBreaks: allowsMultilineSentenceContext
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
}
