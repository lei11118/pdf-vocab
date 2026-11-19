import Foundation
import NaturalLanguage

struct ReadingPhraseGroup: Equatable, Sendable {
    let sourceSpan: UTF16Span
    let sourceSurface: String
}

/// Forms a consistent partition before looking up the selected occurrence.
/// Word boundaries and POS tags are evidence; offset ranges are always taken
/// from the source so PDF highlights and the translation prompt agree.
enum ReadingPhraseGrouper {
    private struct Word {
        let text: String
        let lemma: String
        let tag: NLTag?
        let range: NSRange
    }

    private struct Chunk {
        let end: Int
        let score: Int
    }

    private static let wordPattern = try! NSRegularExpression(
        pattern: #"\p{Latin}[\p{Latin}\p{M}]*(?:['’‐‑-]\p{Latin}[\p{Latin}\p{M}]*)*"#
    )
    private static let auxiliaries: Set<String> = [
        "am", "is", "are", "was", "were", "be", "been", "being",
        "do", "does", "did", "have", "has", "had", "can", "could",
        "should", "must", "might", "may", "shall", "will", "would"
    ]
    private static let negativeModifiers: Set<String> = ["hardly", "barely", "scarcely", "never", "rarely", "seldom"]
    private static let degreeModifiers: Set<String> = ["very", "quite", "too", "highly", "strongly", "statistically",
        "significantly", "substantially", "completely", "entirely", "reliably"]
    private static let termHeads: Set<String> = [
        "coefficient", "rate", "moment", "center", "centre", "conservation", "degree", "order",
        "law", "point", "axis", "radius", "standard", "power"
    ]
    private static let fixedPhrases: Set<String> = [
        "as a result", "in spite of", "due to", "according to", "rather than",
        "as well as", "in terms of", "at least", "at most", "no more than",
        "no less than", "not necessarily", "not always", "on the other hand",
        "with respect to", "per unit", "out of phase", "in phase"
    ]
    private static let verbFrames: Set<String> = [
        "account for", "break down", "bring about", "carry out", "come across", "differ by much", "do no work", "do work", "figure out",
        "find out", "give up", "hold back", "look after", "look for", "look into", "look up",
        "make up", "point out", "put off", "put up with", "rule out", "run into", "run out of",
        "set up", "shut down", "take off", "take into account", "take place", "turn down",
        "turn into", "turn off", "work out"
    ]
    private static let separableFrames: Set<String> = [
        "bring up", "hand in", "hold back", "look up", "pick up", "put away", "put out",
        "rule out", "switch off", "take off", "turn down", "turn off"
    ]
    private static let knownHeads = termHeads.union(verbFrames.union(separableFrames).compactMap {
        $0.split(separator: " ").first.map(String.init)
    })
    private static let irregularHeads = [
        "brought": "bring", "broke": "break", "broken": "break", "came": "come", "did": "do",
        "does": "do", "done": "do", "found": "find", "gave": "give", "given": "give", "held": "hold",
        "made": "make", "ran": "run", "took": "take", "taken": "take"
    ]
    private static let upwardDirections: Set<String> = [
        "at", "toward", "towards", "to", "into", "through", "above"
    ]
    private static let upwardPaths: Set<String> = [
        "chimney", "hill", "stairs", "staircase", "street", "road", "slope", "path", "shaft", "tower"
    ]

