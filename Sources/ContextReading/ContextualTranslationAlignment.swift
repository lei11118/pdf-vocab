import Foundation

/// An occurrence of a reading token in one exact sentence. IDs identify a
/// position, not a spelling, so repeated words remain distinguishable.
struct ContextualTranslationToken: Equatable, Sendable {
    let id: String
    let sourceSpan: UTF16Span
    let sourceSurface: String
}

/// An explicitly verified multiword phrase, aligned as one semantic unit
/// while the underlying word tokens remain available in the same request.
struct ContextualTranslationPhraseGroup: Equatable, Sendable {
    let id: String
    let sourceSpan: UTF16Span
    let sourceSurface: String
}

/// A validated, sentence-local request. The sentence is sent to Translation,
/// while only the selected token range is ever returned to the card.
struct ContextualTranslationRequest: Equatable, Sendable {
    let sentenceText: String
    let tokens: [ContextualTranslationToken]
    let selectedTokenIDs: [String]
    let selectedSourceSpans: [UTF16Span]
    let selectedSourcePhrase: String
    let selectedPhraseGroup: ContextualTranslationPhraseGroup?

    static let maximumInputUTF16Units = 2_048

    static func make(from context: SentenceContext,
                     verifiedPhraseGroupSpan: UTF16Span? = nil) throws -> ContextualTranslationRequest {
        guard context.kind == .completeSentence else { throw ContextualTranslationError.incompleteSentence }
        guard !context.text.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else {
            throw ContextualTranslationError.incompleteSentence
        }
        guard !context.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextualTranslationError.emptyInput
        }
        let sentenceLength = (context.text as NSString).length
        guard sentenceLength <= maximumInputUTF16Units else {
            throw ContextualTranslationError.inputTooLong(maximumUTF16Units: maximumInputUTF16Units)
        }
        guard !context.selectedSourceSpans.isEmpty,
              context.sourceSpan.length == sentenceLength,
              context.sourceSpan.location >= 0,
              context.sourceSpan.endExclusive != nil else {
            throw ContextualTranslationError.invalidSelection
        }

        let localSelections = try localSelectionSpans(in: context)
        let localPhraseGroupSpan: UTF16Span?
        if let verifiedPhraseGroupSpan {
            guard context.selectedSourceSpans == [verifiedPhraseGroupSpan],
                  verifiedPhraseGroupSpan.location >= context.sourceSpan.location,
                  let verifiedEnd = verifiedPhraseGroupSpan.endExclusive,
                  verifiedEnd <= (context.sourceSpan.endExclusive ?? -1) else {
                throw ContextualTranslationError.invalidSelection
            }
            let local = UTF16Span(location: verifiedPhraseGroupSpan.location - context.sourceSpan.location,
                                  length: verifiedPhraseGroupSpan.length)
            guard local.composedCharacterRange(in: context.text) != nil,
                  localSelections == [local] else {
                throw ContextualTranslationError.invalidSelection
            }
            localPhraseGroupSpan = local
        } else {
            localPhraseGroupSpan = nil
        }
        let canonical = SemanticTokenizer.canonicalize(context.text,
                                                       documentSHA256: context.documentSHA256,
                                                       pageIndex: context.pageIndex,
                                                       blockID: context.blockID)
        guard !canonical.tokens.isEmpty else { throw ContextualTranslationError.noTokens }

        let sourceTokens = canonical.tokens.sorted { $0.span.location < $1.span.location }
        var selectedIndices: [Int] = []
        for (index, token) in sourceTokens.enumerated() {
            guard let tokenEnd = token.span.endExclusive else { throw ContextualTranslationError.invalidSelection }
            let intersections = localSelections.filter { $0.intersects(token.span) }
            guard !intersections.isEmpty else { continue }
            let covered = intersections.reduce(0) { partial, span in
                let start = max(span.location, token.span.location)
                let end = min(span.endExclusive ?? start, tokenEnd)
                return partial + max(0, end - start)
            }
            guard covered == token.span.length else { throw ContextualTranslationError.partialTokenSelection }
            selectedIndices.append(index)
        }

