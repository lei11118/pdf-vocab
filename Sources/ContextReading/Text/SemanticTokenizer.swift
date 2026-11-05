import Foundation
import NaturalLanguage

/// Adds stable source ranges around NLTokenizer's word boundaries without
/// normalizing, deleting, or searching the source text.
enum SemanticTokenizer {
    private static let internalJoiners: Set<String> = ["'", "’", "-", "‐", "‑"]
    private static let numberPattern = try! NSRegularExpression(
        pattern: #"^[+-]?(?:\p{Nd}+(?:[.,]\p{Nd}+)?|[.,]\p{Nd}+)(?:[eE][+-]?\p{Nd}+)?$"#
    )

    static func canonicalize(_ sourceText: String,
                             documentSHA256: String,
                             pageIndex: Int,
                             blockID: String? = nil) -> CanonicalContent {
        let ns = sourceText as NSString
        guard ns.length > 0 else {
            return CanonicalContent(documentSHA256: documentSHA256,
                                    pageIndex: pageIndex,
                                    sourceText: sourceText,
                                    tokens: [])
        }

        var ranges = wordRanges(in: sourceText)
        ranges = mergeInternalJoiners(in: ranges, source: sourceText)
        ranges = addUncoveredCharacters(to: ranges, source: sourceText)
        ranges = mergeOverlappingRanges(ranges)
        ranges.sort { $0.location < $1.location }

        let tokens = ranges.compactMap { range -> SourceToken? in
            guard let span = UTF16Span(composedRange: range, in: sourceText),
                  let surface = span.substring(in: sourceText),
                  !surface.isEmpty else { return nil }
            return SourceToken(documentSHA256: documentSHA256,
                               pageIndex: pageIndex,
                               span: span,
                               sourceSurface: surface,
                               kind: kind(of: surface),
                               blockID: blockID)
        }

        return CanonicalContent(documentSHA256: documentSHA256,
                                pageIndex: pageIndex,
                                sourceText: sourceText,
                                tokens: tokens)
    }

    private static func wordRanges(in source: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = source
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: source.startIndex..<source.endIndex) { tokenRange, _ in
            let range = NSRange(tokenRange, in: source)
            if range.location != NSNotFound, range.length > 0,
               let composedRange = expandedToComposedBoundaries(range, source: source) {
                ranges.append(composedRange)
            }
            return true
        }
        return ranges.sorted { $0.location < $1.location }
    }

    private static func expandedToComposedBoundaries(_ range: NSRange, source: String) -> NSRange? {
        let ns = source as NSString
        guard range.location >= 0, range.length > 0,
              range.location < ns.length, range.length <= ns.length - range.location else { return nil }
        let first = ns.rangeOfComposedCharacterSequence(at: range.location)
        let last = ns.rangeOfComposedCharacterSequence(at: NSMaxRange(range) - 1)
        let end = NSMaxRange(last)
        guard end > first.location, end <= ns.length else { return nil }
        return NSRange(location: first.location, length: end - first.location)
    }

    private static func mergeInternalJoiners(in ranges: [NSRange], source: String) -> [NSRange] {
        guard ranges.count > 1 else { return ranges }
        let ns = source as NSString
        var merged: [NSRange] = []

        for range in ranges {
            guard var previous = merged.last else {
                merged.append(range)
                continue
            }
            let previousEnd = NSMaxRange(previous)
            guard range.location >= previousEnd else { continue }
            let gapRange = NSRange(location: previousEnd, length: range.location - previousEnd)
            let gap = ns.substring(with: gapRange)
            let left = ns.substring(with: previous)
            let right = ns.substring(with: range)
            if internalJoiners.contains(gap), containsLetter(left), containsLetter(right) {
                previous.length = NSMaxRange(range) - previous.location
                merged[merged.count - 1] = previous
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func addUncoveredCharacters(to ranges: [NSRange], source: String) -> [NSRange] {
        let ns = source as NSString
        var covered = Array(repeating: false, count: ns.length)
        for range in ranges where range.location >= 0 && NSMaxRange(range) <= ns.length {
            for index in range.location..<NSMaxRange(range) {
                covered[index] = true
            }
        }

        var result = ranges
        var index = 0
        while index < ns.length {
            let characterRange = ns.rangeOfComposedCharacterSequence(at: index)
            let end = NSMaxRange(characterRange)
            guard end > index, end <= ns.length else { break }
            let character = ns.substring(with: characterRange)
            if !isWhitespace(character), !covered[index..<end].allSatisfy({ $0 }) {
                result.append(characterRange)
            }
            index = end
        }
        return result
    }

    private static func mergeOverlappingRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted where range.location >= 0 && range.length > 0 {
            guard var last = merged.last else {
                merged.append(range)
                continue
            }
            if range.location < NSMaxRange(last) {
                last.length = max(NSMaxRange(last), NSMaxRange(range)) - last.location
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    static func kind(of text: String) -> SourceTokenKind {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return .other }
        if scalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) { return .other }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        if numberPattern.firstMatch(in: text, range: fullRange)?.range == fullRange { return .number }
        if scalars.contains(where: { CharacterSet.letters.contains($0) }) { return .word }
        if scalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) }) { return .punctuation }
        if scalars.allSatisfy({ CharacterSet.nonBaseCharacters.contains($0) }) { return .combiningMark }
        if scalars.contains(where: { CharacterSet.symbols.contains($0) }) { return .symbol }
        return .other
    }

    private static func containsLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private static func isWhitespace(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
