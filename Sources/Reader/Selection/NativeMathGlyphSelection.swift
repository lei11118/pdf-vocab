import PDFKit
import UIKit

/// Maps content-stream math glyphs back to exact, source-checked PDFKit ranges.
/// The search is intentionally bounded around PDFKit's character index hint.
enum NativeMathGlyphSelection {
    struct Entry {
        /// Position in the input glyph array, retained for callers that keep
        /// additional parser metadata alongside each glyph.
        let glyphIndex: Int
        let glyph: PDFTextLayout.Glyph
        let sourceRange: NSRange
        let selection: PDFSelection
    }

    struct Mapping {
        let entries: [Entry]
        let mergedSelection: PDFSelection

        var ranges: [NSRange] { entries.map(\.sourceRange) }
        var selections: [PDFSelection] { entries.map(\.selection) }
    }

    private struct RangeKey: Hashable {
        let location: Int
        let length: Int

        init(_ range: NSRange) {
            location = range.location
            length = range.length
        }
    }

    private struct Candidate {
        let range: NSRange
        let selection: PDFSelection
        let bounds: CGRect
    }

    private static let anchorRadius = 80, maximumWindowLength = 320
    private static let maximumGlyphs = 64, maximumGlyphTextLength = 32
    private static let maximumCandidateSpanLength = 64, maximumCandidateClusters = 32

    /// Returns nil unless every supplied glyph maps uniquely to an exact
    /// source range and the merged PDFKit selection contains only those ranges.
    static func map(_ glyphs: [PDFTextLayout.Glyph],
                    on page: PDFPage,
                    anchoredAt characterIndex: Int,
                    allowingInterveningWhitespace: Bool = false) -> Mapping? {
        guard !glyphs.isEmpty,
              glyphs.count <= maximumGlyphs,
              let source = page.string else { return nil }

        let sourceText = source as NSString
        guard let searchRange = boundedSearchRange(near: characterIndex, in: sourceText),
              let pageBounds = validPageBounds(page) else { return nil }

        let normalizedGlyphs = glyphs.map { normalized($0.text) }
        guard normalizedGlyphs.allSatisfy({ !$0.isEmpty && $0.utf16.count <= maximumGlyphTextLength }) else {
            return nil
        }

        for glyph in glyphs {
            guard isPlausible(glyph.rect, inside: pageBounds) else { return nil }
        }

        let targets = Set(normalizedGlyphs)
        guard let rangesByText = matchingSourceRanges(
            for: targets, in: sourceText, within: searchRange) else { return nil }

        // Resolve each candidate source range once even when several glyphs
        // have the same text (for example, repeated x symbols).
        var candidates: [RangeKey: Candidate] = [:]
        for range in Set(rangesByText.values.flatMap { $0 }.map(RangeKey.init)) {
            let sourceRange = NSRange(location: range.location, length: range.length)
            guard isComposedRange(sourceRange, in: sourceText),
                  let selection = page.selection(for: sourceRange),
                  isExactSinglePageSelection(selection, range: sourceRange, on: page, source: source,
                                             allowingTrailingWhitespace: allowingInterveningWhitespace) else { continue }

            let sourceGlyph = normalized(sourceText.substring(with: sourceRange))
            guard targets.contains(sourceGlyph),
                  selectionText(selection, allowingTrailingWhitespace: allowingInterveningWhitespace) == sourceGlyph
            else { continue }

            let bounds = selection.bounds(for: page).standardized
            guard isPlausible(bounds, inside: pageBounds) else { continue }
            candidates[range] = Candidate(range: sourceRange, selection: selection, bounds: bounds)
        }

        var entries: [Entry] = []
        entries.reserveCapacity(glyphs.count)
        var usedRanges = Set<RangeKey>()

        for glyphIndex in glyphs.indices {
            let glyph = glyphs[glyphIndex]
            let target = normalizedGlyphs[glyphIndex]
            let candidateRanges = rangesByText[target] ?? []
            let matches = candidateRanges.compactMap { candidateRange -> Candidate? in
                guard let candidate = candidates[RangeKey(candidateRange)],
                      geometricallyMatches(glyph.rect, candidate.bounds) else { return nil }
                return candidate
            }
            guard matches.count == 1,
                  let match = matches.first,
                  usedRanges.insert(RangeKey(match.range)).inserted else { return nil }
            entries.append(Entry(glyphIndex: glyphIndex,
                                 glyph: glyph,
                                 sourceRange: match.range,
                                 selection: match.selection))
        }

        guard let merged = merge(entries, on: page,
                                 allowingInterveningWhitespace: allowingInterveningWhitespace)?.selection else { return nil }

        return Mapping(entries: entries, mergedSelection: merged)
    }