        guard let firstSelectedIndex = selectedIndices.first,
              let lastSelectedIndex = selectedIndices.last else {
            throw ContextualTranslationError.invalidSelection
        }
        guard selectedIndices.count == lastSelectedIndex - firstSelectedIndex + 1 else {
            throw ContextualTranslationError.discontiguousSelection
        }
        let selectedIndexSet = Set(selectedIndices)
        let meaningfulTokenIndices = sourceTokens.indices.filter { index in
            switch sourceTokens[index].kind {
            case .punctuation, .combiningMark, .other:
                return false
            case .word, .number, .symbol:
                return true
            }
        }
        guard selectedIndices.count < sourceTokens.count,
              !meaningfulTokenIndices.allSatisfy(selectedIndexSet.contains) else {
            throw ContextualTranslationError.selectionCoversSentence
        }

        let selectedSourceTokens = Array(sourceTokens[firstSelectedIndex...lastSelectedIndex])
        guard let phraseStart = selectedSourceTokens.first?.span.location,
              let phraseEnd = selectedSourceTokens.last?.span.endExclusive,
              phraseEnd > phraseStart else { throw ContextualTranslationError.invalidSelection }
        let phraseSpan = UTF16Span(location: phraseStart, length: phraseEnd - phraseStart)
        guard let selectedPhrase = phraseSpan.substring(in: context.text),
              !selectedPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextualTranslationError.invalidSelection
        }

        let tokens = sourceTokens.enumerated().map { index, token in
            ContextualTranslationToken(id: "token-\(index)-\(token.span.location)-\(token.span.length)",
                                        sourceSpan: token.span,
                                        sourceSurface: token.sourceSurface)
        }
        let phraseGroup: ContextualTranslationPhraseGroup?
        if let localPhraseGroupSpan {
            guard selectedIndices.count >= 2,
                  selectedIndices.allSatisfy({ sourceTokens[$0].kind == .word }),
                  firstSelectedIndex >= 0, firstSelectedIndex < sourceTokens.count,
                  lastSelectedIndex >= 0, lastSelectedIndex < sourceTokens.count else {
                throw ContextualTranslationError.invalidSelection
            }
            let firstToken = sourceTokens[firstSelectedIndex]
            let lastToken = sourceTokens[lastSelectedIndex]
            guard
                  let lastEnd = lastToken.span.endExclusive,
                  firstToken.span.location == localPhraseGroupSpan.location,
                  lastEnd == (localPhraseGroupSpan.endExclusive ?? -1),
                  localPhraseGroupSpan.length > 0,
                  phraseGapsAreWhitespace(sourceTokens: sourceTokens, indices: selectedIndices, in: context.text),
                  let groupSurface = localPhraseGroupSpan.substring(in: context.text) else {
                throw ContextualTranslationError.invalidSelection
            }
            let groupID = "phrase-\(context.sourceSpan.location + localPhraseGroupSpan.location)-\(localPhraseGroupSpan.length)"
            phraseGroup = ContextualTranslationPhraseGroup(id: groupID,
                                                            sourceSpan: localPhraseGroupSpan,
                                                            sourceSurface: groupSurface)
        } else {
            phraseGroup = nil
        }
        let selectedIDs = phraseGroup.map { [$0.id] } ?? selectedIndices.map { tokens[$0].id }
        let selectedPhrase = phraseGroup?.sourceSurface ?? selectedPhrase
        return ContextualTranslationRequest(sentenceText: context.text,
                                            tokens: tokens,
                                            selectedTokenIDs: selectedIDs,
                                            selectedSourceSpans: localSelections,
                                            selectedSourcePhrase: selectedPhrase,
                                            selectedPhraseGroup: phraseGroup)
    }

    func attributedSourceText() throws -> AttributedString {
        var attributed = AttributedString(sentenceText)
        for token in tokens {
            guard let end = token.sourceSpan.endExclusive,
                  token.sourceSpan.composedCharacterRange(in: sentenceText) != nil,
                  let startIndex = attributedIndex(atUTF16Offset: token.sourceSpan.location,
                                                   in: sentenceText,
                                                   attributed: attributed),
                  let endIndex = attributedIndex(atUTF16Offset: end,
                                                 in: sentenceText,
                                                 attributed: attributed) else {
                throw ContextualTranslationError.invalidTokenRange
            }
            attributed[startIndex..<endIndex][ContextualTranslationTokenIDAttribute.self] = token.id
        }
        if let group = selectedPhraseGroup {
            guard let end = group.sourceSpan.endExclusive,
                  group.sourceSpan.composedCharacterRange(in: sentenceText) != nil,
                  let startIndex = attributedIndex(atUTF16Offset: group.sourceSpan.location,
                                                   in: sentenceText,
                                                   attributed: attributed),
                  let endIndex = attributedIndex(atUTF16Offset: end,
                                                 in: sentenceText,
                                                 attributed: attributed) else {
                throw ContextualTranslationError.invalidTokenRange
            }
            attributed[startIndex..<endIndex][ContextualTranslationPhraseGroupIDAttribute.self] = group.id
        }
        return attributed
    }

    private static func phraseGapsAreWhitespace(sourceTokens: [SourceToken],
                                                indices: [Int],
                                                in sourceText: String) -> Bool {
        guard indices.count >= 2 else { return false }
        for pair in zip(indices, indices.dropFirst()) {
            guard let leftEnd = sourceTokens[pair.0].span.endExclusive else { return false }
            let rightStart = sourceTokens[pair.1].span.location
            guard rightStart > leftEnd,
                  let gapText = UTF16Span(location: leftEnd,
                                          length: rightStart - leftEnd).substring(in: sourceText),
                  !gapText.isEmpty,
                  gapText.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                return false
            }
        }
        return true
    }

    private static func localSelectionSpans(in context: SentenceContext) throws -> [UTF16Span] {
        var local: [UTF16Span] = []
        for span in context.selectedSourceSpans {
            guard let end = span.endExclusive,
                  span.length > 0,
                  span.location >= context.sourceSpan.location,
                  end <= (context.sourceSpan.endExclusive ?? -1) else {
                throw ContextualTranslationError.invalidSelection
            }
            let localSpan = UTF16Span(location: span.location - context.sourceSpan.location,
                                      length: span.length)
            guard localSpan.composedCharacterRange(in: context.text) != nil else {
                throw ContextualTranslationError.invalidSelection
            }
            local.append(localSpan)
        }
        local.sort { $0.location < $1.location }
        for index in 1..<local.count where local[index - 1].intersects(local[index]) {
            throw ContextualTranslationError.invalidSelection
        }
        return local
    }
}

