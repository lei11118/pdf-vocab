import Foundation

/// Applies trusted fast-character boxes as atomic token components.
/// `verifiedCharacter` means source identity and complete character coverage
/// passed these checks; it is not a pixel-precision or statistical guarantee.
enum OCRCharacterGeometryComposer {
    private struct ParentEntry {
        let nodes: [Int]
        let rect: CGRect
    }

    private struct TokenProposal {
        let rect: SourceRect
        let geometryIndex: Int?
    }

    private struct VerifiedPair {
        let geometry: SourceTokenGeometry
    }

    private struct DisjointSet {
        private var parents: [Int]
        private var ranks: [Int]

        init(count: Int) {
            parents = Array(0..<count)
            ranks = Array(repeating: 0, count: count)
        }

        mutating func find(_ item: Int) -> Int {
            var root = item
            while parents[root] != root { root = parents[root] }

            var cursor = item
            while parents[cursor] != cursor {
                let next = parents[cursor]
                parents[cursor] = root
                cursor = next
            }
            return root
        }

        mutating func union(_ first: Int, _ second: Int) {
            let firstRoot = find(first)
            let secondRoot = find(second)
            guard firstRoot != secondRoot else { return }

            if ranks[firstRoot] < ranks[secondRoot] {
                parents[firstRoot] = secondRoot
            } else if ranks[firstRoot] > ranks[secondRoot] {
                parents[secondRoot] = firstRoot
            } else {
                parents[secondRoot] = firstRoot
                ranks[firstRoot] += 1
            }
        }
    }

    /// Adds verified character unions to a copy of `page`. The source text,
    /// candidates, token IDs, spans, and page revision remain unchanged.
    static func apply(page: ContextOCRPage,
                      refinementsByBlockID: [String: OCRCharacterRefinementResult]) -> ContextOCRPage {
        guard !page.documentSHA256.isEmpty, page.pageIndex >= 0, page.revision >= 0,
              !refinementsByBlockID.isEmpty else { return page }
        let lineIndicesByBlockID = Dictionary(grouping: page.lines.indices) {
            page.lines[$0].blockID
        }

        var updatedLines = page.lines
        var didChange = false
        for lineIndex in page.lines.indices {
            let originalLine = page.lines[lineIndex]
            guard lineIndicesByBlockID[originalLine.blockID]?.count == 1,
                  let refinement = refinementsByBlockID[originalLine.blockID],
                  let updatedLine = apply(refinement,
                                          to: originalLine,
                                          lineIndex: lineIndex,
                                          page: page),
                  updatedLine != originalLine else { continue }
            updatedLines[lineIndex] = updatedLine
            didChange = true
        }

        guard didChange else { return page }
        return ContextOCRPage(documentSHA256: page.documentSHA256,
                              pageIndex: page.pageIndex,
                              revision: page.revision,
                              mediaBox: page.mediaBox,
                              lines: updatedLines)
    }

