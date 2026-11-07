import Foundation

/// Creates a translation context only from an exact source block whose bounds
/// came from validated text rows and layout geometry. Sentence punctuation is
/// deliberately not required to define this block.
enum LayoutBlockContextBuilder {
    static let maximumUTF16Units = NativeSentenceContextBuilder.maximumSentenceUTF16Units

    enum BoundaryKind: Equatable {
        case promptStart
        case formulaOrHeading
    }

    static func build(sourceText: String,
                      sourceSpan: UTF16Span,
                      selectedSourceSpans: [UTF16Span],
                      documentSHA256: String,
                      pageIndex: Int,
                      blockID: String,
                      sourceSpanMappings: [SentenceContextSpanMapping] = []) -> SentenceContext? {
        guard !documentSHA256.isEmpty, pageIndex >= 0, !blockID.isEmpty,
              !selectedSourceSpans.isEmpty,
              let sourceRange = sourceSpan.nsRange(in: sourceText),
              sourceRange.length > 0,
              let rawBlock = sourceSpan.substring(in: sourceText) else { return nil }
        let rawLength = (rawBlock as NSString).length
        guard rawLength > 0, rawLength <= maximumUTF16Units else { return nil }

        let contextText = replacingLineBreaksPreservingUTF16(in: rawBlock)
        let contextLength = (contextText as NSString).length
        guard contextLength == rawLength,
              !contextText.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else {
            return nil
        }

        let mappedSelections: [UTF16Span]
        if sourceSpanMappings.isEmpty {
            mappedSelections = selectedSourceSpans.compactMap { sourceSelection in
                guard let end = sourceSelection.endExclusive,
                      sourceSelection.length > 0,
                      sourceSelection.location >= sourceSpan.location,
                      end <= (sourceSpan.endExclusive ?? -1) else { return nil }
                let local = UTF16Span(location: sourceSelection.location - sourceSpan.location,
                                      length: sourceSelection.length)
                guard local.composedCharacterRange(in: contextText) != nil else { return nil }
                return local
            }
        } else {
            guard sourceSpanMappings.count == selectedSourceSpans.count,
                  sourceSpanMappings.map(\.sourceSpan) == selectedSourceSpans else { return nil }
            mappedSelections = sourceSpanMappings.map(\.contextSpan)
            guard mappedSelections.allSatisfy({
                $0.length > 0 && $0.composedCharacterRange(in: contextText) != nil
            }) else { return nil }
            let orderedMappings = sourceSpanMappings.sorted { $0.contextSpan.location < $1.contextSpan.location }
            for pair in zip(orderedMappings, orderedMappings.dropFirst()) {
                guard let previousEnd = pair.0.contextSpan.endExclusive,
                      pair.1.contextSpan.location >= previousEnd else { return nil }
            }
        }
        guard mappedSelections.count == selectedSourceSpans.count,
              mappedSelections.allSatisfy({ $0.length > 0 }) else { return nil }

        let canonical = SemanticTokenizer.canonicalize(contextText,
                                                       documentSHA256: documentSHA256,
                                                       pageIndex: pageIndex,
                                                       blockID: blockID)
        guard canonical.tokens.contains(where: { token in
            token.kind == .word && !mappedSelections.contains(where: { $0.intersects(token.span) })
        }) else { return nil }

        let displaySpan = UTF16Span(location: 0, length: contextLength)
        return SentenceContext(documentSHA256: documentSHA256,
                               pageIndex: pageIndex,
                               blockID: blockID,
                               text: contextText,
                               displayLineText: contextText,
                               displaySentenceText: contextText,
                               sourceSpan: sourceSpan,
                               displaySpan: displaySpan,
                               selectedSourceSpans: selectedSourceSpans,
                               selectedDisplaySpans: mappedSelections,
                               kind: .layoutBlock,
                               sourceSpanMappings: sourceSpanMappings)
    }