/// The ID attribute supports attributed-string serialization. The decoder
/// still validates returned source and target runs before showing any result.
struct ContextualTranslationTokenIDAttribute: CodableAttributedStringKey {
    typealias Value = String
    static let name = "com.pdfvocab.contextual-token-id"
}

struct ContextualTranslationPhraseGroupIDAttribute: CodableAttributedStringKey {
    typealias Value = String
    static let name = "com.pdfvocab.contextual-phrase-group-id"
}

extension AttributeScopes {
    struct PdfVocabContextualTranslationAttributes: AttributeScope {
        let contextualTokenID: ContextualTranslationTokenIDAttribute
        let contextualPhraseGroupID: ContextualTranslationPhraseGroupIDAttribute
    }

    var pdfVocabContextualTranslation: PdfVocabContextualTranslationAttributes.Type {
        PdfVocabContextualTranslationAttributes.self
    }
}

struct ContextualTranslationPayload: Sendable {
    let sourceText: String
    let attributedSourceText: AttributedString?
    let targetText: String
    let attributedTargetText: AttributedString?
}

struct ContextualTranslationCandidate: Equatable, Sendable {
    let sourcePhrase: String
    let translatedPhrase: String
}

enum ContextualTranslationAlignment {
    static func decode(request: ContextualTranslationRequest,
                       payload: ContextualTranslationPayload) throws -> ContextualTranslationCandidate {
        guard payload.sourceText.utf8.elementsEqual(request.sentenceText.utf8),
              let attributedSource = payload.attributedSourceText,
              String(attributedSource.characters).utf8.elementsEqual(request.sentenceText.utf8) else {
            throw ContextualTranslationError.sourceChanged
        }
        guard let attributedTarget = payload.attributedTargetText,
              payload.targetText.utf8.elementsEqual(String(attributedTarget.characters).utf8),
              !payload.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextualTranslationError.targetChanged
        }

