import Foundation
import XCTest
@testable import PdfVocab

final class ContextualTranslationAlignmentTests: XCTestCase {
    func testDiagnosticCodesDistinguishContentFreeFailureCategories() {
        XCTAssertEqual(ContextualTranslationError.incompleteSentence.diagnosticCode, "incomplete_sentence")
        XCTAssertEqual(ContextualTranslationError.partialTokenSelection.diagnosticCode, "partial_token")
        XCTAssertEqual(ContextualTranslationError.sourceAttributesLost.diagnosticCode, "source_attributes_lost")
        XCTAssertEqual(ContextualTranslationError.inputTooLong(maximumUTF16Units: 99).diagnosticCode,
                       "input_too_long")
    }

    func testRepeatedWordsHaveUniquePositionIDsAndSelectedOccurrenceIsExact() throws {
        let text = "They read read carefully."
        let selected = try XCTUnwrap(span(of: "read", in: text, occurrence: 1))
        let request = try ContextualTranslationRequest.make(from: context(text, selected: [selected]))
        let marked = try request.attributedSourceText()
        let readTokens = request.tokens.filter { $0.sourceSurface == "read" }

        XCTAssertEqual(readTokens.count, 2)
        XCTAssertNotEqual(readTokens[0].id, readTokens[1].id)
        XCTAssertEqual(request.selectedTokenIDs, [readTokens[1].id])

        let marks = marked.runs.compactMap { $0[ContextualTranslationTokenIDAttribute.self] }
        XCTAssertTrue(marks.contains(readTokens[0].id))
        XCTAssertTrue(marks.contains(readTokens[1].id))
    }

    func testComposedCharacterUsesUTF16OffsetsAndCodableScopeRetainsTokenID() throws {
        let text = "Cafe\u{0301} moves forward."
        let selected = UTF16Span(location: 0, length: 5)
        let request = try ContextualTranslationRequest.make(from: context(text, selected: [selected]))
        let token = try XCTUnwrap(request.tokens.first)
        XCTAssertEqual(token.sourceSurface, "Cafe\u{0301}")
        XCTAssertEqual(token.sourceSpan, selected)

        let marked = try request.attributedSourceText()
        let data = try JSONEncoder().encode(
            marked,
            configuration: AttributeScopes.PdfVocabContextualTranslationAttributes.self
        )
        let decoded = try JSONDecoder().decode(
            AttributedString.self,
            from: data,
            configuration: AttributeScopes.PdfVocabContextualTranslationAttributes.self
        )
        XCTAssertEqual(String(decoded.characters).utf8.elementsEqual(text.utf8), true)
        XCTAssertTrue(decoded.runs.contains { $0[ContextualTranslationTokenIDAttribute.self] == token.id })

        let invalidSelection = UTF16Span(location: 0, length: 4)
        XCTAssertThrowsError(try ContextualTranslationRequest.make(from: context(text, selected: [invalidSelection]))) {
            XCTAssertEqual($0 as? ContextualTranslationError, .invalidSelection)
        }
    }

    func testReorderedTargetUsesOnlySelectedTokenRange() throws {
        let text = "I read books daily."
        let selected = try XCTUnwrap(span(of: "read", in: text))
        let request = try ContextualTranslationRequest.make(from: context(text, selected: [selected]))
        let target = "每天阅读书籍"
        let readID = try XCTUnwrap(request.tokens.first { $0.sourceSurface == "read" }?.id)
        let payload = try self.payload(request: request,
                                      target: target,
                                      targetRanges: [readID: UTF16Span(location: 2, length: 2)])

        let candidate = try ContextualTranslationAlignment.decode(request: request, payload: payload)
        XCTAssertEqual(candidate.sourcePhrase, "read")
        XCTAssertEqual(candidate.translatedPhrase, "阅读")
        XCTAssertNotEqual(candidate.sourcePhrase, request.sentenceText)
        XCTAssertNotEqual(candidate.translatedPhrase, target)
    }

    func testSourceAndTargetMustMatchExactUTF8Content() throws {
        let decomposed = "Cafe\u{0301} moves forward."
        let request = try request(text: decomposed, selected: "Cafe\u{0301}")
        let selectedID = try XCTUnwrap(request.selectedTokenIDs.first)
        let source = try request.attributedSourceText()
        let target = "词语"
        let validTarget = try attributed(target,
                                         ranges: [selectedID: UTF16Span(location: 0, length: 2)])

        let canonicallyEquivalentSource = "Café moves forward."
        let changedSourcePayload = ContextualTranslationPayload(sourceText: canonicallyEquivalentSource,
                                                                attributedSourceText: source,
                                                                targetText: target,
                                                                attributedTargetText: validTarget)
        XCTAssertThrowsError(try ContextualTranslationAlignment.decode(request: request,
                                                                        payload: changedSourcePayload)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .sourceChanged)
        }