    /// Keeps UTF-16 offsets stable for PDFKit, OCR, and attributed translation.
    static func replacingLineBreaksPreservingUTF16(in text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            CharacterSet.newlines.contains(scalar) ? Unicode.Scalar(0x20)! : scalar
        }))
    }

    /// Strong structural signals stop a geometry-adjacent block. This is a
    /// conservative boundary check for equation rows, numbered prompts, and
    /// explicit section/activity labels; punctuation is not used as a boundary.
    static func isStrongContextBoundaryLine(_ text: String) -> Bool {
        boundaryKind(for: text) != nil
    }

    static func boundaryKind(for text: String) -> BoundaryKind? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .formulaOrHeading }
        let folded = trimmed.lowercased()

        let promptLabels = [
            "exercise", "exercises", "problem", "problems", "question", "questions",
            "example", "examples", "activity", "activities", "practice", "review",
            "try", "find", "choose", "match", "write", "fill in", "circle", "calculate",
            "discuss", "练习", "习题", "题目", "例题", "试一试", "自测", "选择", "完成", "匹配", "写出", "填空", "圈出"
        ]
        if promptLabels.contains(where: { folded == $0 || folded.hasPrefix($0 + " ") || folded.hasPrefix($0 + ":") }) {
            return .promptStart
        }

        let sectionLabels = ["module", "chapter", "section", "unit", "lesson", "part",
                             "theorem", "definition", "formula", "模块", "章节", "单元", "定理", "定义", "公式"]
        if sectionLabels.contains(where: { matchesLabel(folded, label: $0) }) {
            return .formulaOrHeading
        }

        let formulaMarkers: Set<Unicode.Scalar> = ["=", "+", "×", "÷", "≤", "≥", "≠", "≈",
                                                   "∑", "∫", "√", "∂", "∇", "→", "↔", "∞"]
        if trimmed.unicodeScalars.contains(where: { formulaMarkers.contains($0) }) {
            return .formulaOrHeading
        }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        if hasNumberedPromptPrefix(trimmed) || hasBulletPrefix(trimmed) { return .promptStart }
        if words.count <= 12, !hasTerminalSentencePunctuation(trimmed) {
            let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            if letters.count >= 3 && letters.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }) {
                return .formulaOrHeading
            }
        }
        return nil
    }

    private static func hasNumberedPromptPrefix(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.first, CharacterSet.decimalDigits.contains(first) else { return false }
        var index = 1
        while index < scalars.count, CharacterSet.decimalDigits.contains(scalars[index]) { index += 1 }
        guard index < scalars.count else { return true }
        if CharacterSet.whitespaces.contains(scalars[index]) { return true }
        guard [".", ")", ":"].contains(String(scalars[index])) else { return false }
        index += 1
        guard index < scalars.count else { return true }
        // Do not treat decimal measurements such as "3.2 m" as a prompt.
        if CharacterSet.decimalDigits.contains(scalars[index]) { return false }
        return CharacterSet.whitespaces.contains(scalars[index])
    }

    private static func matchesLabel(_ text: String, label: String) -> Bool {
        guard text.hasPrefix(label) else { return false }
        guard text.count > label.count else { return true }
        let nextIndex = text.index(text.startIndex, offsetBy: label.count)
        let next = text[nextIndex]
        return next.isWhitespace || next == ":" || next.isNumber
    }

    private static func hasBulletPrefix(_ text: String) -> Bool {
        ["•", "◦", "▪", "▫", "●", "○", "‣", "⁃", "–", "—", "-", "*"].contains { marker in
            text.hasPrefix(marker + " ")
        }
    }

    private static func hasTerminalSentencePunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return [".", "!", "?", "。", "！", "？"].contains(String(last))
    }
}