        try validateSourceAttributes(attributedSource, request: request)
        let targetRanges = try tokenRanges(in: attributedTarget,
                                           expectedIDs: Set(request.tokens.map(\.id)),
                                           allowMissingIDs: true)
        let expectedGroupIDs = Set(request.selectedPhraseGroup.map { [$0.id] } ?? [])
        let targetGroupRanges = try phraseGroupRanges(in: attributedTarget,
                                                     expectedIDs: expectedGroupIDs,
                                                     allowMissingIDs: true)

        var selectedRanges: [UTF16Span] = []
        if let group = request.selectedPhraseGroup {
            guard let spans = targetGroupRanges[group.id], !spans.isEmpty else {
                throw ContextualTranslationError.selectedPhraseGroupNotAligned
            }
            let merged = try mergeContiguous(spans)
            guard merged.count == 1 else { throw ContextualTranslationError.discontiguousTokenAlignment }
            selectedRanges = merged
        } else {
            for id in request.selectedTokenIDs {
                guard let spans = targetRanges[id], !spans.isEmpty else {
                    throw ContextualTranslationError.selectedTokenNotAligned
                }
                let merged = try mergeContiguous(spans)
                guard merged.count == 1 else { throw ContextualTranslationError.discontiguousTokenAlignment }
                selectedRanges.append(merged[0])
            }
        }
        selectedRanges.sort { $0.location < $1.location }
        guard let first = selectedRanges.first,
              let last = selectedRanges.last,
              let targetEnd = last.endExclusive,
              targetEnd <= (payload.targetText as NSString).length else {
            throw ContextualTranslationError.selectedTokenNotAligned
        }

        var previousEnd = first.location
        for span in selectedRanges {
            guard let end = span.endExclusive, span.location >= previousEnd else {
                throw ContextualTranslationError.overlappingTokenAlignment
            }
            if span.location > previousEnd {
                let gap = UTF16Span(location: previousEnd, length: span.location - previousEnd)
                guard let gapText = gap.substring(in: payload.targetText), isWhitespace(gapText) else {
                    throw ContextualTranslationError.noncontiguousPhraseAlignment
                }
            }
            previousEnd = end
        }

