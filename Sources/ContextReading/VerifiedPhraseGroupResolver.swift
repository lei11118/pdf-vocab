import Foundation

struct VerifiedPhraseGroup: Equatable, Sendable {
    let sourceSpan: UTF16Span
    let sourceSurface: String
    let lookupKey: String
}

/// Resolves only exact, enabled dictionary phrases around the selected word.
/// The bounded source context limits the search; punctuation and line breaks
/// always terminate a candidate, and no lemma or generated n-gram is accepted.
enum VerifiedPhraseGroupResolver {
    static let maximumWords = 4
    static let maximumCharacters = 40

    static func resolve(in context: SentenceContext,
                        selectedSourceSpans: [UTF16Span],
                        sourceText: String? = nil,
                        exactPhraseExists: (String) -> Bool) -> VerifiedPhraseGroup? {
        guard selectedSourceSpans.count == 1,
              let contextEnd = context.sourceSpan.endExclusive,
              let selection = selectedSourceSpans.first,
              let selectionEnd = selection.endExclusive,
              selection.length > 0,
              selection.location >= context.sourceSpan.location,
              selectionEnd <= contextEnd else { return nil }

        let tokenSourceText = sourceText ?? context.text
        let tokenContextSpan = sourceText == nil
            ? UTF16Span(location: 0, length: (context.text as NSString).length)
            : context.sourceSpan
        guard let tokenContextEnd = tokenContextSpan.endExclusive,
              tokenContextEnd <= (tokenSourceText as NSString).length,
              tokenContextSpan.composedCharacterRange(in: tokenSourceText) != nil else { return nil }
        let selectionInTokenSource = sourceText == nil
            ? UTF16Span(location: selection.location - context.sourceSpan.location, length: selection.length)
            : selection
        guard selectionInTokenSource.composedCharacterRange(in: tokenSourceText) != nil else { return nil }

        let canonical = SemanticTokenizer.canonicalize(tokenSourceText,
                                                       documentSHA256: context.documentSHA256,
                                                       pageIndex: context.pageIndex,
                                                       blockID: context.blockID)
        let intersectingContextTokens = canonical.tokens.filter { $0.span.intersects(tokenContextSpan) }
        guard intersectingContextTokens.allSatisfy({ contains(tokenContextSpan, $0.span) }) else { return nil }
        let tokens = intersectingContextTokens.sorted { $0.span.location < $1.span.location }
        let selectedIndices = tokens.indices.filter { tokens[$0].span.intersects(selectionInTokenSource) }
        guard let firstSelected = selectedIndices.first,
              let lastSelected = selectedIndices.last,
              selectedIndices.count == lastSelected - firstSelected + 1,
              selectedIndices.allSatisfy({ tokens[$0].kind == .word }),
              tokens[firstSelected].span.location == selectionInTokenSource.location,
              tokens[lastSelected].span.endExclusive == selectionInTokenSource.endExclusive,
              isWhitespaceSeparatedWordRun(tokens,
                                           from: firstSelected,
                                           through: lastSelected,
                                           in: tokenSourceText) else { return nil }

        let selectedWordCount = lastSelected - firstSelected + 1
        guard selectedWordCount <= maximumWords else { return nil }
        var matches: [(span: UTF16Span, surface: String, key: String, wordCount: Int)] = []

        let minimumStart = max(0, firstSelected - (maximumWords - selectedWordCount))
        for start in minimumStart...firstSelected {
            let minimumEnd = max(lastSelected, start + 1)
            let maximumEnd = min(tokens.count - 1, start + maximumWords - 1)
            guard minimumEnd <= maximumEnd else { continue }
            for end in minimumEnd...maximumEnd where start <= firstSelected && end >= lastSelected {
                let wordCount = end - start + 1
                guard wordCount >= 2,
                      isWhitespaceSeparatedWordRun(tokens, from: start, through: end, in: tokenSourceText),
                      let phraseEnd = tokens[end].span.endExclusive else { continue }
                let span = UTF16Span(location: tokens[start].span.location,
                                     length: phraseEnd - tokens[start].span.location)
                guard span.length > 0,
                      span.composedCharacterRange(in: tokenSourceText) != nil,
                      let surface = span.substring(in: tokenSourceText),
                      surface.count <= maximumCharacters else { continue }
                let key = (start...end).map { tokens[$0].sourceSurface.lowercased() }.joined(separator: " ")
                guard exactPhraseExists(key) else { continue }
                matches.append((span, surface, key, wordCount))
            }
        }

        let best = matches.max {
            $0.wordCount == $1.wordCount
                ? $0.span.length < $1.span.length
                : $0.wordCount < $1.wordCount
        }
        guard let best else { return nil }
        let verifiedSpan = sourceText == nil
            ? UTF16Span(location: context.sourceSpan.location + best.span.location, length: best.span.length)
            : best.span
        return VerifiedPhraseGroup(sourceSpan: verifiedSpan,
                                   sourceSurface: best.surface,
                                   lookupKey: best.key)
    }