/// Builds a bounded block from validated native-PDF rows. The supplied block
/// is already geometry-checked by `NativeSentenceContextBuilder`; this layer
/// trims only at explicit structural rows and keeps every source offset exact.
enum NativeLayoutBlockContextBuilder {
    static func build(sourceText: String,
                      trustedSourceBlock: TrustedSourceBlock,
                      selectedSourceSpans: [UTF16Span],
                      documentSHA256: String,
                      pageIndex: Int) -> SentenceContext? {
        guard !selectedSourceSpans.isEmpty,
              let trustedRange = trustedSourceBlock.sourceSpan.nsRange(in: sourceText),
              trustedRange.length > 0,
              selectedSourceSpans.allSatisfy({ contains(trustedSourceBlock.sourceSpan, $0) }),
              let selectionStart = selectedSourceSpans.map(\.location).min(),
              let selectionEnd = selectedSourceSpans.compactMap(\.endExclusive).max(),
              let rows = NativeSentenceContextBuilder.lineSpans(in: sourceText,
                                                                 sourceSpan: trustedSourceBlock.sourceSpan),
              !rows.isEmpty else { return nil }

        let selectedRows = rows.indices.filter { index in
            guard let rowEnd = rows[index].endExclusive else { return false }
            return rows[index].location <= selectionStart && selectionEnd <= rowEnd
        }
        guard selectedRows.count == 1,
              let selectedRow = selectedRows.first else { return nil }

        let seedKind = rows[selectedRow].substring(in: sourceText).flatMap {
            LayoutBlockContextBuilder.boundaryKind(for: $0)
        }
        var first = selectedRow
        var last = selectedRow
        if seedKind != .formulaOrHeading {
            if seedKind != .promptStart {
                while first > 0 {
                    guard let rowText = rows[first - 1].substring(in: sourceText) else { break }
                    switch LayoutBlockContextBuilder.boundaryKind(for: rowText) {
                    case .promptStart:
                        first -= 1
                        break
                    case .formulaOrHeading:
                        break
                    case nil:
                        first -= 1
                        continue
                    }
                    break
                }
            }
            while last + 1 < rows.count {
                guard let rowText = rows[last + 1].substring(in: sourceText),
                      LayoutBlockContextBuilder.boundaryKind(for: rowText) == nil else { break }
                last += 1
            }
        }
        guard let end = rows[last].endExclusive,
              end > rows[first].location else { return nil }
        let boundedSpan = UTF16Span(location: rows[first].location,
                                    length: end - rows[first].location)
        let blockID = "native-layout-\(pageIndex)-\(boundedSpan.location)-\(boundedSpan.length)"
        return LayoutBlockContextBuilder.build(sourceText: sourceText,
                                               sourceSpan: boundedSpan,
                                               selectedSourceSpans: selectedSourceSpans,
                                               documentSHA256: documentSHA256,
                                               pageIndex: pageIndex,
                                               blockID: blockID)
    }

    private static func contains(_ container: UTF16Span, _ candidate: UTF16Span) -> Bool {
        guard let containerEnd = container.endExclusive,
              let candidateEnd = candidate.endExclusive else { return false }
        return container.location <= candidate.location && candidateEnd <= containerEnd
    }
}

/// OCR has line-local source coordinates, so this adapter records the exact
/// line index and offset for each selected span before creating block text.
struct OCRLayoutGeometryIndex: Sendable {
    let linesByIndex: [Int: OCRLayoutBlockContextBuilder.Line]
    let unindexedTextPrefixCounts: [Int]
    let verticalLineIndices: [Int]
    let verticalPositionByLineIndex: [Int: Int]