        let targetSpan = UTF16Span(location: first.location, length: targetEnd - first.location)
        guard targetSpan.composedCharacterRange(in: payload.targetText) != nil,
              let translatedPhrase = targetSpan.substring(in: payload.targetText),
              !translatedPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextualTranslationError.invalidTargetRange
        }

        if (request.selectedPhraseGroup != nil || request.selectedTokenIDs.count < request.tokens.count),
           isWholeSentenceTarget(targetSpan, targetText: payload.targetText) {
            throw ContextualTranslationError.translationCoversSentence
        }

        return ContextualTranslationCandidate(sourcePhrase: request.selectedSourcePhrase,
                                              translatedPhrase: translatedPhrase)
    }

    private static func validateSourceAttributes(_ attributed: AttributedString,
                                                 request: ContextualTranslationRequest) throws {
        let expected = Dictionary(uniqueKeysWithValues: request.tokens.map { ($0.id, $0.sourceSpan) })
        let found = try tokenRanges(in: attributed, expectedIDs: Set(expected.keys), allowMissingIDs: false)
        guard found.count == expected.count else { throw ContextualTranslationError.sourceAttributesLost }
        for (id, span) in expected {
            guard let ranges = found[id], try mergeContiguous(ranges) == [span] else {
                throw ContextualTranslationError.sourceAttributesLost
            }
        }
        let expectedGroupIDs = Set(request.selectedPhraseGroup.map { [$0.id] } ?? [])
        let foundGroups = try phraseGroupRanges(in: attributed,
                                                expectedIDs: expectedGroupIDs,
                                                allowMissingIDs: false)
        if let group = request.selectedPhraseGroup {
            guard let expectedSurface = group.sourceSpan.substring(in: request.sentenceText),
                  group.sourceSpan.composedCharacterRange(in: request.sentenceText) != nil,
                  expectedSurface == group.sourceSurface,
                  let ranges = foundGroups[group.id],
                  try mergeContiguous(ranges) == [group.sourceSpan] else {
                throw ContextualTranslationError.sourceAttributesLost
            }
        }
    }

    private static func tokenRanges(in attributed: AttributedString,
                                    expectedIDs: Set<String>,
                                    allowMissingIDs: Bool) throws -> [String: [UTF16Span]] {
        let attributedText = String(attributed.characters)
        var result: [String: [UTF16Span]] = [:]
        for run in attributed.runs {
            guard let id = run[ContextualTranslationTokenIDAttribute.self] else { continue }
            guard expectedIDs.contains(id) else { throw ContextualTranslationError.unknownTokenID }
            guard let lower = String.Index(run.range.lowerBound, within: attributedText),
                  let upper = String.Index(run.range.upperBound, within: attributedText) else {
                throw ContextualTranslationError.invalidTargetRange
            }
            let range = NSRange(lower..<upper, in: attributedText)
            guard let span = UTF16Span(composedRange: range, in: attributedText), span.length > 0 else {
                throw ContextualTranslationError.invalidTargetRange
            }
            result[id, default: []].append(span)
        }
        if !allowMissingIDs && result.count != expectedIDs.count {
            throw ContextualTranslationError.sourceAttributesLost
        }
        return result
    }

    private static func phraseGroupRanges(in attributed: AttributedString,
                                          expectedIDs: Set<String>,
                                          allowMissingIDs: Bool) throws -> [String: [UTF16Span]] {
        let attributedText = String(attributed.characters)
        var result: [String: [UTF16Span]] = [:]
        for run in attributed.runs {
            guard let id = run[ContextualTranslationPhraseGroupIDAttribute.self] else { continue }
            guard expectedIDs.contains(id) else { throw ContextualTranslationError.unknownPhraseGroupID }
            guard let lower = String.Index(run.range.lowerBound, within: attributedText),
                  let upper = String.Index(run.range.upperBound, within: attributedText) else {
                throw ContextualTranslationError.invalidTargetRange
            }
            let range = NSRange(lower..<upper, in: attributedText)
            guard let span = UTF16Span(composedRange: range, in: attributedText), span.length > 0 else {
                throw ContextualTranslationError.invalidTargetRange
            }
            result[id, default: []].append(span)
        }
        if !allowMissingIDs && result.count != expectedIDs.count {
            throw ContextualTranslationError.sourceAttributesLost
        }
        return result
    }

    private static func mergeContiguous(_ spans: [UTF16Span]) throws -> [UTF16Span] {
        let sorted = spans.sorted { $0.location < $1.location }
        var merged: [UTF16Span] = []
        for span in sorted {
            guard let end = span.endExclusive else { throw ContextualTranslationError.invalidTargetRange }
            if let previous = merged.last {
                guard let previousEnd = previous.endExclusive else { throw ContextualTranslationError.invalidTargetRange }
                if span.location < previousEnd { throw ContextualTranslationError.overlappingTokenAlignment }
                if span.location == previousEnd {
                    merged[merged.count - 1] = UTF16Span(location: previous.location,
                                                         length: end - previous.location)
                    continue
                }
            }
            merged.append(span)
        }
        return merged
    }

    private static func isWholeSentenceTarget(_ span: UTF16Span, targetText: String) -> Bool {
        guard let end = span.endExclusive,
              let selected = span.substring(in: targetText),
              let range = span.nsRange(in: targetText) else { return false }
        let target = targetText as NSString
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        if span.location == 0 && end == target.length
            || targetText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
            return true
        }
        let leading = target.substring(to: range.location)
        let trailing = target.substring(from: end)
        return isSentenceEdgeNoise(leading) && isSentenceEdgeNoise(trailing)
    }

    private static func isWhitespace(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func isSentenceEdgeNoise(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.punctuationCharacters.contains($0)
        }
    }
}

enum ContextualTranslationError: Error, Equatable, LocalizedError, Sendable {
    case disabled
    case incompleteSentence
    case emptyInput
    case inputTooLong(maximumUTF16Units: Int)
    case invalidSelection
    case partialTokenSelection
    case discontiguousSelection
    case selectionCoversSentence
    case noTokens
    case invalidTokenRange
    case sourceChanged
    case sourceAttributesLost
    case targetChanged
    case unknownTokenID
    case selectedTokenNotAligned
    case selectedPhraseGroupNotAligned
    case unknownPhraseGroupID
    case discontiguousTokenAlignment
    case overlappingTokenAlignment
    case noncontiguousPhraseAlignment
    case invalidTargetRange
    case translationCoversSentence
    case invalidConfiguration
    case outputTooLong(maximumUTF16Units: Int)
    case staleRequest