    private static func isWhitespaceSeparatedWordRun(_ tokens: [SourceToken],
                                                     from start: Int,
                                                     through end: Int,
                                                     in source: String) -> Bool {
        guard start >= 0, end >= start, end < tokens.count,
              (start...end).allSatisfy({ tokens[$0].kind == .word }) else { return false }
        guard start < end else { return true }
        for index in start..<end {
            let rightStart = tokens[index + 1].span.location
            guard let leftEnd = tokens[index].span.endExclusive,
                  rightStart > leftEnd,
                  let gapText = UTF16Span(location: leftEnd, length: rightStart - leftEnd).substring(in: source),
                  !gapText.isEmpty,
                  gapText.unicodeScalars.allSatisfy({
                      CharacterSet.whitespaces.contains($0) && !CharacterSet.newlines.contains($0)
                  }) else { return false }
        }
        return true
    }

    private static func contains(_ container: UTF16Span, _ candidate: UTF16Span) -> Bool {
        guard let containerEnd = container.endExclusive,
              let candidateEnd = candidate.endExclusive else { return false }
        return container.location <= candidate.location && candidateEnd <= containerEnd
    }
}

/// Memoizes one active hover/selection seed so a pointer's per-frame hover
/// updates do not repeat dictionary queries. Dictionary revisions are part of
/// the key, and callers can clear the active seed when hover or mode ends.
final class VerifiedPhraseGroupLookup {
    private struct CacheKey: Equatable {
        let documentSHA256: String
        let pageIndex: Int
        let blockID: String
        let contextSourceSpan: UTF16Span
        let selectedSourceSpans: [UTF16Span]
        let sourceText: String
        let dictionaryRevision: Int
    }

    private let dictionaryRevision: () -> Int
    private let exactPhraseExists: (String) -> Bool
    private var cachedKey: CacheKey?
    private var hasCachedResult = false
    private var cachedResult: VerifiedPhraseGroup?

    init(dictionaryRevision: @escaping () -> Int,
         exactPhraseExists: @escaping (String) -> Bool) {
        self.dictionaryRevision = dictionaryRevision
        self.exactPhraseExists = exactPhraseExists
    }

    func resolve(in context: SentenceContext,
                 selectedSourceSpans: [UTF16Span],
                 sourceText: String? = nil) -> VerifiedPhraseGroup? {
        let source = sourceText ?? context.text
        let key = CacheKey(documentSHA256: context.documentSHA256,
                           pageIndex: context.pageIndex,
                           blockID: context.blockID,
                           contextSourceSpan: context.sourceSpan,
                           selectedSourceSpans: selectedSourceSpans,
                           sourceText: source,
                           dictionaryRevision: dictionaryRevision())
        if hasCachedResult, cachedKey == key { return cachedResult }
        cachedKey = key
        cachedResult = VerifiedPhraseGroupResolver.resolve(in: context,
                                                           selectedSourceSpans: selectedSourceSpans,
                                                           sourceText: sourceText,
                                                           exactPhraseExists: exactPhraseExists)
        hasCachedResult = true
        return cachedResult
    }

    func clear() {
        cachedKey = nil
        cachedResult = nil
        hasCachedResult = false
    }
}