    /// Preserves previously verified geometry when an older full-page OCR
    /// result arrives after a same-generation refinement. It only carries a
    /// token/geometry pair across an identical source and line layout.
    static func mergePreservingVerifiedGeometry(existing: ContextOCRPage,
                                                incoming: ContextOCRPage) -> ContextOCRPage {
        guard existing.documentSHA256 == incoming.documentSHA256,
              !existing.documentSHA256.isEmpty,
              existing.pageIndex == incoming.pageIndex,
              existing.pageIndex >= 0,
              existing.revision == incoming.revision,
              existing.revision >= 0,
              existing.mediaBox == incoming.mediaBox else { return incoming }

        let existingLinesByBlockID = Dictionary(grouping: existing.lines.indices) {
            existing.lines[$0].blockID
        }
        let incomingLinesByBlockID = Dictionary(grouping: incoming.lines.indices) {
            incoming.lines[$0].blockID
        }
        var mergedLines = incoming.lines
        var didChange = false

        for incomingIndex in incoming.lines.indices {
            let incomingLine = incoming.lines[incomingIndex]
            guard incomingLinesByBlockID[incomingLine.blockID]?.count == 1,
                  let existingIndices = existingLinesByBlockID[incomingLine.blockID],
                  existingIndices.count == 1 else { continue }
            let existingLine = existing.lines[existingIndices[0]]
            guard linesHaveSameSourceAndLayout(existingLine, existing: existing,
                                               incomingLine, incoming: incoming) else { continue }

            let oldVerified = verifiedPairs(in: existingLine, page: existing)
            guard !oldVerified.isEmpty else { continue }
            let incomingVerified = verifiedPairs(in: incomingLine, page: incoming)
            let incomingGeometryByTokenID = Dictionary(grouping: incomingLine.tokenGeometry,
                                                       by: \.tokenID)
            var tokens = incomingLine.tokens
            var geometry = incomingLine.tokenGeometry
            var lineChanged = false

            for tokenIndex in tokens.indices {
                let token = tokens[tokenIndex]
                guard let old = oldVerified[token.id],
                      !incomingVerified.keys.contains(token.id) else { continue }
                let geometryMatches = incomingGeometryByTokenID[token.id] ?? []

                if geometryMatches.isEmpty && token.geometryQuality == .unknown {
                    tokens[tokenIndex] = token.withGeometryQuality(.verifiedCharacter)
                    geometry.append(old.geometry)
                    lineChanged = true
                    continue
                }
                guard geometryMatches.count == 1,
                      geometryMatches[0].span == token.span,
                      let geometryIndex = geometry.firstIndex(where: {
                          $0.tokenID == token.id && $0.span == token.span
                      }) else { continue }

                tokens[tokenIndex] = token.withGeometryQuality(.verifiedCharacter)
                geometry[geometryIndex] = old.geometry
                lineChanged = true
            }

            guard lineChanged else { continue }
            mergedLines[incomingIndex] = OCRLine(blockID: incomingLine.blockID,
                                                 candidates: incomingLine.candidates,
                                                 regionRect: incomingLine.regionRect,
                                                 pageRect: incomingLine.pageRect,
                                                 tokens: tokens,
                                                 tokenGeometry: geometry)
            didChange = true
        }

        guard didChange else { return incoming }
        return ContextOCRPage(documentSHA256: incoming.documentSHA256,
                              pageIndex: incoming.pageIndex,
                              revision: incoming.revision,
                              mediaBox: incoming.mediaBox,
                              lines: mergedLines)
    }