    static func group(in context: SentenceContext, selected: UTF16Span,
                      sourceText: String?, allowsLineWrap: Bool) -> ReadingPhraseGroup? {
        let source: String
        if let sourceText {
            guard let raw = context.sourceSpan.substring(in: sourceText) else { return nil }
            source = raw
        } else {
            source = context.text
        }
        guard selected.location >= context.sourceSpan.location else { return nil }
        let local = UTF16Span(location: selected.location - context.sourceSpan.location, length: selected.length)
        guard source.utf16.count <= 1_200, let selection = local.nsRange(in: source) else { return nil }

        let text = source as NSString
        let matches = wordPattern.matches(in: source, range: NSRange(location: 0, length: text.length))
        guard let selectedIndex = matches.firstIndex(where: {
            $0.range.location <= selection.location && NSMaxRange($0.range) >= NSMaxRange(selection)
        }) else { return nil }

        // Bound processing to the current clause/sentence. Physical wraps are
        // allowed only after the PDF layout route has established reading order.
        func isJoinable(_ left: Int, _ right: Int) -> Bool {
            let start = NSMaxRange(matches[left].range)
            let length = matches[right].range.location - start
            guard length > 0 else { return false }
            let gap = text.substring(with: NSRange(location: start, length: length))
            let lineBreaks = gap.filter(\.isNewline).count
            if lineBreaks > (allowsLineWrap ? 1 : 0) { return false }
            return gap.allSatisfy(\.isWhitespace)
        }
        var first = selectedIndex
        var last = selectedIndex
        while first > 0, isJoinable(first - 1, first) { first -= 1 }
        while last + 1 < matches.count, isJoinable(last, last + 1) { last += 1 }
        guard last > first else { return nil }
        let clause = Array(matches[first...last])
        let spellings = clause.map { text.substring(with: $0.range) }
        let tags = EnglishReadingTagger.bundled?.tags(for: spellings)
        let fallback: NLTagger? = tags == nil ? NLTagger(tagSchemes: [.lexicalClass]) : nil
        fallback?.string = source
        let words = clause.enumerated().map { offset, match -> Word in
            let spelling = normalized(spellings[offset])
            let tag: NLTag?
            if let tags {
                tag = lexicalTag(for: tags[offset])
            } else if let index = Range(match.range, in: source)?.lowerBound {
                tag = fallback?.tag(at: index, unit: .word, scheme: .lexicalClass).0
            } else {
                tag = nil
            }
            return Word(text: spelling, lemma: frameHead(spelling), tag: tag, range: match.range)
        }

        let target = selectedIndex - first
        let hasPredicate = words.contains { $0.tag == .verb }
        var totals = [Int](repeating: 0, count: words.count + 1)
        var ends = Array(words.indices)
        for start in words.indices.reversed() {
            totals[start] = totals[start + 1]
            for chunk in candidates(startingAt: start, in: words, hasPredicate: hasPredicate) {
                let score = chunk.score + totals[chunk.end + 1]
                if score > totals[start] || (score == totals[start] && chunk.end > ends[start]) {
                    totals[start] = score
                    ends[start] = chunk.end
                }
            }
        }

        var start = 0
        while ends[start] < target { start = ends[start] + 1 }
        guard ends[start] > start else { return nil }
        let range = NSRange(location: words[start].range.location,
                            length: NSMaxRange(words[ends[start]].range) - words[start].range.location)
        let raw = text.substring(with: range)
        guard raw.count <= maximumCharacters else { return nil }
        return ReadingPhraseGroup(
            sourceSpan: UTF16Span(location: context.sourceSpan.location + range.location, length: range.length),
            sourceSurface: raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        )
    }

    static let maximumCharacters = 80
    static let maximumWords = 7

    private static func candidates(startingAt start: Int, in words: [Word], hasPredicate: Bool) -> [Chunk] {
        var result: [Chunk] = []
        let limit = min(words.count - 1, start + maximumWords - 1)
        guard start < limit else { return result }

        let verbEnd = verbFrameEnd(at: start, in: words) ?? separableFrameEnd(at: start, in: words)
        if let verbEnd { result.append(Chunk(end: verbEnd, score: 27 + verbEnd - start)) }
        for end in (start + 1)...min(limit, start + 4) {
            let surface = words[start...end].map(\.text).joined(separator: " ")
            if fixedPhrases.contains(surface) {
                result.append(Chunk(end: end, score: 29 + end - start))
            }
        }

        var core = start
        var carriesNegation = false
        while core < limit {
            let word = words[core]
            if word.text == "not" || negativeModifiers.contains(word.text) || word.text.hasSuffix("n't") {
                carriesNegation = true
            } else if !auxiliaries.contains(word.text) && !(core > start && degreeModifiers.contains(word.text)) {
                break
            }
            core += 1
        }
        if core > start, carriesNegation {
            let frame = verbFrameEnd(at: core, in: words) ?? separableFrameEnd(at: core, in: words)
            let end = frame ?? core
            if end <= limit && (frame != nil || words[core].tag == .verb || words[core].tag == .adjective) {
                result.append(Chunk(end: end, score: 39 + end - start))
            }
        }

        // Base noun phrases stop at the head. Keep determiners available for a
        // deliberate single-word lookup unless the determiner changes meaning.
        var noun = start
        if words[noun].text == "no" { noun += 1 }
        var hasHead = false
        while noun <= limit {
            let word = words[noun]
            if word.tag == .noun {
                // Unpunctuated OCR labels and repeated occurrences can look
                // like nominal compounds to a tagger. Keep their anchors separate.
                if hasHead && (!hasPredicate || word.text == words[noun - 1].text) { break }
                hasHead = true
                if noun > start {
                    result.append(Chunk(end: noun, score: 6 * (noun - start) + 2))
                }
            } else if !hasHead && (word.tag == .adjective ||
                (degreeModifiers.contains(word.text) && noun < limit && words[noun + 1].tag == .adjective)) {
                // Continue to the noun head.
            } else {
                break
            }
            noun += 1
        }

        // Academic terms often have a short complement introduced by “of”.
        // Only allow recognized terminology heads, with no article in the middle.
        if termHeads.contains(words[start].lemma), start + 2 <= limit, words[start + 1].text == "of" {
            for end in (start + 2)...limit {
                let next = words[end]
                if end > start + 2 && next.tag != .noun { break }
                if words[start].lemma == "power", end == start + 2, next.tag == .number {
                    result.append(Chunk(end: end, score: 29))
                    break
                }
                if end == start + 2 && next.tag != .noun && next.tag != .adjective { break }
                if next.tag == .noun {
                    result.append(Chunk(end: end, score: 23 + 3 * (end - start)))
                }
            }
        }
        return result
    }