    init(page: ContextOCRPage) {
        var lines: [Int: OCRLayoutBlockContextBuilder.Line] = [:]
        var unindexedTextLines = Set<Int>()
        for index in page.lines.indices {
            guard !page.lines[index].sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let rect = page.lines[index].pageRect,
                  page.mediaBox.cgRect.insetBy(dx: -0.01, dy: -0.01).contains(rect.cgRect) else {
                unindexedTextLines.insert(index)
                continue
            }
            let geometryIsTrusted = Self.hasTrustedHorizontalTokenGeometry(page.lines[index],
                                                                           page: page,
                                                                           mediaBox: page.mediaBox)
            lines[index] = OCRLayoutBlockContextBuilder.Line(pageIndex: index,
                                                              sourceText: page.lines[index].sourceText,
                                                              rect: rect,
                                                              tokenGeometryIsTrusted: geometryIsTrusted)
        }
        var unindexedPrefix = Array(repeating: 0, count: page.lines.count + 1)
        for index in page.lines.indices {
            unindexedPrefix[index + 1] = unindexedPrefix[index] + (unindexedTextLines.contains(index) ? 1 : 0)
        }
        let ordered = lines.keys.sorted { leftIndex, rightIndex in
            let left = lines[leftIndex]!.cgRect
            let right = lines[rightIndex]!.cgRect
            if left.midY != right.midY { return left.midY > right.midY }
            if left.minX != right.minX { return left.minX < right.minX }
            return leftIndex < rightIndex
        }
        self.linesByIndex = lines
        self.unindexedTextPrefixCounts = unindexedPrefix
        self.verticalLineIndices = ordered
        self.verticalPositionByLineIndex = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })
    }

    func hasUnindexedTextLine(between firstIndex: Int, and secondIndex: Int) -> Bool {
        let lower = min(firstIndex, secondIndex) + 1
        let upper = max(firstIndex, secondIndex)
        guard lower < upper,
              unindexedTextPrefixCounts.indices.contains(lower),
              unindexedTextPrefixCounts.indices.contains(upper) else { return false }
        return unindexedTextPrefixCounts[upper] > unindexedTextPrefixCounts[lower]
    }

    private static func hasTrustedHorizontalTokenGeometry(_ line: OCRLine,
                                                          page: ContextOCRPage,
                                                          mediaBox: SourceRect) -> Bool {
        let semanticTokens = line.tokens.filter { $0.kind == .word || $0.kind == .number }
            .sorted { $0.span.location < $1.span.location }
        guard !semanticTokens.isEmpty else { return true }
        let geometryByID = Dictionary(grouping: line.tokenGeometry, by: \.tokenID)
        var rects: [CGRect] = []
        for token in semanticTokens {
            guard token.span.composedCharacterRange(in: line.sourceText) != nil,
                  token.documentSHA256 == page.documentSHA256,
                  token.pageIndex == page.pageIndex,
                  token.blockID == line.blockID,
                  token.span.substring(in: line.sourceText) == token.sourceSurface,
                  let geometry = geometryByID[token.id], geometry.count == 1,
                  geometry[0].span == token.span,
                  geometry[0].quality == .word || geometry[0].quality == .verifiedCharacter,
                  let rect = geometry[0].rect?.cgRect,
                  SelectionGeometry.isValid(rect),
                  mediaBox.cgRect.insetBy(dx: -0.01, dy: -0.01).contains(rect) else { return false }
            rects.append(rect)
        }
        guard rects.count == semanticTokens.count else { return false }
        guard rects.count > 1 else { return true }
        for pair in zip(rects, rects.dropFirst()) {
            let maximumHeight = max(pair.0.height, pair.1.height)
            let horizontalGap = pair.1.minX - pair.0.maxX
            guard pair.1.midX > pair.0.midX,
                  abs(pair.0.midY - pair.1.midY) <= maximumHeight * 0.6,
                  horizontalGap >= -maximumHeight * 0.35,
                  horizontalGap <= maximumHeight * 1.5 else { return false }
        }
        return true
    }
}

enum OCRLayoutBlockContextBuilder {
    private static let maximumNeighborLines = 8
    private static let maximumCandidateLinesPerSide = 64

    struct Line: Sendable {
        let pageIndex: Int
        let sourceText: String
        let rect: SourceRect
        let tokenGeometryIsTrusted: Bool

        var cgRect: CGRect { rect.cgRect }
    }

    private struct Candidate {
        let lineIndex: Int
        let verticalGap: CGFloat
        let overlapRatio: CGFloat
        let leftEdgeDrift: CGFloat
    }