    private static func apply(_ refinement: OCRCharacterRefinementResult,
                              to line: OCRLine,
                              lineIndex: Int,
                              page: ContextOCRPage) -> OCRLine? {
        guard refinement.fallback == nil,
              !line.blockID.isEmpty,
              sameUTF16(refinement.sourceText, line.sourceText),
              refinement.mediaBox == page.mediaBox,
              let sourceLine = line.pageRect?.cgRect,
              line.sourceText.utf16.count > 0,
              isWithinAlignmentLimits(line.sourceText),
              isFinitePositive(sourceLine),
              isFinitePositive(refinement.roi.cgRect),
              refinement.roi.width > 1, refinement.roi.height > 1,
              contains(refinement.roi.cgRect, in: page.mediaBox.cgRect),
              contains(sourceLine, in: page.mediaBox.cgRect, tolerance: 0.000_001),
              contains(sourceLine, in: refinement.roi.cgRect, tolerance: 0.000_001) else {
            return nil
        }

        let candidateTokenIndices = line.tokens.indices.filter {
            isValidSourceToken(line.tokens[$0], line: line, page: page)
        }
        let tokenIndicesBySpan = Dictionary(grouping: candidateTokenIndices) {
            line.tokens[$0].span
        }
        let tokenIndicesByID = Dictionary(grouping: candidateTokenIndices) {
            line.tokens[$0].id
        }
        let validTokenIndices = candidateTokenIndices.filter { tokenIndex in
            let token = line.tokens[tokenIndex]
            return tokenIndicesBySpan[token.span]?.count == 1
                && tokenIndicesByID[token.id]?.count == 1
        }
        guard !validTokenIndices.isEmpty else { return nil }

        let geometryByTokenID = Dictionary(grouping: line.tokenGeometry, by: \.tokenID)
        let expandedSourceLine = expanded(sourceLine, fractionOfHeight: 0.25)
        var characterRectsBySpan: [UTF16Span: SourceRect] = [:]
        let boxesBySpan = Dictionary(grouping: refinement.boxes, by: \.sourceSpan)
        for (span, boxes) in boxesBySpan where boxes.count == 1 {
            guard let box = boxes.first,
                  box.geometrySource == .visionFast,
                  box.mappingSource == .mandatoryExactMapping,
                  isSingleNonWhitespaceCharacter(span, in: line.sourceText),
                  isFinitePositive(box.actualRect.cgRect),
                  contains(box.actualRect.cgRect, in: page.mediaBox.cgRect),
                  contains(box.actualRect.cgRect, in: refinement.roi.cgRect),
                  contains(box.actualRect.cgRect, in: expandedSourceLine, tolerance: 0.000_001),
                  passesWordFrameChecks(for: span,
                                        rect: box.actualRect.cgRect,
                                        tokens: validTokenIndices.map { line.tokens[$0] },
                                        geometryByTokenID: geometryByTokenID,
                                        mediaBox: page.mediaBox) else { continue }
            characterRectsBySpan[span] = box.actualRect
        }

        let ambiguousSpans = nearlyDuplicatedCharacterSpans(characterRectsBySpan)
        for span in ambiguousSpans { characterRectsBySpan.removeValue(forKey: span) }

        var proposalsByNode: [Int: TokenProposal] = [:]
        for (node, tokenIndex) in validTokenIndices.enumerated() {
            let token = line.tokens[tokenIndex]
            let matchingGeometry = geometryByTokenID[token.id] ?? []
            let geometryIndex: Int?
            if matchingGeometry.isEmpty && token.geometryQuality == .unknown {
                geometryIndex = nil
            } else {
                guard matchingGeometry.count == 1,
                      matchingGeometry[0].span == token.span,
                      matchingGeometry[0].quality == token.geometryQuality,
                      let index = line.tokenGeometry.firstIndex(where: {
                          $0.tokenID == token.id && $0.span == token.span
                      }) else { continue }
                geometryIndex = index
            }
            guard let proposal = proposedTokenRect(for: token,
                                                  sourceText: line.sourceText,
                                                  characterRectsBySpan: characterRectsBySpan) else { continue }
            proposalsByNode[node] = TokenProposal(rect: proposal, geometryIndex: geometryIndex)
        }

        let baseSource = ContextOCRSelectionSource(page: page)
        var disjointSet = DisjointSet(count: validTokenIndices.count)
        var parentEntries: [ParentEntry] = []
        let nodeByTokenID = Dictionary(uniqueKeysWithValues: validTokenIndices.enumerated().map {
            (line.tokens[$0.element].id, $0.offset)
        })

        for entry in baseSource?.entries ?? [] where entry.lineIndex == lineIndex
            && entry.blockID == line.blockID {
            let nodes = entry.tokens.compactMap { nodeByTokenID[$0.id] }
            guard !nodes.isEmpty, nodes.count == entry.tokens.count else { continue }
            for node in nodes.dropFirst() { disjointSet.union(nodes[0], node) }

            let parentRect = OCRService.pageRect(from: entry.word, pageBounds: page.mediaBox.cgRect)
            guard isFinitePositive(parentRect) else { continue }
            parentEntries.append(ParentEntry(nodes: nodes, rect: parentRect))
        }

        if parentEntries.count > 1 {
            for firstIndex in 0..<(parentEntries.count - 1) {
                for secondIndex in (firstIndex + 1)..<parentEntries.count {
                    guard hasSubstantialIntersection(parentEntries[firstIndex].rect,
                                                     parentEntries[secondIndex].rect) else { continue }
                    union(parentEntries[firstIndex].nodes,
                          parentEntries[secondIndex].nodes,
                          in: &disjointSet)
                }
            }
        }

        for (node, proposal) in proposalsByNode {
            for parent in parentEntries where hasSubstantialIntersection(proposal.rect.cgRect, parent.rect) {
                for member in parent.nodes { disjointSet.union(node, member) }
            }
        }

        var components: [Int: [Int]] = [:]
        for node in validTokenIndices.indices {
            let root = disjointSet.find(node)
            components[root, default: []].append(node)
        }
        let promotedNodes = components.values
            .filter { $0.allSatisfy { proposalsByNode[$0] != nil } }
            .flatMap { $0 }
        guard !promotedNodes.isEmpty else { return nil }

        var updatedTokens = line.tokens
        var updatedGeometry = line.tokenGeometry
        for node in promotedNodes {
            let token = line.tokens[validTokenIndices[node]]
            let proposal = proposalsByNode[node]!
            updatedTokens[validTokenIndices[node]] = token.withGeometryQuality(.verifiedCharacter)
            let verifiedGeometry = SourceTokenGeometry(tokenID: token.id,
                                                      span: token.span,
                                                      rect: proposal.rect,
                                                      quality: .verifiedCharacter)
            if let geometryIndex = proposal.geometryIndex {
                updatedGeometry[geometryIndex] = verifiedGeometry
            } else {
                updatedGeometry.append(verifiedGeometry)
            }
        }

        let updatedLine = OCRLine(blockID: line.blockID,
                                  candidates: line.candidates,
                                  regionRect: line.regionRect,
                                  pageRect: line.pageRect,
                                  tokens: updatedTokens,
                                  tokenGeometry: updatedGeometry)
        return updatedLine == line ? nil : updatedLine
    }