    /// Rebuilds a checked selection for any subset of mapped glyph entries.
    /// The returned ranges preserve the subset's input order.
    static func merge(_ entries: [Entry],
                      on page: PDFPage, allowingInterveningWhitespace: Bool = false)
        -> (selection: PDFSelection, ranges: [NSRange])? {
        guard !entries.isEmpty,
              let source = page.string,
              let pageBounds = validPageBounds(page) else { return nil }

        let ranges = entries.map(\.sourceRange)
        guard hasNoOverlappingRanges(ranges) else { return nil }
        for entry in entries {
            let range = entry.sourceRange
            guard isPlausible(entry.glyph.rect, inside: pageBounds),
                  isComposedRange(range, in: source as NSString),
                  normalized((source as NSString).substring(with: range)) == normalized(entry.glyph.text),
                  isExactSinglePageSelection(entry.selection, range: range, on: page, source: source,
                                             allowingTrailingWhitespace: allowingInterveningWhitespace),
                  selectionText(entry.selection, allowingTrailingWhitespace: allowingInterveningWhitespace)
                    == normalized(entry.glyph.text),
                  isPlausible(entry.selection.bounds(for: page), inside: pageBounds) else { return nil }
        }

        guard let selection = checkedMergedSelection(for: entries.map(\.selection),
                                                     expectedRanges: ranges,
                                                     on: page,
                                                     source: source,
                                                     allowingInterveningWhitespace: allowingInterveningWhitespace) else { return nil }
        return (selection, ranges)
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    private static func selectionText(_ selection: PDFSelection, allowingTrailingWhitespace: Bool) -> String {
        let text = selection.string ?? ""
        return normalized(allowingTrailingWhitespace ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text)
    }

    private static func boundedSearchRange(near index: Int, in source: NSString) -> NSRange? {
        guard source.length > 0, index >= 0, index < source.length else { return nil }

        let startHint = max(0, index - anchorRadius)
        let endHint = min(source.length, index + anchorRadius + 1)
        var start = startHint
        var end = endHint

        if start > 0 {
            start = source.rangeOfComposedCharacterSequence(at: start).location
        }
        if end < source.length, end > 0 {
            end = NSMaxRange(source.rangeOfComposedCharacterSequence(at: end - 1))
        }

        guard end > start, end - start <= maximumWindowLength else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private static func matchingSourceRanges(for targets: Set<String>,
                                             in source: NSString,
                                             within window: NSRange) -> [String: [NSRange]]? {
        guard !targets.isEmpty,
              window.location >= 0,
              window.length > 0,
              window.location <= source.length,
              window.length <= source.length - window.location else { return nil }

        let maxTargetLength = targets.map { $0.utf16.count }.max() ?? 0
        guard maxTargetLength > 0, maxTargetLength <= maximumGlyphTextLength else { return nil }
        let maxSpanLength = min(maximumCandidateSpanLength, maxTargetLength + 8)
        var result: [String: [NSRange]] = [:]
        var seen: [String: Set<RangeKey>] = [:]

        var start = window.location
        let windowEnd = NSMaxRange(window)
        while start < windowEnd {
            let firstCluster = source.rangeOfComposedCharacterSequence(at: start)
            guard firstCluster.location == start,
                  NSMaxRange(firstCluster) <= windowEnd else { return nil }

            var end = start
            var clusterCount = 0
            var candidate = ""
            while end < windowEnd, clusterCount < maximumCandidateClusters {
                let cluster = source.rangeOfComposedCharacterSequence(at: end)
                guard cluster.location == end,
                      NSMaxRange(cluster) <= windowEnd else { return nil }
                let nextEnd = NSMaxRange(cluster)
                guard nextEnd - start <= maxSpanLength else { break }

                candidate += source.substring(with: cluster)
                end = nextEnd
                clusterCount += 1

                let key = normalized(candidate)
                if targets.contains(key) {
                    let range = NSRange(location: start, length: end - start)
                    let rangeKey = RangeKey(range)
                    if seen[key, default: []].insert(rangeKey).inserted {
                        result[key, default: []].append(range)
                    }
                }
            }
            start = NSMaxRange(firstCluster)
        }

        return result
    }

    private static func isComposedRange(_ range: NSRange, in source: NSString) -> Bool {
        guard range.location >= 0,
              range.length > 0,
              range.location <= source.length,
              range.length <= source.length - range.location else { return false }
        let end = NSMaxRange(range)
        return (range.location == 0
                || source.rangeOfComposedCharacterSequence(at: range.location).location == range.location)
            && (end == source.length
                || source.rangeOfComposedCharacterSequence(at: end).location == end)
    }

    private static func isExactSinglePageSelection(_ selection: PDFSelection,
                                                   range: NSRange,
                                                   on page: PDFPage,
                                                   source: String,
                                                   allowingTrailingWhitespace: Bool = false) -> Bool {
        guard selection.pages.count == 1,
              selection.pages.first === page,
              selection.numberOfTextRanges(on: page) == 1 else { return false }
        let actual = selection.range(at: 0, on: page)
        let text = source as NSString
        guard actual.location == range.location, isComposedRange(actual, in: text) else { return false }
        if actual.length == range.length { return true }
        let trailingLength = actual.length - range.length
        guard allowingTrailingWhitespace, (1...2).contains(trailingLength) else { return false }
        let trailing = NSRange(location: NSMaxRange(range), length: trailingLength)
        return text.substring(with: trailing).allSatisfy(\.isWhitespace)
    }

    private static func validPageBounds(_ page: PDFPage) -> CGRect? {
        let bounds = page.bounds(for: .mediaBox).standardized
        guard bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0 else { return nil }
        return bounds
    }

    private static func isPlausible(_ rect: CGRect, inside pageBounds: CGRect) -> Bool {
        let rect = rect.standardized
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0,
              rect.width <= pageBounds.width,
              rect.height <= pageBounds.height else { return false }

        let tolerance: CGFloat = 0.5
        return rect.minX >= pageBounds.minX - tolerance
            && rect.minY >= pageBounds.minY - tolerance
            && rect.maxX <= pageBounds.maxX + tolerance
            && rect.maxY <= pageBounds.maxY + tolerance
    }

    private static func geometricallyMatches(_ glyphRect: CGRect, _ selectionRect: CGRect) -> Bool {
        let glyphRect = glyphRect.standardized
        let selectionRect = selectionRect.standardized
        let overlap = glyphRect.intersection(selectionRect)
        guard !overlap.isNull,
              overlap.width > 0,
              overlap.height > 0 else { return false }

        let overlapArea = overlap.width * overlap.height
        let glyphArea = glyphRect.width * glyphRect.height
        let selectionArea = selectionRect.width * selectionRect.height
        guard glyphArea.isFinite,
              selectionArea.isFinite,
              overlapArea / glyphArea >= 0.15,
              overlapArea / selectionArea >= 0.15 else { return false }

        let xDistance = abs(glyphRect.midX - selectionRect.midX)
        let yDistance = abs(glyphRect.midY - selectionRect.midY)
        let xLimit = max(4, min(glyphRect.width, selectionRect.width) * 0.75)
        let yLimit = max(4, min(glyphRect.height, selectionRect.height) * 0.55)
        return xDistance <= xLimit && yDistance <= yLimit
    }

    private static func hasNoOverlappingRanges(_ ranges: [NSRange]) -> Bool {
        let ordered = ranges.sorted { $0.location < $1.location }
        return zip(ordered, ordered.dropFirst()).allSatisfy { pair in
            pair.1.location >= NSMaxRange(pair.0)
        }
    }

    private static func checkedMergedSelection(for selections: [PDFSelection],
                                               expectedRanges: [NSRange],
                                               on page: PDFPage,
                                               source: String,
                                               allowingInterveningWhitespace: Bool) -> PDFSelection? {
        guard let firstRange = expectedRanges.first,
              let merged = page.selection(for: firstRange) else { return nil }
        if selections.count > 1 {
            merged.add(Array(selections.dropFirst()))
        }

        guard merged.pages.count == 1,
              merged.pages.first === page else { return nil }
        let count = merged.numberOfTextRanges(on: page)
        guard count > 0 else { return nil }

        var actualRanges: [NSRange] = []
        for index in 0..<count {
            let range = merged.range(at: index, on: page)
            guard isComposedRange(range, in: source as NSString) else { return nil }
            actualRanges.append(range)
        }

        if coalesced(actualRanges) == coalesced(expectedRanges) { return merged }
        guard allowingInterveningWhitespace else { return nil }
        let text = source as NSString
        func visibleStarts(in ranges: [NSRange]) -> [Int] {
            coalesced(ranges).flatMap { range in
                var starts: [Int] = []
                var index = range.location
                while index < NSMaxRange(range) {
                    let grapheme = text.rangeOfComposedCharacterSequence(at: index)
                    if !text.substring(with: grapheme).allSatisfy(\.isWhitespace) {
                        starts.append(grapheme.location)
                    }
                    index = NSMaxRange(grapheme)
                }
                return starts
            }
        }
        return visibleStarts(in: actualRanges) == visibleStarts(in: expectedRanges) ? merged : nil
    }

    private static func coalesced(_ ranges: [NSRange]) -> [NSRange] {
        let ordered = ranges.sorted {
            $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
        }
        var result: [NSRange] = []
        for range in ordered {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSRange(location: last.location,
                                                   length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