    /// Stable, content-free category for diagnostics. Never log localized
    /// descriptions here because translation framework errors may include text.
    var diagnosticCode: String {
        switch self {
        case .disabled: "disabled"
        case .incompleteSentence: "incomplete_sentence"
        case .emptyInput: "empty_input"
        case .inputTooLong: "input_too_long"
        case .invalidSelection: "invalid_selection"
        case .partialTokenSelection: "partial_token"
        case .discontiguousSelection: "discontiguous_selection"
        case .selectionCoversSentence: "selection_covers_sentence"
        case .noTokens: "no_tokens"
        case .invalidTokenRange: "invalid_token_range"
        case .sourceChanged: "source_changed"
        case .sourceAttributesLost: "source_attributes_lost"
        case .targetChanged: "target_changed"
        case .unknownTokenID: "unknown_token_id"
        case .selectedTokenNotAligned: "selected_token_not_aligned"
        case .selectedPhraseGroupNotAligned: "selected_phrase_group_not_aligned"
        case .unknownPhraseGroupID: "unknown_phrase_group_id"
        case .discontiguousTokenAlignment: "discontiguous_token_alignment"
        case .overlappingTokenAlignment: "overlapping_token_alignment"
        case .noncontiguousPhraseAlignment: "noncontiguous_phrase_alignment"
        case .invalidTargetRange: "invalid_target_range"
        case .translationCoversSentence: "translation_covers_sentence"
        case .invalidConfiguration: "invalid_configuration"
        case .outputTooLong: "output_too_long"
        case .staleRequest: "stale_request"
        }
    }

    var errorDescription: String? {
        switch self {
        case .disabled: "语境 Token 阅读已关闭。"
        case .incompleteSentence: "当前片段不是可验证的完整句子。"
        case .emptyInput: "当前句子没有可翻译的文字。"
        case .inputTooLong(let maximum): "句子超过了 \(maximum) 个 UTF-16 单元的上限。"
        case .invalidSelection: "选中范围无法映射到句中 Token。"
        case .partialTokenSelection: "选区只覆盖了 Token 的一部分，无法可靠对齐。"
        case .discontiguousSelection: "选区包含不连续的句中 Token，暂不提供语境候选。"
        case .selectionCoversSentence: "选区覆盖整句，语境卡只显示选中 Token 或短语候选。"
        case .noTokens: "句中没有可对齐的 Token。"
        case .invalidTokenRange: "句中 Token 范围无效，无法请求对齐。"
        case .sourceChanged: "翻译返回的原文与当前句子不一致。"
        case .sourceAttributesLost: "系统未保留足够的原文 Token 标记，未显示语境候选。"
        case .targetChanged: "系统译文与带标记译文不一致。"
        case .unknownTokenID: "系统返回了未知的 Token 标记，未显示语境候选。"
        case .selectedTokenNotAligned: "系统没有为选中的 Token 返回可用对齐。"
        case .selectedPhraseGroupNotAligned: "系统没有为已验证短语返回可用对齐。"
        case .unknownPhraseGroupID: "系统返回了未知的短语组标记，未显示语境候选。"
        case .discontiguousTokenAlignment: "选中 Token 的系统对齐分成了多段。"
        case .overlappingTokenAlignment: "系统返回的 Token 对齐范围发生重叠。"
        case .noncontiguousPhraseAlignment: "短语中的 Token 在译文里无法连续提取。"
        case .invalidTargetRange: "系统译文的 Token 对齐范围无效。"
        case .translationCoversSentence: "系统无法把选中 Token 与整句译文分开。"
        case .invalidConfiguration: "语境翻译语言配置无效。"
        case .outputTooLong(let maximum): "系统译文超过了 \(maximum) 个 UTF-16 单元的上限。"
        case .staleRequest: "选区已变化，旧的语境翻译结果已丢弃。"
        }
    }
}

private func attributedIndex(atUTF16Offset offset: Int,
                             in source: String,
                             attributed: AttributedString) -> AttributedString.Index? {
    guard offset >= 0, offset <= (source as NSString).length else { return nil }
    let stringIndex = String.Index(utf16Offset: offset, in: source)
    return AttributedString.Index(stringIndex, within: attributed)
}