    private static func linesHaveSameSourceAndLayout(_ existingLine: OCRLine,
                                                     existing: ContextOCRPage,
                                                     _ incomingLine: OCRLine,
                                                     incoming: ContextOCRPage) -> Bool {
        guard !existingLine.blockID.isEmpty,
              existingLine.blockID == incomingLine.blockID,
              sameUTF16(existingLine.sourceText, incomingLine.sourceText),
              existingLine.regionRect == incomingLine.regionRect,
              existingLine.pageRect == incomingLine.pageRect,
              existingLine.tokens.count == incomingLine.tokens.count else { return false }

        for (oldToken, newToken) in zip(existingLine.tokens, incomingLine.tokens) {
            guard oldToken.id == newToken.id,
                  oldToken.span == newToken.span,
                  oldToken.kind == newToken.kind,
                  sameUTF16(oldToken.sourceSurface, newToken.sourceSurface),
                  isValidSourceToken(oldToken, line: existingLine, page: existing),
                  isValidSourceToken(newToken, line: incomingLine, page: incoming) else { return false }
        }
        return true
    }

    private static func verifiedPairs(in line: OCRLine,
                                      page: ContextOCRPage) -> [String: VerifiedPair] {
        guard let sourceLine = line.pageRect?.cgRect,
              isFinitePositive(sourceLine),
              contains(sourceLine, in: page.mediaBox.cgRect, tolerance: 0.000_001),
              isWithinAlignmentLimits(line.sourceText) else { return [:] }

        let validTokens = line.tokens.filter { isValidSourceToken($0, line: line, page: page) }
        let tokenCounts = Dictionary(grouping: validTokens, by: \.id)
        let spanCounts = Dictionary(grouping: validTokens, by: \.span)
        let geometryByTokenID = Dictionary(grouping: line.tokenGeometry, by: \.tokenID)
        let lineExpansion = expanded(sourceLine, fractionOfHeight: 0.25)
        var pairs: [String: VerifiedPair] = [:]

        for token in validTokens where token.geometryQuality == .verifiedCharacter {
            guard tokenCounts[token.id]?.count == 1,
                  spanCounts[token.span]?.count == 1,
                  let geometries = geometryByTokenID[token.id], geometries.count == 1,
                  let geometry = geometries.first,
                  geometry.span == token.span,
                  geometry.quality == .verifiedCharacter,
                  let rect = geometry.rect,
                  isFinitePositive(rect.cgRect),
                  contains(rect.cgRect, in: page.mediaBox.cgRect),
                  contains(rect.cgRect, in: lineExpansion, tolerance: 0.000_001) else { continue }
            pairs[token.id] = VerifiedPair(geometry: geometry)
        }
        return pairs
    }