    static func build(page: ContextOCRPage,
                      geometryIndex: OCRLayoutGeometryIndex,
                      selectedLineIndex: Int,
                      selectedSourceSpans: [UTF16Span]) -> SentenceContext? {
        guard page.lines.indices.contains(selectedLineIndex),
              !selectedSourceSpans.isEmpty,
              let selectedLine = geometryIndex.linesByIndex[selectedLineIndex],
              selectedLine.tokenGeometryIsTrusted,
              selectedSourceSpans.allSatisfy({ span in
                  span.length > 0 && span.composedCharacterRange(in: selectedLine.sourceText) != nil
              }) else { return nil }

        let selectedBoundary = LayoutBlockContextBuilder.boundaryKind(for: selectedLine.sourceText)
        var orderedLineIndices = [selectedLineIndex]
        if selectedBoundary != .formulaOrHeading {
            if selectedBoundary != .promptStart {
                orderedLineIndices = extend(geometryIndex: geometryIndex,
                                            from: selectedLineIndex,
                                            direction: .above)
            }
            let last = orderedLineIndices.last ?? selectedLineIndex
            let below = extend(geometryIndex: geometryIndex,
                               from: last,
                               direction: .below,
                               alreadyIncluded: Set(orderedLineIndices))
            orderedLineIndices += below.dropFirst()
        }
        guard orderedLineIndices.count <= maximumNeighborLines * 2 + 1 else { return nil }

        var offsetsByLineIndex: [Int: Int] = [:]
        var blockParts: [String] = []
        var offset = 0
        for (partIndex, lineIndex) in orderedLineIndices.enumerated() {
            guard let line = geometryIndex.linesByIndex[lineIndex],
                  line.tokenGeometryIsTrusted,
                  !line.sourceText.isEmpty else { return nil }
            if partIndex > 0 { offset += 1 } // Synthetic LF is normalized to an equal-width space.
            offsetsByLineIndex[lineIndex] = offset
            blockParts.append(line.sourceText)
            offset += (line.sourceText as NSString).length
            guard offset <= LayoutBlockContextBuilder.maximumUTF16Units else { return nil }
        }
        let rawBlock = blockParts.joined(separator: "\n")
        guard (rawBlock as NSString).length == offset,
              let selectedBlockOffset = offsetsByLineIndex[selectedLineIndex] else { return nil }
        let mappings = selectedSourceSpans.map { span in
            SentenceContextSpanMapping(lineIndex: selectedLineIndex,
                                       sourceSpan: span,
                                       contextSpan: UTF16Span(location: selectedBlockOffset + span.location,
                                                             length: span.length))
        }
        guard let firstLineIndex = orderedLineIndices.first,
              let lastLineIndex = orderedLineIndices.last else { return nil }
        let firstID = page.lines[firstLineIndex].blockID
        let lastID = page.lines[lastLineIndex].blockID
        return LayoutBlockContextBuilder.build(sourceText: rawBlock,
                                               sourceSpan: UTF16Span(location: 0, length: offset),
                                               selectedSourceSpans: selectedSourceSpans,
                                               documentSHA256: page.documentSHA256,
                                               pageIndex: page.pageIndex,
                                               blockID: "ocr-layout-\(firstID)-\(lastID)-\(selectedLineIndex)",
                                               sourceSpanMappings: mappings)
    }

    private enum Direction: Equatable { case above, below }