        let substitutedSourcePayload = ContextualTranslationPayload(sourceText: decomposed,
                                                                    attributedSourceText: AttributedString(canonicallyEquivalentSource),
                                                                    targetText: target,
                                                                    attributedTargetText: validTarget)
        XCTAssertThrowsError(try ContextualTranslationAlignment.decode(request: request,
                                                                        payload: substitutedSourcePayload)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .sourceChanged)
        }

        let changedTargetPayload = ContextualTranslationPayload(sourceText: decomposed,
                                                                attributedSourceText: source,
                                                                targetText: "另一个译文",
                                                                attributedTargetText: validTarget)
        XCTAssertThrowsError(try ContextualTranslationAlignment.decode(request: request,
                                                                        payload: changedTargetPayload)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .targetChanged)
        }
    }

    func testUnknownAndMissingSelectedTokenAttributesAreRejected() throws {
        let request = try request(text: "The reader learns.", selected: "reader")
        let selectedSpan = UTF16Span(location: 0, length: 4)

        let unknownPayload = try payload(request: request,
                                         target: "陌生人学习",
                                         targetRanges: ["unrequested-token": selectedSpan])
        XCTAssertThrowsError(try ContextualTranslationAlignment.decode(request: request, payload: unknownPayload)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .unknownTokenID)
        }

        let missingPayload = try payload(request: request,
                                         target: "读者学习",
                                         targetRanges: [:])
        XCTAssertThrowsError(try ContextualTranslationAlignment.decode(request: request, payload: missingPayload)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .selectedTokenNotAligned)
        }
    }

    func testWholeSentenceAttributionAndUnmarkedTrailingPunctuationAreRejected() throws {
        let text = "The reader learns fast."
        let request = try request(text: text, selected: "reader")
        let selectedID = try XCTUnwrap(request.selectedTokenIDs.first)
        let fullTarget = "读者学得很快。"
        let attributedRange = UTF16Span(location: 0, length: (fullTarget as NSString).length - 1)
        let payload = try self.payload(request: request,
                                       target: fullTarget,
                                       targetRanges: [selectedID: attributedRange])

        XCTAssertThrowsError(try ContextualTranslationAlignment.decode(request: request, payload: payload)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .translationCoversSentence)
        }
    }

    func testDiscontiguousPhraseAlignmentIsRejected() throws {
        let text = "We ate red apple yesterday."
        let red = try XCTUnwrap(span(of: "red", in: text))
        let apple = try XCTUnwrap(span(of: "apple", in: text))
        let phraseSpan = UTF16Span(location: red.location,
                                   length: (apple.endExclusive ?? 0) - red.location)
        let request = try ContextualTranslationRequest.make(from: context(text, selected: [phraseSpan]))
        XCTAssertEqual(request.selectedTokenIDs.count, 2)
        let target = "我们吃了红以及苹果"
        let redID = request.selectedTokenIDs[0]
        let appleID = request.selectedTokenIDs[1]
        let payload = try self.payload(request: request,
                                       target: target,
                                       targetRanges: [redID: UTF16Span(location: 4, length: 1),
                                                      appleID: UTF16Span(location: 7, length: 2)])

        XCTAssertThrowsError(try ContextualTranslationAlignment.decode(request: request, payload: payload)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .noncontiguousPhraseAlignment)
        }
    }

    func testOneTokenIDOnTwoDiscontiguousTargetRunsIsRejected() throws {
        let request = try request(text: "The reader learns.", selected: "reader")
        let selectedID = try XCTUnwrap(request.selectedTokenIDs.first)
        let target = "甲乙丙"
        let attributedSource = try request.attributedSourceText()
        let attributedTarget = try attributed(target,
                                              ranges: [selectedID: [UTF16Span(location: 0, length: 1),
                                                                    UTF16Span(location: 2, length: 1)]])
        let payload = ContextualTranslationPayload(sourceText: request.sentenceText,
                                                   attributedSourceText: attributedSource,
                                                   targetText: target,
                                                   attributedTargetText: attributedTarget)

        XCTAssertThrowsError(try ContextualTranslationAlignment.decode(request: request, payload: payload)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .discontiguousTokenAlignment)
        }
    }

    func testVerifiedPhraseGroupAlignsManySourceWordsToOneTargetRange() throws {
        let request = try phraseGroupRequest(text: "They read books daily.", selected: "read books")
        let group = try XCTUnwrap(request.selectedPhraseGroup)
        XCTAssertEqual(request.tokens.filter { ["read", "books"].contains($0.sourceSurface) }.count, 2)
        XCTAssertEqual(request.selectedTokenIDs, [group.id])
        XCTAssertEqual(request.selectedSourceSpans, [group.sourceSpan])

        let target = "他们读书每天"
        let groupTargetSpan = UTF16Span(location: 2, length: 2)
        let payload = try phrasePayload(request: request,
                                        target: target,
                                        targetGroupSpans: [groupTargetSpan])
        let candidate = try ContextualTranslationAlignment.decode(request: request, payload: payload)

        XCTAssertEqual(candidate.sourcePhrase, "read books")
        XCTAssertEqual(candidate.translatedPhrase, "读书")
    }

    func testVerifiedPhraseGroupRejectsMissingUnknownMovedDisjointAndWholeTargetMarkers() throws {
        let request = try phraseGroupRequest(text: "They read books daily.", selected: "read books")
        let expectedTargetSpan = UTF16Span(location: 1, length: 2)
        let target = "甲读书乙"

        let missingTarget = try phrasePayload(request: request, target: target)
        XCTAssertThrowsError(try ContextualTranslationAlignment.decode(request: request, payload: missingTarget)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .selectedPhraseGroupNotAligned)
        }

        let unknownID = try phrasePayload(request: request,
                                          target: target,
                                          targetGroupSpans: [expectedTargetSpan],
                                          targetGroupID: "unknown-phrase")
        XCTAssertThrowsError(try ContextualTranslationAlignment.decode(request: request, payload: unknownID)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .unknownPhraseGroupID)
        }

        let group = try XCTUnwrap(request.selectedPhraseGroup)
        let movedSource = try phrasePayload(request: request,
                                            target: target,
                                            sourceGroupSpans: [UTF16Span(location: group.sourceSpan.location + 1,
                                                                        length: group.sourceSpan.length)],
                                            targetGroupSpans: [expectedTargetSpan])
        XCTAssertThrowsError(try ContextualTranslationAlignment.decode(request: request, payload: movedSource)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .sourceAttributesLost)
        }

        let disjointTarget = try phrasePayload(request: request,
                                               target: target,
                                               targetGroupSpans: [UTF16Span(location: 1, length: 1),
                                                                  UTF16Span(location: 3, length: 1)])
        XCTAssertThrowsError(try ContextualTranslationAlignment.decode(request: request, payload: disjointTarget)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .discontiguousTokenAlignment)
        }

        let wholeTarget = "读书"
        let wholeTargetMarker = try phrasePayload(request: request,
                                                  target: wholeTarget,
                                                  targetGroupSpans: [UTF16Span(location: 0,
                                                                               length: (wholeTarget as NSString).length)])
        XCTAssertThrowsError(try ContextualTranslationAlignment.decode(request: request, payload: wholeTargetMarker)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .translationCoversSentence)
        }
    }

    func testVerifiedPhraseGroupRejectsMissingSourceMarker() throws {
        let request = try phraseGroupRequest(text: "They read books daily.", selected: "read books")
        let payload = try phrasePayload(request: request,
                                        target: "甲读书乙",
                                        sourceGroupSpans: [],
                                        targetGroupSpans: [UTF16Span(location: 1, length: 2)])
        XCTAssertThrowsError(try ContextualTranslationAlignment.decode(request: request, payload: payload)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .sourceAttributesLost)
        }
    }

    func testRequestRejectsPartialTokenWholeSentenceAndMultilineInput() throws {
        let accented = "Cafe\u{0301} moves forward."
        XCTAssertThrowsError(try ContextualTranslationRequest.make(
            from: context(accented, selected: [UTF16Span(location: 0, length: 4)])
        )) {
            XCTAssertEqual($0 as? ContextualTranslationError, .invalidSelection)
        }

        let completeSelection = context("Two words here.", selected: [UTF16Span(location: 0, length: 15)])
        XCTAssertThrowsError(try ContextualTranslationRequest.make(from: completeSelection)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .selectionCoversSentence)
        }
        let wordsWithoutFinalPunctuation = context("Two words here.", selected: [UTF16Span(location: 0, length: 14)])
        XCTAssertThrowsError(try ContextualTranslationRequest.make(from: wordsWithoutFinalPunctuation)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .selectionCoversSentence)
        }

        XCTAssertThrowsError(try ContextualTranslationRequest.make(
            from: context("First line.\nSecond line.", selected: [UTF16Span(location: 0, length: 5)])
        )) {
            XCTAssertEqual($0 as? ContextualTranslationError, .incompleteSentence)
        }
    }

    func testNonSentenceLayoutBlockBuildsContextualRequestAndFragmentStillFails() throws {
        let text = "The charge of an electron is negative"
        let selected = try XCTUnwrap(span(of: "charge", in: text))
        let layout = layoutBlockContext(rawText: text,
                                        selectedLineSpans: [selected],
                                        seedLineIndex: 0,
                                        seedLineOffset: 0)
        let request = try ContextualTranslationRequest.make(from: layout)
        XCTAssertEqual(request.sentenceText, text)
        XCTAssertEqual(request.selectedSourcePhrase, "charge")
        XCTAssertEqual(request.selectedSourceSpans, [selected])

        let fragment = context(text, selected: [selected], kind: .fragment)
        XCTAssertThrowsError(try ContextualTranslationRequest.make(from: fragment)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .incompleteSentence)
        }
    }

    func testMappedRepeatedWordOnSecondLineUsesMappedOccurrenceOffset() throws {
        let firstLine = "The method"
        let secondLine = "uses method daily"
        let rawText = firstLine + "\n" + secondLine
        let selectedLineSpan = try XCTUnwrap(span(of: "method", in: secondLine))
        let seedOffset = (firstLine as NSString).length + 1
        let context = layoutBlockContext(rawText: rawText,
                                        selectedLineSpans: [selectedLineSpan],
                                        seedLineIndex: 8,
                                        seedLineOffset: seedOffset)

        let request = try ContextualTranslationRequest.make(from: context)
        let mappedSpan = UTF16Span(location: seedOffset + selectedLineSpan.location,
                                   length: selectedLineSpan.length)
        XCTAssertEqual(request.selectedSourceSpans, [mappedSpan])
        XCTAssertEqual(request.tokens.filter { $0.sourceSurface == "method" }.count, 2)
        XCTAssertEqual(request.selectedTokenIDs,
                       [try XCTUnwrap(request.tokens.first { $0.sourceSpan == mappedSpan }?.id)])
    }

    func testCRLFLayoutBlockNormalizesWithoutShiftingMappedSelection() throws {
        let firstLine = "A useful"
        let secondLine = "method carries meaning"
        let rawText = firstLine + "\r\n" + secondLine
        let selected = try XCTUnwrap(span(of: "method", in: secondLine))
        let seedOffset = (firstLine as NSString).length + 2
        let context = layoutBlockContext(rawText: rawText,
                                        selectedLineSpans: [selected],
                                        seedLineIndex: 4,
                                        seedLineOffset: seedOffset)

        let request = try ContextualTranslationRequest.make(from: context)
        XCTAssertEqual(context.text, "A useful  method carries meaning")
        XCTAssertEqual((context.text as NSString).length, (rawText as NSString).length)
        XCTAssertEqual(request.selectedSourceSpans,
                       [UTF16Span(location: seedOffset + selected.location, length: selected.length)])
        XCTAssertEqual(request.selectedSourcePhrase, "method")
    }

    func testVerifiedPhraseGroupMapsLineLocalSpanIntoLayoutBlock() throws {
        let firstLine = "Earlier line"
        let secondLine = "They read books daily"
        let rawText = firstLine + "\n" + secondLine
        let selectedLineSpan = try XCTUnwrap(span(of: "read books", in: secondLine))
        let seedOffset = (firstLine as NSString).length + 1
        let context = layoutBlockContext(rawText: rawText,
                                        selectedLineSpans: [selectedLineSpan],
                                        seedLineIndex: 1,
                                        seedLineOffset: seedOffset)

        let request = try ContextualTranslationRequest.make(from: context,
                                                            verifiedPhraseGroupSpan: selectedLineSpan)
        let mappedSpan = UTF16Span(location: seedOffset + selectedLineSpan.location,
                                   length: selectedLineSpan.length)
        XCTAssertEqual(context.selectedSourceSpans, [selectedLineSpan])
        XCTAssertEqual(request.selectedSourceSpans, [mappedSpan])
        XCTAssertEqual(request.selectedPhraseGroup?.sourceSpan, mappedSpan)
        XCTAssertEqual(request.selectedPhraseGroup?.sourceSurface, "read books")
    }

    func testLayoutBlockRejectsMalformedMappingsAndWholeContextSelection() throws {
        let text = "The red apple remains fresh"
        let red = try XCTUnwrap(span(of: "red", in: text))
        let apple = try XCTUnwrap(span(of: "apple", in: text))
        let normalMaps = [
            SentenceContextSpanMapping(lineIndex: 3, sourceSpan: red, contextSpan: red),
            SentenceContextSpanMapping(lineIndex: 3, sourceSpan: apple, contextSpan: apple)
        ]
        let malformed: [SentenceContext] = [
            layoutBlockContext(rawText: text,
                               selectedLineSpans: [red, apple],
                               seedLineIndex: 3,
                               seedLineOffset: 0,
                               mappings: [normalMaps[0]]),
            layoutBlockContext(rawText: text,
                               selectedLineSpans: [red, apple],
                               seedLineIndex: 3,
                               seedLineOffset: 0,
                               sourceSpan: UTF16Span(location: 1, length: (text as NSString).length)),
            layoutBlockContext(rawText: text,
                               selectedLineSpans: [red, apple],
                               seedLineIndex: 3,
                               seedLineOffset: 0,
                               mappings: [normalMaps[0],
                                          SentenceContextSpanMapping(lineIndex: 4,
                                                                     sourceSpan: apple,
                                                                     contextSpan: apple)]),
            layoutBlockContext(rawText: text,
                               selectedLineSpans: [red, apple],
                               seedLineIndex: 3,
                               seedLineOffset: 0,
                               mappings: [normalMaps[0],
                                          SentenceContextSpanMapping(lineIndex: 3,
                                                                     sourceSpan: apple,
                                                                     contextSpan: UTF16Span(location: red.location + 1,
                                                                                            length: apple.length))]),
            layoutBlockContext(rawText: text,
                               selectedLineSpans: [red, apple],
                               seedLineIndex: 3,
                               seedLineOffset: 0,
                               mappings: [normalMaps[0], normalMaps[0]]),
            layoutBlockContext(rawText: text,
                               selectedLineSpans: [red, red],
                               seedLineIndex: 3,
                               seedLineOffset: 0,
                               mappings: [normalMaps[0],
                                          SentenceContextSpanMapping(lineIndex: 3,
                                                                     sourceSpan: red,
                                                                     contextSpan: apple)]),
            layoutBlockContext(rawText: text,
                               selectedLineSpans: [red, apple],
                               seedLineIndex: 3,
                               seedLineOffset: 0,
                               mappings: [SentenceContextSpanMapping(lineIndex: 3,
                                                                     sourceSpan: red,
                                                                     contextSpan: apple),
                                          SentenceContextSpanMapping(lineIndex: 3,
                                                                     sourceSpan: apple,
                                                                     contextSpan: red)]),
            layoutBlockContext(rawText: text,
                               selectedLineSpans: [red, apple],
                               seedLineIndex: 3,
                               seedLineOffset: 0,
                               mappings: [normalMaps[0],
                                          SentenceContextSpanMapping(lineIndex: 3,
                                                                     sourceSpan: apple,
                                                                     contextSpan: UTF16Span(location: apple.location,
                                                                                            length: apple.length - 1))]),
            layoutBlockContext(rawText: text,
                               selectedLineSpans: [red, apple],
                               seedLineIndex: 3,
                               seedLineOffset: 0,
                               mappings: normalMaps,
                               selectedDisplaySpans: [red,
                                                      UTF16Span(location: apple.location + 1,
                                                                length: apple.length)])
        ]
        for context in malformed {
            XCTAssertThrowsError(try ContextualTranslationRequest.make(from: context)) {
                XCTAssertEqual($0 as? ContextualTranslationError, .invalidSelection)
            }
        }

        let wholeText = "Charge levels change slowly"
        let allWords = SemanticTokenizer.canonicalize(wholeText,
                                                       documentSHA256: "layout-whole-context",
                                                       pageIndex: 0,
                                                       blockID: "layout-whole-context")
            .tokens.filter { $0.kind == .word }.map(\.span)
        let wholeContext = layoutBlockContext(rawText: wholeText,
                                             selectedLineSpans: allWords,
                                             seedLineIndex: 0,
                                             seedLineOffset: 0)
        XCTAssertThrowsError(try ContextualTranslationRequest.make(from: wholeContext)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .selectionCoversSentence)
        }

        let onlyNonWordContext = "7 + read"
        let read = try XCTUnwrap(span(of: "read", in: onlyNonWordContext))
        let onlyNonWord = layoutBlockContext(rawText: onlyNonWordContext,
                                             selectedLineSpans: [read],
                                             seedLineIndex: 0,
                                             seedLineOffset: 0)
        XCTAssertThrowsError(try ContextualTranslationRequest.make(from: onlyNonWord)) {
            XCTAssertEqual($0 as? ContextualTranslationError, .selectionCoversSentence)
        }
    }

    func testNativeLayoutBlockWithoutMappingsKeepsPageGlobalOffsets() throws {
        let text = "The charge of an electron is negative"
        let local = try XCTUnwrap(span(of: "charge", in: text))
        let nativeLayoutBlock = context(text,
                                       selected: [local],
                                       kind: .layoutBlock)
        let request = try ContextualTranslationRequest.make(from: nativeLayoutBlock)
        XCTAssertEqual(request.selectedSourceSpans, [local])
        XCTAssertEqual(request.selectedSourcePhrase, "charge")
    }

    private func request(text: String, selected surface: String) throws -> ContextualTranslationRequest {
        let selected = try XCTUnwrap(span(of: surface, in: text))
        return try ContextualTranslationRequest.make(from: context(text, selected: [selected]))
    }

    private func payload(request: ContextualTranslationRequest,
                         target: String,
                         targetRanges: [String: UTF16Span]) throws -> ContextualTranslationPayload {
        let source = try request.attributedSourceText()
        let attributedTarget = try attributed(target, ranges: targetRanges)
        return ContextualTranslationPayload(sourceText: request.sentenceText,
                                            attributedSourceText: source,
                                            targetText: target,
                                            attributedTargetText: attributedTarget)
    }

    private func phrasePayload(request: ContextualTranslationRequest,
                               target: String,
                               sourceGroupSpans: [UTF16Span]? = nil,
                               targetGroupSpans: [UTF16Span] = [],
                               targetGroupID: String? = nil) throws -> ContextualTranslationPayload {
        let group = try XCTUnwrap(request.selectedPhraseGroup)
        let sourceTokenRanges = Dictionary(uniqueKeysWithValues: request.tokens.map { ($0.id, [$0.sourceSpan]) })
        let sourceGroupRanges = [group.id: sourceGroupSpans ?? [group.sourceSpan]]
        let source = try attributed(request.sentenceText,
                                    ranges: sourceTokenRanges,
                                    phraseGroupRanges: sourceGroupRanges)
        let targetGroupRanges = [targetGroupID ?? group.id: targetGroupSpans]
        let attributedTarget = try attributed(target,
                                              ranges: [:],
                                              phraseGroupRanges: targetGroupRanges)
        return ContextualTranslationPayload(sourceText: request.sentenceText,
                                            attributedSourceText: source,
                                            targetText: target,
                                            attributedTargetText: attributedTarget)
    }

    private func phraseGroupRequest(text: String, selected surface: String) throws -> ContextualTranslationRequest {
        let local = try XCTUnwrap(span(of: surface, in: text))
        let selectedContext = context(text, selected: [local])
        let global = UTF16Span(location: selectedContext.sourceSpan.location + local.location,
                               length: local.length)
        return try ContextualTranslationRequest.make(from: selectedContext,
                                                     verifiedPhraseGroupSpan: global)
    }

    private func attributed(_ text: String,
                           ranges: [String: UTF16Span]) throws -> AttributedString {
        try attributed(text, ranges: ranges.mapValues { [$0] })
    }

    private func attributed(_ text: String,
                           ranges: [String: [UTF16Span]],
                           phraseGroupRanges: [String: [UTF16Span]] = [:]) throws -> AttributedString {
        var result = AttributedString(text)
        for (id, spans) in ranges {
            for span in spans {
                guard let end = span.endExclusive else { throw ContextualTranslationError.invalidTargetRange }
                let lowerStringIndex = String.Index(utf16Offset: span.location, in: text)
                let upperStringIndex = String.Index(utf16Offset: end, in: text)
                guard let lower = AttributedString.Index(lowerStringIndex, within: result),
                      let upper = AttributedString.Index(upperStringIndex, within: result),
                      span.composedCharacterRange(in: text) != nil else {
                    throw ContextualTranslationError.invalidTargetRange
                }
                result[lower..<upper][ContextualTranslationTokenIDAttribute.self] = id
            }
        }
        for (id, spans) in phraseGroupRanges {
            for span in spans {
                guard let end = span.endExclusive else { throw ContextualTranslationError.invalidTargetRange }
                let lowerStringIndex = String.Index(utf16Offset: span.location, in: text)
                let upperStringIndex = String.Index(utf16Offset: end, in: text)
                guard let lower = AttributedString.Index(lowerStringIndex, within: result),
                      let upper = AttributedString.Index(upperStringIndex, within: result),
                      span.composedCharacterRange(in: text) != nil else {
                    throw ContextualTranslationError.invalidTargetRange
                }
                result[lower..<upper][ContextualTranslationPhraseGroupIDAttribute.self] = id
            }
        }
        return result
    }

    private func layoutBlockContext(rawText: String,
                                    selectedLineSpans: [UTF16Span],
                                    seedLineIndex: Int,
                                    seedLineOffset: Int,
                                    mappings: [SentenceContextSpanMapping]? = nil,
                                    selectedDisplaySpans: [UTF16Span]? = nil,
                                    sourceSpan: UTF16Span? = nil) -> SentenceContext {
        let text = LayoutBlockContextBuilder.replacingLineBreaksPreservingUTF16(in: rawText)
        let length = (text as NSString).length
        let defaultMappings = selectedLineSpans.map { span in
            SentenceContextSpanMapping(lineIndex: seedLineIndex,
                                       sourceSpan: span,
                                       contextSpan: UTF16Span(location: seedLineOffset + span.location,
                                                             length: span.length))
        }
        let resolvedMappings = mappings ?? defaultMappings
        let displaySpans = selectedDisplaySpans ?? resolvedMappings.map(\.contextSpan)
        return SentenceContext(documentSHA256: "layout-fixture-document",
                               pageIndex: 0,
                               blockID: "layout-fixture-block",
                               text: text,
                               displayLineText: text,
                               displaySentenceText: text,
                               sourceSpan: sourceSpan ?? UTF16Span(location: 0, length: length),
                               displaySpan: UTF16Span(location: 0, length: length),
                               selectedSourceSpans: selectedLineSpans,
                               selectedDisplaySpans: displaySpans,
                               kind: .layoutBlock,
                               sourceSpanMappings: resolvedMappings)
    }

    private func context(_ text: String,
                         selected localSpans: [UTF16Span],
                         kind: SentenceContextKind = .completeSentence) -> SentenceContext {
        let origin = 100
        let length = (text as NSString).length
        return SentenceContext(documentSHA256: "fixture-document",
                               pageIndex: 0,
                               blockID: "fixture-block",
                               text: text,
                               displayLineText: text,
                               displaySentenceText: text,
                               sourceSpan: UTF16Span(location: origin, length: length),
                               displaySpan: UTF16Span(location: 0, length: length),
                               selectedSourceSpans: localSpans.map {
                                   UTF16Span(location: origin + $0.location, length: $0.length)
                               },
                               selectedDisplaySpans: localSpans,
                               kind: kind)
    }

    private func span(of surface: String, in text: String, occurrence: Int = 0) -> UTF16Span? {
        let source = text as NSString
        var searchLocation = 0
        for index in 0...occurrence {
            guard searchLocation <= source.length else { return nil }
            let found = source.range(of: surface,
                                     options: [],
                                     range: NSRange(location: searchLocation,
                                                    length: source.length - searchLocation))
            guard found.location != NSNotFound else { return nil }
            searchLocation = NSMaxRange(found)
            if searchLocation == 0 { return nil }
            if index == occurrence { return UTF16Span(location: found.location, length: found.length) }
        }
        return nil
    }
}