    private static func isValidSourceToken(_ token: SourceToken,
                                          line: OCRLine,
                                          page: ContextOCRPage) -> Bool {
        guard token.documentSHA256 == page.documentSHA256,
              token.pageIndex == page.pageIndex,
              token.blockID == line.blockID,
              token.span.length > 0,
              let range = token.span.composedCharacterRange(in: line.sourceText),
              range.length == token.span.length,
              let surface = token.span.substring(in: line.sourceText) else { return false }
        return sameUTF16(surface, token.sourceSurface)
    }

    private static func isSingleNonWhitespaceCharacter(_ span: UTF16Span, in source: String) -> Bool {
        guard span.length > 0,
              let range = span.composedCharacterRange(in: source),
              range.length == span.length else { return false }
        let nsSource = source as NSString
        let characterRange = nsSource.rangeOfComposedCharacterSequence(at: span.location)
        guard characterRange.location == span.location,
              characterRange.length == span.length else { return false }
        let character = nsSource.substring(with: range)
        return !isWhitespace(character)
    }

    private static func proposedTokenRect(for token: SourceToken,
                                          sourceText: String,
                                          characterRectsBySpan: [UTF16Span: SourceRect]) -> SourceRect? {
        guard let end = token.span.endExclusive,
              token.span.length > 0,
              token.span.composedCharacterRange(in: sourceText) != nil else { return nil }
        let nsSource = sourceText as NSString
        var offset = token.span.location
        var unionRect: CGRect?
        var coveredCharacterCount = 0

        while offset < end {
            let range = nsSource.rangeOfComposedCharacterSequence(at: offset)
            guard range.location == offset, range.length > 0,
                  range.length <= end - offset,
                  let characterSpan = UTF16Span(composedRange: range, in: sourceText) else { return nil }
            let character = nsSource.substring(with: range)
            if !isWhitespace(character) {
                guard let rect = characterRectsBySpan[characterSpan] else { return nil }
                unionRect = unionRect.map { $0.union(rect.cgRect) } ?? rect.cgRect
                coveredCharacterCount += 1
            }
            offset += range.length
        }

        guard coveredCharacterCount > 0, let unionRect else { return nil }
        return SourceRect(rect: unionRect)
    }

    private static func passesWordFrameChecks(for characterSpan: UTF16Span,
                                              rect: CGRect,
                                              tokens: [SourceToken],
                                              geometryByTokenID: [String: [SourceTokenGeometry]],
                                              mediaBox: SourceRect) -> Bool {
        guard let characterEnd = characterSpan.endExclusive else { return false }
        for token in tokens where token.geometryQuality == .word {
            guard let tokenEnd = token.span.endExclusive,
                  token.span.location <= characterSpan.location,
                  tokenEnd >= characterEnd else { continue }
            guard let geometries = geometryByTokenID[token.id], geometries.count == 1,
                  let geometry = geometries.first,
                  geometry.span == token.span,
                  geometry.quality == .word,
                  let wordRect = geometry.rect?.cgRect,
                  isFinitePositive(wordRect),
                  contains(wordRect, in: mediaBox.cgRect),
                  contains(rect, in: expanded(wordRect, fractionOfHeight: 0.2),
                           tolerance: 0.000_001) else { return false }
        }
        return true
    }

