import Foundation

struct ContextOCRSelectionEntry: Sendable {
    let word: OCRWord
    let lineIndex: Int
    let blockID: String
    let sourceSpan: UTF16Span
    let tokens: [SourceToken]
}

/// Immutable bridge from a complete OCR page to the legacy hit-test surface.
/// It keeps each hit box tied to exact line-local source ranges and tokens.
struct ContextOCRSelectionSource: Sendable {
    let page: ContextOCRPage
    let entries: [ContextOCRSelectionEntry]
    let words: [OCRWord]

    init?(page: ContextOCRPage) {
        guard !page.documentSHA256.isEmpty, page.pageIndex >= 0, page.revision >= 0,
              page.mediaBox.width > 0, page.mediaBox.height > 0 else { return nil }
        self.page = page

        var built: [ContextOCRSelectionEntry] = []
        for (lineIndex, line) in page.lines.enumerated() {
            let validTokens = line.tokens.filter { token in
                Self.isValidSourceToken(token, in: line, page: page)
            }.sorted {
                $0.span.location == $1.span.location
                    ? $0.span.length < $1.span.length
                    : $0.span.location < $1.span.location
            }
            let geometryByToken = Dictionary(grouping: line.tokenGeometry, by: \.tokenID)
            var seeds: [TokenSeed] = []
            for token in validTokens {
                guard token.geometryQuality == .word || token.geometryQuality == .verifiedCharacter,
                      let matches = geometryByToken[token.id], matches.count == 1,
                      let geometry = matches.first,
                      geometry.span == token.span,
                      geometry.quality == token.geometryQuality,
                      let rect = geometry.rect,
                      Self.isInsideMediaBox(rect, mediaBox: page.mediaBox) else { continue }
                seeds.append(TokenSeed(token: token, rect: rect))
            }

            for seedRange in Self.coalescedSeedRanges(seeds) {
                let group = seedRange.map { seeds[$0] }
                guard let first = group.first,
                      let start = group.map({ $0.token.span.location }).min(),
                      let end = group.compactMap({ $0.token.span.endExclusive }).max(),
                      end > start else { continue }
                let span = UTF16Span(location: start, length: end - start)
                guard span.composedCharacterRange(in: line.sourceText) != nil,
                      let surface = span.substring(in: line.sourceText), !surface.isEmpty else { continue }
                let groupTokens = validTokens.filter { token in
                    guard let tokenEnd = token.span.endExclusive else { return false }
                    return token.span.location >= start && tokenEnd <= end
                }
                guard !groupTokens.isEmpty else { continue }
                // Shared or indistinguishable source geometry stays a single
                // hit target; this adapter never invents smaller rectangles.
                // Include every valid source token inside the closure span,
                // even when an intermediate token has no reliable box.
                let unionBox = group.dropFirst().reduce(first.rect.cgRect) { current, seed in
                    current.union(seed.rect.cgRect)
                }
                guard let box = SourceRect(rect: unionBox) else { continue }
                let normalized = Self.normalizedWord(box, in: page.mediaBox)
                guard normalized.x.isFinite, normalized.y.isFinite,
                      normalized.w.isFinite, normalized.h.isFinite,
                      normalized.x >= 0, normalized.y >= 0,
                      normalized.w > 0, normalized.h > 0,
                      normalized.x + normalized.w <= 1.000_001,
                      normalized.y + normalized.h <= 1.000_001 else { continue }
                let word = OCRWord(text: surface,
                                   x: normalized.x,
                                   y: normalized.y,
                                   w: normalized.w,
                                   h: normalized.h,
                                   line: lineIndex)
                built.append(ContextOCRSelectionEntry(word: word,
                                                      lineIndex: lineIndex,
                                                      blockID: line.blockID,
                                                      sourceSpan: span,
                                                      tokens: groupTokens))
            }
        }
        let sortedEntries = built.sorted {
            $0.lineIndex == $1.lineIndex
                ? $0.sourceSpan.location < $1.sourceSpan.location
                : $0.lineIndex < $1.lineIndex
        }
        self.entries = sortedEntries
        self.words = sortedEntries.map(\.word)
    }