    private static func verbFrameEnd(at start: Int, in words: [Word]) -> Int? {
        guard words[start].tag == .verb,
              start + 1 < words.count else { return nil }
        for end in stride(from: min(start + 2, words.count - 1), through: start + 1, by: -1) {
            let frame = ([words[start].lemma] + words[(start + 1)...end].map(\.text)).joined(separator: " ")
            guard verbFrames.contains(frame) else { continue }
            if frame == "look up", end + 1 < words.count {
                let next = words[end + 1]
                if upwardDirections.contains(next.text) { continue }
                let destination = next.tag == .determiner && end + 2 < words.count ? words[end + 2] : next
                if upwardPaths.contains(destination.lemma) { continue }
            }
            return end
        }
        return nil
    }

    private static func separableFrameEnd(at verb: Int, in words: [Word]) -> Int? {
        // Keep short objects inside their phrasal verb. A new determiner
        // after the particle often starts a directional complement.
        guard words[verb].tag == .verb, verb + 2 < words.count,
              words[verb+1].tag == .determiner || words[verb+1].tag == .pronoun else { return nil }
        var objectHasHead = false
        for end in (verb+2)...min(verb+5, words.count-1) {
            let previous = words[end-1]
            if previous.tag == .noun || previous.tag == .pronoun { objectHasHead = true }
            if end > verb + 2 {
                guard let tag = previous.tag, [NLTag.noun, .adjective, .pronoun, .number].contains(tag) else { break }
            }
            let particle = words[end].text
            guard objectHasHead, separableFrames.contains("\(words[verb].lemma) \(particle)") else { continue }
            if end+1 < words.count, words[end+1].tag == .determiner { continue }
            return end
        }
        return nil
    }

    private static func lexicalTag(for tag: String) -> NLTag? {
        if tag.hasPrefix("NN") { return .noun }
        if tag.hasPrefix("VB") || tag == "MD" { return .verb }
        if tag.hasPrefix("JJ") { return .adjective }
        if tag.hasPrefix("RB") { return .adverb }
        switch tag {
        case "DT", "PDT", "WDT": return .determiner
        case "PRP", "PRP$", "WP", "WP$": return .pronoun
        case "IN", "TO": return .preposition
        case "RP": return .particle
        case "CD": return .number
        default: return nil
        }
    }

    private static func frameHead(_ word: String) -> String {
        if knownHeads.contains(word) { return word }
        if let irregular = irregularHeads[word] { return irregular }
        for suffix in ["ies", "ied", "ing", "ed", "es", "s"] where word.hasSuffix(suffix) {
            let stem = String(word.dropLast(suffix.count))
            let possibilities = suffix == "ies" || suffix == "ied"
                ? [stem + "y"] : [stem, stem + "e", String(stem.dropLast())]
            if let match = possibilities.first(where: knownHeads.contains) { return match }
        }
        return word
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
    }
}