    private static func nearlyDuplicatedCharacterSpans(_ rectangles: [UTF16Span: SourceRect]) -> Set<UTF16Span> {
        let ordered = rectangles.keys.sorted {
            $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
        }
        guard ordered.count > 1 else { return [] }
        var ambiguous = Set<UTF16Span>()
        for firstIndex in 0..<(ordered.count - 1) {
            guard let first = rectangles[ordered[firstIndex]]?.cgRect else { continue }
            for secondIndex in (firstIndex + 1)..<ordered.count {
                guard let second = rectangles[ordered[secondIndex]]?.cgRect,
                      intersectionOverUnion(first, second) >= 0.9 else { continue }
                ambiguous.insert(ordered[firstIndex])
                ambiguous.insert(ordered[secondIndex])
            }
        }
        return ambiguous
    }

    private static func union(_ first: [Int], _ second: [Int], in set: inout DisjointSet) {
        guard let firstNode = first.first else { return }
        for node in first.dropFirst() { set.union(firstNode, node) }
        for node in second { set.union(firstNode, node) }
    }

    private static func hasSubstantialIntersection(_ first: CGRect, _ second: CGRect) -> Bool {
        let intersection = first.intersection(second)
        return !intersection.isNull && !intersection.isInfinite
            && intersection.width.isFinite && intersection.height.isFinite
            && intersection.width > 0.01 && intersection.height > 0.01
    }

    private static func intersectionOverUnion(_ first: CGRect, _ second: CGRect) -> Double {
        let intersection = first.intersection(second)
        guard !intersection.isNull, !intersection.isInfinite else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = first.width * first.height + second.width * second.height - intersectionArea
        guard intersectionArea.isFinite, unionArea.isFinite, unionArea > 0 else { return 0 }
        return Double(intersectionArea / unionArea)
    }

    private static func expanded(_ rect: CGRect, fractionOfHeight: CGFloat) -> CGRect {
        let margin = max(2, rect.height * fractionOfHeight)
        return rect.insetBy(dx: -margin, dy: -margin)
    }

    private static func contains(_ rect: CGRect, in bounds: CGRect) -> Bool {
        isFinitePositive(rect) && isFinitePositive(bounds)
            && rect.minX >= bounds.minX && rect.minY >= bounds.minY
            && rect.maxX <= bounds.maxX && rect.maxY <= bounds.maxY
    }

    private static func contains(_ rect: CGRect, in bounds: CGRect, tolerance: CGFloat) -> Bool {
        isFinitePositive(rect) && isFinitePositive(bounds)
            && rect.minX >= bounds.minX - tolerance && rect.minY >= bounds.minY - tolerance
            && rect.maxX <= bounds.maxX + tolerance && rect.maxY <= bounds.maxY + tolerance
    }

    private static func isFinitePositive(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
            && rect.maxX.isFinite && rect.maxY.isFinite
            && !rect.isNull && !rect.isInfinite
    }

    private static func isWhitespace(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func sameUTF16(_ first: String, _ second: String) -> Bool {
        first.utf16.elementsEqual(second.utf16)
    }

    private static func isWithinAlignmentLimits(_ text: String) -> Bool {
        let nsText = text as NSString
        guard nsText.length <= OCRCharacterAligner.maximumUTF16Units else { return false }
        var graphemeCount = 0
        var offset = 0
        while offset < nsText.length {
            let range = nsText.rangeOfComposedCharacterSequence(at: offset)
            guard range.location == offset, range.length > 0,
                  range.length <= nsText.length - offset else { return false }
            graphemeCount += 1
            guard graphemeCount <= OCRCharacterAligner.maximumGraphemes else { return false }
            offset += range.length
        }
        return true
    }
}