    func contextualSelection(for range: ClosedRange<Int>, generation: Int) -> ContextualSelection? {
        guard range.lowerBound >= 0, range.upperBound < entries.count else { return nil }
        let selectedEntries = Array(entries[range])
        guard let first = selectedEntries.first, let last = selectedEntries.last else { return nil }
        var sourceSpans: [UTF16Span] = []
        var selectedTokens: [SourceToken] = []
        var displayLines: [String] = []

        for lineIndex in first.lineIndex...last.lineIndex {
            guard lineIndex >= 0, lineIndex < page.lines.count else { return nil }
            let line = page.lines[lineIndex]
            let lineEntries = selectedEntries.filter { $0.lineIndex == lineIndex }
            let spans: [UTF16Span]
            if !lineEntries.isEmpty {
                spans = lineEntries.map(\.sourceSpan)
            } else {
                // A geometry-free OCR line between two selected rows still
                // contributes its original text and Token ranges.
                spans = line.tokens.filter { Self.isValidSourceToken($0, in: line, page: page) }.map(\.span).filter {
                    $0.length > 0
                }
            }
            guard let start = spans.map(\.location).min(),
                  let end = spans.compactMap(\.endExclusive).max(), end > start else { continue }
            let span = UTF16Span(location: start, length: end - start)
            guard span.composedCharacterRange(in: line.sourceText) != nil,
                  let surface = span.substring(in: line.sourceText) else { return nil }
            sourceSpans.append(span)
            displayLines.append(surface)
            selectedTokens.append(contentsOf: line.tokens.filter { token in
                guard let tokenEnd = token.span.endExclusive else { return false }
                return Self.isValidSourceToken(token, in: line, page: page)
                    && token.span.length > 0
                    && token.span.location >= start
                    && tokenEnd <= end
            }.sorted { $0.span.location < $1.span.location })
        }

        guard !sourceSpans.isEmpty, !selectedTokens.isEmpty else { return nil }
        return ContextualSelection(documentSHA256: page.documentSHA256,
                                   pageIndex: page.pageIndex,
                                   sourceSpans: sourceSpans,
                                   tokens: selectedTokens,
                                   displaySurface: displayLines.joined(separator: "\n"),
                                   generation: generation)
    }

    func fullLineContext(for range: ClosedRange<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound < entries.count else { return nil }
        let selected = entries[range]
        guard let first = selected.first, let last = selected.last else { return nil }
        return page.lines[first.lineIndex...last.lineIndex]
            .map(\.sourceText)
            .joined(separator: "\n")
    }

    private struct TokenSeed {
        let token: SourceToken
        let rect: SourceRect
    }

    private static func normalizedWord(_ rect: SourceRect,
                                       in mediaBox: SourceRect) -> (x: Double, y: Double, w: Double, h: Double) {
        (x: (rect.x - mediaBox.x) / mediaBox.width,
         y: (mediaBox.y + mediaBox.height - rect.y - rect.height) / mediaBox.height,
         w: rect.width / mediaBox.width,
         h: rect.height / mediaBox.height)
    }

    private static func isInsideMediaBox(_ rect: SourceRect, mediaBox: SourceRect) -> Bool {
        let bounds = mediaBox.cgRect.insetBy(dx: -0.01, dy: -0.01)
        return bounds.contains(rect.cgRect)
    }

    private static func intersectionOverUnion(_ first: CGRect, _ second: CGRect) -> Double {
        let intersection = first.intersection(second)
        guard !intersection.isNull, !intersection.isInfinite else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = first.width * first.height + second.width * second.height - intersectionArea
        guard intersectionArea.isFinite, unionArea.isFinite, unionArea > 0 else { return 0 }
        return Double(intersectionArea / unionArea)
    }

    private static func coalescedSeedRanges(_ seeds: [TokenSeed]) -> [ClosedRange<Int>] {
        guard !seeds.isEmpty else { return [] }

        // A shared Vision word box can cover seeds separated by unboxed or
        // separately boxed source tokens. Record the furthest seed paired
        // with each start, then take interval closure so groups cannot cross.
        var maxReach = Array(seeds.indices)
        if seeds.count > 1 {
            for start in 0..<(seeds.count - 1) {
                for candidate in (start + 1)..<seeds.count {
                    if Self.intersectionOverUnion(seeds[start].rect.cgRect,
                                                  seeds[candidate].rect.cgRect) >= 0.9 {
                        maxReach[start] = candidate
                    }
                }
            }
        }

        var mergedIntervals: [ClosedRange<Int>] = []
        for start in seeds.indices {
            let end = maxReach[start]
            guard end > start else { continue }
            if let previous = mergedIntervals.last, start <= previous.upperBound {
                mergedIntervals[mergedIntervals.count - 1] =
                    previous.lowerBound...Swift.max(previous.upperBound, end)
            } else {
                mergedIntervals.append(start...end)
            }
        }

        var groups: [ClosedRange<Int>] = []
        var nextSeed = 0
        for interval in mergedIntervals {
            while nextSeed < interval.lowerBound {
                groups.append(nextSeed...nextSeed)
                nextSeed += 1
            }
            groups.append(interval)
            nextSeed = interval.upperBound + 1
        }
        while nextSeed < seeds.count {
            groups.append(nextSeed...nextSeed)
            nextSeed += 1
        }
        return groups
    }

    private static func isValidSourceToken(_ token: SourceToken,
                                           in line: OCRLine,
                                           page: ContextOCRPage) -> Bool {
        token.documentSHA256 == page.documentSHA256
            && token.pageIndex == page.pageIndex
            && token.blockID == line.blockID
            && token.span.length > 0
            && token.span.composedCharacterRange(in: line.sourceText) != nil
            && token.span.substring(in: line.sourceText) == token.sourceSurface
    }
}