    private static func extend(geometryIndex: OCRLayoutGeometryIndex,
                               from startIndex: Int,
                               direction: Direction,
                               alreadyIncluded: Set<Int> = []) -> [Int] {
        var result = [startIndex]
        var currentIndex = startIndex
        while result.count <= maximumNeighborLines {
            guard let current = geometryIndex.linesByIndex[currentIndex] else { break }
            let currentBoundary = LayoutBlockContextBuilder.boundaryKind(for: current.sourceText)
            if !current.tokenGeometryIsTrusted || currentBoundary == .formulaOrHeading { break }
            if currentBoundary == .promptStart && direction == .above { break }
            guard let candidate = nearestAdjacentLine(to: current,
                                                      currentIndex: currentIndex,
                                                      geometryIndex: geometryIndex,
                                                      direction: direction,
                                                      excluding: alreadyIncluded.union(result)) else { break }
            guard let next = geometryIndex.linesByIndex[candidate.lineIndex] else { break }
            let nextBoundary = LayoutBlockContextBuilder.boundaryKind(for: next.sourceText)
            if nextBoundary == .formulaOrHeading { break }
            if nextBoundary == .promptStart {
                if direction == .above && next.tokenGeometryIsTrusted {
                    result.insert(candidate.lineIndex, at: 0)
                }
                break
            }
            guard next.tokenGeometryIsTrusted else { break }
            if direction == .above {
                result.insert(candidate.lineIndex, at: 0)
            } else {
                result.append(candidate.lineIndex)
            }
            currentIndex = candidate.lineIndex
        }
        return result
    }

    private static func nearestAdjacentLine(to current: Line,
                                            currentIndex: Int,
                                            geometryIndex: OCRLayoutGeometryIndex,
                                            direction: Direction,
                                            excluding excluded: Set<Int>) -> Candidate? {
        guard let position = geometryIndex.verticalPositionByLineIndex[currentIndex] else { return nil }
        var candidates: [Candidate] = []
        var inspected = 0
        let positions: AnySequence<Int>
        switch direction {
        case .above:
            positions = AnySequence((0..<position).reversed())
        case .below:
            positions = AnySequence((position + 1)..<geometryIndex.verticalLineIndices.count)
        }
        for candidatePosition in positions {
            guard inspected < maximumCandidateLinesPerSide else { return nil }
            inspected += 1
            let candidateIndex = geometryIndex.verticalLineIndices[candidatePosition]
            guard !excluded.contains(candidateIndex),
                  let line = geometryIndex.linesByIndex[candidateIndex] else { continue }
            let pair: [CGRect]
            let gap: CGFloat
            switch direction {
            case .above:
                guard line.cgRect.midY > current.cgRect.midY else { continue }
                gap = line.cgRect.midY - current.cgRect.midY
                pair = [line.cgRect, current.cgRect]
            case .below:
                guard line.cgRect.midY < current.cgRect.midY else { continue }
                gap = current.cgRect.midY - line.cgRect.midY
                pair = [current.cgRect, line.cgRect]
            }
            let maximumGap = max(line.cgRect.height, current.cgRect.height) * 2.4
            if gap > maximumGap { break }
            guard NativeSentenceContextBuilder.hasTrustedAdjacentLineGeometry(pair) else { continue }
            if geometryIndex.hasUnindexedTextLine(between: candidateIndex, and: currentIndex) {
                return nil
            }
            let overlap = max(0, min(line.cgRect.maxX, current.cgRect.maxX) - max(line.cgRect.minX, current.cgRect.minX))
            candidates.append(Candidate(lineIndex: line.pageIndex,
                                        verticalGap: gap,
                                        overlapRatio: overlap / min(line.cgRect.width, current.cgRect.width),
                                        leftEdgeDrift: abs(line.cgRect.minX - current.cgRect.minX)))
        }
        let sorted = candidates.sorted {
            if abs($0.verticalGap - $1.verticalGap) > 0.5 { return $0.verticalGap < $1.verticalGap }
            if abs($0.overlapRatio - $1.overlapRatio) > 0.01 { return $0.overlapRatio > $1.overlapRatio }
            return $0.leftEdgeDrift < $1.leftEdgeDrift
        }
        guard let best = sorted.first else { return nil }
        if sorted.count > 1 {
            let second = sorted[1]
            let height = max(current.cgRect.height, CGFloat(1))
            let sameRow = abs(best.verticalGap - second.verticalGap) <= height * 0.2
            let indistinguishable = abs(best.overlapRatio - second.overlapRatio) < 0.1
                && abs(best.leftEdgeDrift - second.leftEdgeDrift) <= height * 0.25
            if sameRow && indistinguishable { return nil }
        }
        return best
    }
}