final class ContextualTranslationServiceTests: XCTestCase {
    func testDefaultOffPreventsTranslationAndCacheSeparatesSelectionAndBackend() async throws {
        let suite = "ContextualTranslationServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ContextualTranslationService(isEnabled: {
            guard let defaults = UserDefaults(suiteName: suite) else { return false }
            return FeatureFlags.contextReadingEnabled(in: defaults)
        })
        let calls = ContextualTranslationCallRecorder()
        let text = "They read books daily."
        let first = try makeRequest(text: text, selected: "read")
        let second = try makeRequest(text: text, selected: "books")
        let translator = fakeTranslator(calls: calls)

        do {
            _ = try await service.translate(first,
                                            sourceLanguageIdentifier: "en",
                                            targetLanguageIdentifier: "zh-Hans",
                                            backendVersion: "test-v1",
                                            using: translator)
            XCTFail("The default-off context switch must block translation")
        } catch let error as ContextualTranslationError {
            XCTAssertEqual(error, .disabled)
        }
        let disabledCallCount = await calls.count
        XCTAssertEqual(disabledCallCount, 0)

        defaults.set(true, forKey: FeatureFlags.contextReadingEnabledKey)
        _ = try await service.translate(first,
                                       sourceLanguageIdentifier: "en",
                                       targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v1",
                                       using: translator)
        _ = try await service.translate(first,
                                       sourceLanguageIdentifier: "en",
                                       targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v1",
                                       using: translator)
        _ = try await service.translate(second,
                                       sourceLanguageIdentifier: "en",
                                       targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v1",
                                       using: translator)
        _ = try await service.translate(first,
                                       sourceLanguageIdentifier: "en",
                                       targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v2",
                                       using: translator)
        let enabledCallCount = await calls.count
        let cachedEntryCount = await service.cachedEntryCount
        let cachedPayloadCount = await service.cachedPayloadEntryCount
        XCTAssertEqual(enabledCallCount, 2)
        XCTAssertEqual(cachedEntryCount, 3)
        XCTAssertEqual(cachedPayloadCount, 2)
    }

    func testWholeBlockPayloadCacheExtractsEachSelectedWordOnce() async throws {
        let service = ContextualTranslationService(maximumCachedEntries: 4, isEnabled: { true })
        let calls = ContextualTranslationCallRecorder()
        let text = "They read books daily."
        let read = try makeRequest(text: text, selected: "read")
        let books = try makeRequest(text: text, selected: "books")
        let translator: ContextualTranslationService.Translator = { request, source, _, _ in
            await calls.record()
            return try makeWholeBlockPayload(request: request, source: source)
        }

        let readResult = try await service.translate(read,
                                                     sourceLanguageIdentifier: "en",
                                                     targetLanguageIdentifier: "zh-Hans",
                                                     backendVersion: "test-v1",
                                                     using: translator)
        let booksResult = try await service.translate(books,
                                                      sourceLanguageIdentifier: "en",
                                                      targetLanguageIdentifier: "zh-Hans",
                                                      backendVersion: "test-v1",
                                                      using: translator)
        let callCount = await calls.count
        let candidateCount = await service.cachedEntryCount
        let payloadCount = await service.cachedPayloadEntryCount
        XCTAssertEqual(readResult.sourcePhrase, "read")
        XCTAssertEqual(readResult.translatedPhrase, "读")
        XCTAssertEqual(booksResult.sourcePhrase, "books")
        XCTAssertEqual(booksResult.translatedPhrase, "书")
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(candidateCount, 2)
        XCTAssertEqual(payloadCount, 1)
    }

    func testPayloadCacheSeparatesGroupSourceLanguageAndBackend() async throws {
        let service = ContextualTranslationService(maximumCachedEntries: 8, isEnabled: { true })
        let calls = ContextualTranslationCallRecorder()
        let text = "They read books daily."
        let read = try makeRequest(text: text, selected: "read")
        let books = try makeRequest(text: text, selected: "books")
        let phrase = try makePhraseRequest(text: text, selected: "read books")
        let otherSource = try makeRequest(text: "They read passages daily.", selected: "read")
        let translator: ContextualTranslationService.Translator = { request, source, _, _ in
            await calls.record()
            return try makeAllTokenMarkedPayload(request: request, source: source)
        }

        _ = try await service.translate(read, sourceLanguageIdentifier: "en", targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v1", using: translator)
        _ = try await service.translate(books, sourceLanguageIdentifier: "en", targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v1", using: translator)
        _ = try await service.translate(read, sourceLanguageIdentifier: "fr", targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v1", using: translator)
        _ = try await service.translate(read, sourceLanguageIdentifier: "en", targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v2", using: translator)
        _ = try await service.translate(otherSource, sourceLanguageIdentifier: "en", targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v1", using: translator)
        _ = try await service.translate(phrase, sourceLanguageIdentifier: "en", targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v1", using: translator)

        let callCount = await calls.count
        XCTAssertEqual(callCount, 5,
                       "Different source, language, backend, and verified phrase-group payloads must not share")
    }

    func testInvalidCachedPayloadFallsBackToTranslatorForUnmarkedSelection() async throws {
        let service = ContextualTranslationService(maximumCachedEntries: 4, isEnabled: { true })
        let calls = ContextualTranslationCallRecorder()
        let text = "They read books daily."
        let read = try makeRequest(text: text, selected: "read")
        let books = try makeRequest(text: text, selected: "books")
        let translator: ContextualTranslationService.Translator = { request, source, _, _ in
            await calls.record()
            return try makeSelectedTokenPayload(request: request, source: source)
        }

        let readResult = try await service.translate(read, sourceLanguageIdentifier: "en", targetLanguageIdentifier: "zh-Hans",
                                                     backendVersion: "test-v1", using: translator)
        let booksResult = try await service.translate(books, sourceLanguageIdentifier: "en", targetLanguageIdentifier: "zh-Hans",
                                                      backendVersion: "test-v1", using: translator)
        let callCount = await calls.count
        XCTAssertEqual(readResult.translatedPhrase, "读")
        XCTAssertEqual(booksResult.sourcePhrase, "books")
        XCTAssertEqual(booksResult.translatedPhrase, "书")
        XCTAssertEqual(callCount, 2)
    }

    func testFailuresAndCancellationAreNotCached() async throws {
        let service = ContextualTranslationService(maximumCachedEntries: 4, isEnabled: { true })
        let request = try makeRequest(text: "A reader learns quickly.", selected: "reader")
        let calls = ContextualTranslationCallRecorder()
        let failing: ContextualTranslationService.Translator = { _, _, _, _ in
            await calls.record()
            throw TestTranslationFailure.failed
        }
        for _ in 0..<2 {
            do {
                _ = try await service.translate(request,
                                               sourceLanguageIdentifier: "en",
                                               targetLanguageIdentifier: "zh-Hans",
                                               backendVersion: "test-v1",
                                               using: failing)
                XCTFail("Expected translation failure")
            } catch TestTranslationFailure.failed {
                // Failure is intentionally retried below to verify no cache entry was written.
            }
        }
        let failedCallCount = await calls.count
        let failedCacheCount = await service.cachedEntryCount
        let failedPayloadCount = await service.cachedPayloadEntryCount
        XCTAssertEqual(failedCallCount, 2)
        XCTAssertEqual(failedCacheCount, 0)
        XCTAssertEqual(failedPayloadCount, 0)

        let started = ContextualTranslationCallRecorder()
        let sleeping: ContextualTranslationService.Translator = { request, _, _, _ in
            await started.record()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return try makeFakePayload(request: request)
        }
        let task = Task {
            try await service.translate(request,
                                       sourceLanguageIdentifier: "en",
                                       targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v1",
                                       using: sleeping)
        }
        await started.waitForCount(1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: the canceled result is not cached.
        }
        let canceledCacheCount = await service.cachedEntryCount
        let canceledPayloadCount = await service.cachedPayloadEntryCount
        XCTAssertEqual(canceledCacheCount, 0)
        XCTAssertEqual(canceledPayloadCount, 0)
    }

    func testInvalidatedOlderRequestCannotPopulateCache() async throws {
        let service = ContextualTranslationService(maximumCachedEntries: 4, isEnabled: { true })
        let request = try makeRequest(text: "A reader learns quickly.", selected: "reader")
        let gate = ContextualTranslationPayloadGate()
        let translator: ContextualTranslationService.Translator = { request, _, _, _ in
            try await gate.wait()
        }
        let task = Task {
            try await service.translate(request,
                                       sourceLanguageIdentifier: "en",
                                       targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v1",
                                       using: translator)
        }
        await gate.waitUntilStarted()
        await service.invalidatePendingRequests()
        await gate.resume(try makeFakePayload(request: request))

        do {
            _ = try await task.value
            XCTFail("Expected the invalidated result to be rejected")
        } catch let error as ContextualTranslationError {
            XCTAssertEqual(error, .staleRequest)
        }
        let cachedCount = await service.cachedEntryCount
        let cachedPayloadCount = await service.cachedPayloadEntryCount
        XCTAssertEqual(cachedCount, 0)
        XCTAssertEqual(cachedPayloadCount, 0)
    }

    func testClearCacheDuringTranslationDoesNotRepopulateCandidateOrPayloadCache() async throws {
        let service = ContextualTranslationService(maximumCachedEntries: 4, isEnabled: { true })
        let request = try makeRequest(text: "A reader learns quickly.", selected: "reader")
        let gate = ContextualTranslationPayloadGate()
        let pendingTranslator: ContextualTranslationService.Translator = { request, _, _, _ in
            try await gate.wait()
        }
        let pending = Task {
            try await service.translate(request,
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "test-v1",
                                        using: pendingTranslator)
        }
        await gate.waitUntilStarted()
        await service.clearCache()
        await gate.resume(try makeFakePayload(request: request))
        _ = try await pending.value
        let candidateCountAfterClear = await service.cachedEntryCount
        let payloadCountAfterClear = await service.cachedPayloadEntryCount
        XCTAssertEqual(candidateCountAfterClear, 0)
        XCTAssertEqual(payloadCountAfterClear, 0)

        let retryCalls = ContextualTranslationCallRecorder()
        _ = try await service.translate(request,
                                       sourceLanguageIdentifier: "en",
                                       targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v1",
                                       using: fakeTranslator(calls: retryCalls))
        let retryCallCount = await retryCalls.count
        XCTAssertEqual(retryCallCount, 1,"The in-flight payload must not survive clearCache")
    }

    func testCacheRemainsBounded() async throws {
        let service = ContextualTranslationService(maximumCachedEntries: 2, isEnabled: { true })
        let calls = ContextualTranslationCallRecorder()
        let translator = fakeTranslator(calls: calls)
        let requests = try [
            makeRequest(text: "A cat runs quickly.", selected: "cat"),
            makeRequest(text: "A dog sleeps quietly.", selected: "dog"),
            makeRequest(text: "A bird flies swiftly.", selected: "bird")
        ]

        for request in requests {
            _ = try await service.translate(request,
                                            sourceLanguageIdentifier: "en",
                                            targetLanguageIdentifier: "zh-Hans",
                                            backendVersion: "test-v1",
                                            using: translator)
        }
        let callCount = await calls.count
        let cachedCount = await service.cachedEntryCount
        let cachedPayloadCount = await service.cachedPayloadEntryCount
        XCTAssertEqual(callCount, 3)
        XCTAssertEqual(cachedCount, 2)
        XCTAssertEqual(cachedPayloadCount, 2)

        _ = try await service.translate(requests[0],
                                       sourceLanguageIdentifier: "en",
                                       targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v1",
                                       using: translator)
        let callCountAfterEvictedRead = await calls.count
        XCTAssertEqual(callCountAfterEvictedRead, 4, "The first result should have been evicted by the third insertion")
    }

    func testPayloadLRUIsCappedAtEightAndZeroCapacityDisablesReuse() async throws {
        let bounded = ContextualTranslationService(maximumCachedEntries: 12, isEnabled: { true })
        let boundedCalls = ContextualTranslationCallRecorder()
        let nouns = ["cat", "dog", "bird", "book", "reader", "teacher", "method", "charge", "light"]
        for noun in nouns {
            let text = "A \(noun) moves daily."
            let request = try makeRequest(text: text, selected: noun)
            _ = try await bounded.translate(request,
                                            sourceLanguageIdentifier: "en",
                                            targetLanguageIdentifier: "zh-Hans",
                                            backendVersion: "test-v1",
                                            using: { request, source, _, _ in
                                                await boundedCalls.record()
                                                return try makeAllTokenMarkedPayload(request: request, source: source)
                                            })
        }
        let boundedPayloadCount = await bounded.cachedPayloadEntryCount
        XCTAssertEqual(boundedPayloadCount, 8)

        let disabled = ContextualTranslationService(maximumCachedEntries: 0, isEnabled: { true })
        let disabledCalls = ContextualTranslationCallRecorder()
        let text = "They read books daily."
        let read = try makeRequest(text: text, selected: "read")
        let books = try makeRequest(text: text, selected: "books")
        let translator: ContextualTranslationService.Translator = { request, source, _, _ in
            await disabledCalls.record()
            return try makeWholeBlockPayload(request: request, source: source)
        }
        _ = try await disabled.translate(read, sourceLanguageIdentifier: "en", targetLanguageIdentifier: "zh-Hans",
                                         backendVersion: "test-v1", using: translator)
        _ = try await disabled.translate(books, sourceLanguageIdentifier: "en", targetLanguageIdentifier: "zh-Hans",
                                         backendVersion: "test-v1", using: translator)
        let disabledCallCount = await disabledCalls.count
        let disabledCandidateCount = await disabled.cachedEntryCount
        let disabledPayloadCount = await disabled.cachedPayloadEntryCount
        XCTAssertEqual(disabledCallCount, 2)
        XCTAssertEqual(disabledCandidateCount, 0)
        XCTAssertEqual(disabledPayloadCount, 0)
    }

    func testRepeatedWordOccurrencesUseSeparateCacheEntries() async throws {
        let service = ContextualTranslationService(maximumCachedEntries: 4, isEnabled: { true })
        let calls = ContextualTranslationCallRecorder()
        let text = "They read books, then read again."
        let first = try makeRequest(text: text, selected: "read", occurrence: 0)
        let second = try makeRequest(text: text, selected: "read", occurrence: 1)
        let translator: ContextualTranslationService.Translator = { request, _, _, _ in
            await calls.record()
            let translation = request.selectedSourceSpans[0].location == first.selectedSourceSpans[0].location
                ? "义" : "读"
            return try makeFakePayload(request: request, translation: translation)
        }

        let firstResult = try await service.translate(first,
                                                     sourceLanguageIdentifier: "en",
                                                     targetLanguageIdentifier: "zh-Hans",
                                                     backendVersion: "test-v1",
                                                     using: translator)
        let secondResult = try await service.translate(second,
                                                      sourceLanguageIdentifier: "en",
                                                      targetLanguageIdentifier: "zh-Hans",
                                                      backendVersion: "test-v1",
                                                      using: translator)
        _ = try await service.translate(first,
                                       sourceLanguageIdentifier: "en",
                                       targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v1",
                                       using: translator)
        _ = try await service.translate(second,
                                       sourceLanguageIdentifier: "en",
                                       targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v1",
                                       using: translator)
        let callCount = await calls.count
        XCTAssertEqual(firstResult.translatedPhrase, "义")
        XCTAssertEqual(secondResult.translatedPhrase, "读")
        XCTAssertEqual(callCount, 2)
    }

    func testPhraseGroupAndWordSelectionWithSameSpanUseSeparateCacheEntries() async throws {
        let service = ContextualTranslationService(maximumCachedEntries: 4, isEnabled: { true })
        let calls = ContextualTranslationCallRecorder()
        let text = "They read books daily."
        let localRange = (text as NSString).range(of: "read books")
        let selectedSpan = try XCTUnwrap(UTF16Span(range: localRange, in: text))
        let sourceLength = (text as NSString).length
        let context = SentenceContext(documentSHA256: "phrase-cache-fixture",
                                      pageIndex: 0,
                                      blockID: "phrase-cache-block",
                                      text: text,
                                      displayLineText: text,
                                      displaySentenceText: text,
                                      sourceSpan: UTF16Span(location: 0, length: sourceLength),
                                      displaySpan: UTF16Span(location: 0, length: sourceLength),
                                      selectedSourceSpans: [selectedSpan],
                                      selectedDisplaySpans: [selectedSpan],
                                      kind: .completeSentence)
        let words = try ContextualTranslationRequest.make(from: context)
        let group = try ContextualTranslationRequest.make(from: context,
                                                          verifiedPhraseGroupSpan: selectedSpan)
        XCTAssertEqual(words.selectedSourceSpans, group.selectedSourceSpans)
        XCTAssertEqual(words.selectedSourcePhrase, group.selectedSourcePhrase)
        XCTAssertNil(words.selectedPhraseGroup)
        XCTAssertNotNil(group.selectedPhraseGroup)

        let translator: ContextualTranslationService.Translator = { request, source, _, _ in
            await calls.record()
            return try makePhraseModePayload(request: request, source: source)
        }
        let wordResult = try await service.translate(words,
                                                    sourceLanguageIdentifier: "en",
                                                    targetLanguageIdentifier: "zh-Hans",
                                                    backendVersion: "test-v2",
                                                    using: translator)
        let groupResult = try await service.translate(group,
                                                     sourceLanguageIdentifier: "en",
                                                     targetLanguageIdentifier: "zh-Hans",
                                                     backendVersion: "test-v2",
                                                     using: translator)
        _ = try await service.translate(words,
                                       sourceLanguageIdentifier: "en",
                                       targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v2",
                                       using: translator)
        _ = try await service.translate(group,
                                       sourceLanguageIdentifier: "en",
                                       targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v2",
                                       using: translator)

        let callCount = await calls.count
        let cacheCount = await service.cachedEntryCount
        XCTAssertEqual(wordResult.translatedPhrase, "读书")
        XCTAssertEqual(groupResult.translatedPhrase, "读书")
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(cacheCount, 2)
    }

    private func fakeTranslator(calls: ContextualTranslationCallRecorder) -> ContextualTranslationService.Translator {
        { request, _, _, _ in
            await calls.record()
            return try makeFakePayload(request: request)
        }
    }
}

private enum TestTranslationFailure: Error {
    case failed
}

private actor ContextualTranslationCallRecorder {
    private(set) var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func record() {
        count += 1
        let ready = waiters.filter { count >= $0.0 }
        waiters.removeAll { count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func waitForCount(_ expected: Int) async {
        guard count < expected else { return }
        await withCheckedContinuation { continuation in
            waiters.append((expected, continuation))
        }
    }
}

private actor ContextualTranslationPayloadGate {
    private var continuation: CheckedContinuation<ContextualTranslationPayload, Error>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async throws -> ContextualTranslationPayload {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume(_ payload: ContextualTranslationPayload) {
        continuation?.resume(returning: payload)
        continuation = nil
    }
}

private func makeRequest(text: String, selected: String, occurrence: Int = 0) throws -> ContextualTranslationRequest {
    let source = text as NSString
    var location = 0
    var range = NSRange(location: NSNotFound, length: 0)
    for _ in 0...occurrence {
        guard location <= source.length else { throw ContextualTranslationError.invalidSelection }
        range = source.range(of: selected,
                             options: [],
                             range: NSRange(location: location, length: source.length - location))
        guard range.location != NSNotFound else { throw ContextualTranslationError.invalidSelection }
        location = NSMaxRange(range)
    }
    let span = UTF16Span(location: range.location, length: range.length)
    let length = source.length
    let context = SentenceContext(documentSHA256: "service-fixture",
                                  pageIndex: 0,
                                  blockID: "service-block",
                                  text: text,
                                  displayLineText: text,
                                  displaySentenceText: text,
                                  sourceSpan: UTF16Span(location: 0, length: length),
                                  displaySpan: UTF16Span(location: 0, length: length),
                                  selectedSourceSpans: [span],
                                  selectedDisplaySpans: [span],
                                  kind: .completeSentence)
    return try ContextualTranslationRequest.make(from: context)
}

private func makePhraseRequest(text: String, selected: String) throws -> ContextualTranslationRequest {
    let source = text as NSString
    let range = source.range(of: selected)
    guard range.location != NSNotFound,
          let span = UTF16Span(range: range, in: text) else {
        throw ContextualTranslationError.invalidSelection
    }
    let length = source.length
    let context = SentenceContext(documentSHA256: "service-fixture",
                                  pageIndex: 0,
                                  blockID: "service-block",
                                  text: text,
                                  displayLineText: text,
                                  displaySentenceText: text,
                                  sourceSpan: UTF16Span(location: 0, length: length),
                                  displaySpan: UTF16Span(location: 0, length: length),
                                  selectedSourceSpans: [span],
                                  selectedDisplaySpans: [span],
                                  kind: .completeSentence)
    return try ContextualTranslationRequest.make(from: context, verifiedPhraseGroupSpan: span)
}

private func makeWholeBlockPayload(request: ContextualTranslationRequest,
                                   source: AttributedString) throws -> ContextualTranslationPayload {
    let target = "他们读书每天"
    let spans: [String: UTF16Span] = [
        "they": UTF16Span(location: 0, length: 2),
        "read": UTF16Span(location: 2, length: 1),
        "books": UTF16Span(location: 3, length: 1),
        "daily": UTF16Span(location: 4, length: 2)
    ]
    var attributedTarget = AttributedString(target)
    for token in request.tokens {
        guard let span = spans[token.sourceSurface.lowercased()] else { continue }
        try applyToken(token.id, span: span, to: &attributedTarget, source: target)
    }
    return ContextualTranslationPayload(sourceText: request.sentenceText,
                                        attributedSourceText: source,
                                        targetText: target,
                                        attributedTargetText: attributedTarget)
}

private func makeAllTokenMarkedPayload(request: ContextualTranslationRequest,
                                       source: AttributedString) throws -> ContextualTranslationPayload {
    let glyphs = Array("甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥")
    guard request.tokens.count <= glyphs.count else { throw ContextualTranslationError.invalidTargetRange }
    let body = String(glyphs.prefix(request.tokens.count))
    let target = "甲\(body)乙"
    var attributedTarget = AttributedString(target)
    for (index, token) in request.tokens.enumerated() {
        try applyToken(token.id,
                       span: UTF16Span(location: 1 + index, length: 1),
                       to: &attributedTarget,
                       source: target)
    }
    if let group = request.selectedPhraseGroup {
        let selectedIndices = request.tokens.indices.filter {
            request.tokens[$0].sourceSpan.intersects(group.sourceSpan)
        }
        guard let first = selectedIndices.first, let last = selectedIndices.last else {
            throw ContextualTranslationError.invalidSelection
        }
        try applyPhraseGroup(group.id,
                             span: UTF16Span(location: 1 + first, length: last - first + 1),
                             to: &attributedTarget,
                             source: target)
    }
    return ContextualTranslationPayload(sourceText: request.sentenceText,
                                        attributedSourceText: source,
                                        targetText: target,
                                        attributedTargetText: attributedTarget)
}

private func makeSelectedTokenPayload(request: ContextualTranslationRequest,
                                      source: AttributedString) throws -> ContextualTranslationPayload {
    let target = "甲读书乙"
    var attributedTarget = AttributedString(target)
    for id in request.selectedTokenIDs {
        guard let token = request.tokens.first(where: { $0.id == id }) else {
            throw ContextualTranslationError.unknownTokenID
        }
        let span: UTF16Span
        switch token.sourceSurface.lowercased() {
        case "read": span = UTF16Span(location: 1, length: 1)
        case "books": span = UTF16Span(location: 2, length: 1)
        default: throw ContextualTranslationError.invalidSelection
        }
        try applyToken(id, span: span, to: &attributedTarget, source: target)
    }
    return ContextualTranslationPayload(sourceText: request.sentenceText,
                                        attributedSourceText: source,
                                        targetText: target,
                                        attributedTargetText: attributedTarget)
}

private func makeFakePayload(request: ContextualTranslationRequest,
                             translation: String = "义") throws -> ContextualTranslationPayload {
    let target = "甲\(translation)乙"
    var attributedTarget = AttributedString(target)
    guard let selectedID = request.selectedTokenIDs.first else {
        throw ContextualTranslationError.invalidSelection
    }
    let targetSpan = UTF16Span(location: 1, length: (translation as NSString).length)
    let lowerStringIndex = String.Index(utf16Offset: targetSpan.location, in: target)
    let upperStringIndex = String.Index(utf16Offset: targetSpan.endExclusive ?? 0, in: target)
    guard let lower = AttributedString.Index(lowerStringIndex, within: attributedTarget),
          let upper = AttributedString.Index(upperStringIndex, within: attributedTarget) else {
        throw ContextualTranslationError.invalidTargetRange
    }
    attributedTarget[lower..<upper][ContextualTranslationTokenIDAttribute.self] = selectedID
    return ContextualTranslationPayload(sourceText: request.sentenceText,
                                        attributedSourceText: try request.attributedSourceText(),
                                        targetText: target,
                                        attributedTargetText: attributedTarget)
}

private func makePhraseModePayload(request: ContextualTranslationRequest,
                                   source: AttributedString) throws -> ContextualTranslationPayload {
    let target = "他们读书每天"
    var attributedTarget = AttributedString(target)
    if let group = request.selectedPhraseGroup {
        try applyPhraseGroup(group.id,
                             span: UTF16Span(location: 2, length: 2),
                             to: &attributedTarget,
                             source: target)
    } else {
        for id in request.selectedTokenIDs {
            guard let token = request.tokens.first(where: { $0.id == id }) else {
                throw ContextualTranslationError.unknownTokenID
            }
            let offset = token.sourceSurface == "read" ? 2 : 3
            try applyToken(id,
                           span: UTF16Span(location: offset, length: 1),
                           to: &attributedTarget,
                           source: target)
        }
    }
    return ContextualTranslationPayload(sourceText: request.sentenceText,
                                        attributedSourceText: source,
                                        targetText: target,
                                        attributedTargetText: attributedTarget)
}

private func applyToken(_ id: String,
                        span: UTF16Span,
                        to attributed: inout AttributedString,
                        source: String) throws {
    guard let end = span.endExclusive,
          let lower = AttributedString.Index(String.Index(utf16Offset: span.location, in: source), within: attributed),
          let upper = AttributedString.Index(String.Index(utf16Offset: end, in: source), within: attributed) else {
        throw ContextualTranslationError.invalidTargetRange
    }
    attributed[lower..<upper][ContextualTranslationTokenIDAttribute.self] = id
}

private func applyPhraseGroup(_ id: String,
                              span: UTF16Span,
                              to attributed: inout AttributedString,
                              source: String) throws {
    guard let end = span.endExclusive,
          let lower = AttributedString.Index(String.Index(utf16Offset: span.location, in: source), within: attributed),
          let upper = AttributedString.Index(String.Index(utf16Offset: end, in: source), within: attributed) else {
        throw ContextualTranslationError.invalidTargetRange
    }
    attributed[lower..<upper][ContextualTranslationPhraseGroupIDAttribute.self] = id
}
