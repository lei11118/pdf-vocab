import Foundation
import XCTest
@testable import PdfVocab

@MainActor
final class OCRCharacterGeometryComposerTests: XCTestCase {
    func testCompleteTokenPromotesFromActualCharacterBoxUnionAndKeepsSourceIdentity() throws {
        let wordFrame = CGRect(x: 50, y: 100, width: 40, height: 20)
        let page = try makePage(text: "ab", tokens: [
            token("ab", at: 0, kind: .word, quality: .word, rect: wordFrame)
        ])
        let original = try XCTUnwrap(page.lines.first?.tokens.first)
        let boxes = try [
            characterBox(UTF16Span(location: 0, length: 1), CGRect(x: 54, y: 104, width: 8, height: 12)),
            characterBox(UTF16Span(location: 1, length: 1), CGRect(x: 68, y: 104, width: 9, height: 12))
        ]

        let output = OCRCharacterGeometryComposer.apply(
            page: page,
            refinementsByBlockID: ["row": refinement(for: page, boxes: boxes)])
        let updatedLine = try XCTUnwrap(output.lines.first)
        let updatedToken = try XCTUnwrap(updatedLine.tokens.first)
        let updatedGeometry = try XCTUnwrap(updatedLine.tokenGeometry.first)

        XCTAssertEqual(updatedToken.geometryQuality, .verifiedCharacter)
        XCTAssertEqual(updatedToken.id, original.id)
        XCTAssertEqual(updatedToken.span, original.span)
        XCTAssertEqual(updatedToken.sourceSurface, original.sourceSurface)
        XCTAssertEqual(updatedLine.sourceText, "ab")
        XCTAssertEqual(updatedLine.candidates, page.lines[0].candidates)
        XCTAssertEqual(output.revision, page.revision)
        XCTAssertEqual(updatedGeometry.quality, .verifiedCharacter)
        XCTAssertEqual(updatedGeometry.rect,
                       try XCTUnwrap(SourceRect(x: 54, y: 104, width: 23, height: 12)))
        XCTAssertEqual(page, try makePage(text: "ab", tokens: [
            token("ab", at: 0, kind: .word, quality: .word, rect: wordFrame)
        ]), "Applying geometry returns a new value and does not mutate the raw base page")
        XCTAssertEqual(ContextOCRSelectionSource(page: output)?.words.map(\.text), ["ab"],
                       "The legacy hit-test bridge accepts verified token geometry")
    }

    func testMissingCharacterBoxLeavesEntireTokenAtWordGeometry() throws {
        let wordFrame = CGRect(x: 50, y: 100, width: 40, height: 20)
        let page = try makePage(text: "ab", tokens: [
            token("ab", at: 0, kind: .word, quality: .word, rect: wordFrame)
        ])
        let result = refinement(for: page, boxes: [
            try characterBox(UTF16Span(location: 0, length: 1), CGRect(x: 54, y: 104, width: 8, height: 12))
        ])

        XCTAssertEqual(OCRCharacterGeometryComposer.apply(page: page,
                                                          refinementsByBlockID: ["row": result]), page)
        XCTAssertEqual(page.lines[0].tokens[0].geometryQuality, .word)
        XCTAssertEqual(page.lines[0].tokenGeometry[0].rect,
                       try XCTUnwrap(SourceRect(rect: wordFrame)))
    }

    func testSharedNumberAndSymbolWordComponentIsAtomicWhenOneTokenLacksABox() throws {
        let sharedFrame = CGRect(x: 50, y: 100, width: 60, height: 20)
        let page = try makePage(text: "3.2+", tokens: [
            token("3", at: 0, kind: .number, quality: .word, rect: sharedFrame),
            token(".", at: 1, kind: .punctuation, quality: .word, rect: sharedFrame),
            token("2", at: 2, kind: .number, quality: .word, rect: sharedFrame),
            token("+", at: 3, kind: .symbol, quality: .word, rect: sharedFrame)
        ])
        let boxes = try [
            characterBox(UTF16Span(location: 0, length: 1), CGRect(x: 52, y: 104, width: 6, height: 12)),
            characterBox(UTF16Span(location: 1, length: 1), CGRect(x: 62, y: 104, width: 5, height: 12)),
            characterBox(UTF16Span(location: 2, length: 1), CGRect(x: 72, y: 104, width: 6, height: 12))
        ]

        let output = OCRCharacterGeometryComposer.apply(
            page: page,
            refinementsByBlockID: ["row": refinement(for: page, boxes: boxes)])

        XCTAssertEqual(output, page,
                       "A shared accurate word box is one atomic component; no partial fine/coarse mix is allowed")
    }

    func testCompleteSharedNumberAndSymbolComponentUsesActualFineBoxes() throws {
        let sharedFrame = CGRect(x: 50, y: 100, width: 60, height: 20)
        let page = try makePage(text: "3.2+", tokens: [
            token("3", at: 0, kind: .number, quality: .word, rect: sharedFrame),
            token(".", at: 1, kind: .punctuation, quality: .word, rect: sharedFrame),
            token("2", at: 2, kind: .number, quality: .word, rect: sharedFrame),
            token("+", at: 3, kind: .symbol, quality: .word, rect: sharedFrame)
        ])
        let actualRects = [
            CGRect(x: 52, y: 104, width: 6, height: 12),
            CGRect(x: 62, y: 104, width: 5, height: 12),
            CGRect(x: 72, y: 104, width: 6, height: 12),
            CGRect(x: 84, y: 104, width: 8, height: 12)
        ]
        let boxes = try zip(0..<actualRects.count, actualRects).map { index, rect in
            try characterBox(UTF16Span(location: index, length: 1), rect)
        }

        let output = OCRCharacterGeometryComposer.apply(
            page: page,
            refinementsByBlockID: ["row": refinement(for: page, boxes: boxes)])
        let line = try XCTUnwrap(output.lines.first)

        XCTAssertEqual(line.tokens.map(\.geometryQuality), Array(repeating: .verifiedCharacter, count: 4))
        XCTAssertEqual(line.tokenGeometry.compactMap(\.rect), try actualRects.map { try XCTUnwrap(SourceRect(rect: $0)) })
        XCTAssertEqual(ContextOCRSelectionSource(page: output)?.words.map(\.text), ["3", ".", "2", "+"])
        XCTAssertEqual(line.sourceText, "3.2+")
    }

    func testUnknownSourceHoleOverlappingWordParentBlocksTheWholeComponent() throws {
        let sharedFrame = CGRect(x: 50, y: 100, width: 40, height: 20)
        let page = try makePage(text: "x_i", tokens: [
            token("x", at: 0, kind: .word, quality: .word, rect: sharedFrame),
            token("_", at: 1, kind: .symbol, quality: .unknown, rect: nil),
            token("i", at: 2, kind: .word, quality: .word, rect: sharedFrame)
        ], omitGeometryAt: [1])
        let boxes = try [
            characterBox(UTF16Span(location: 0, length: 1), CGRect(x: 54, y: 104, width: 8, height: 12)),
            characterBox(UTF16Span(location: 2, length: 1), CGRect(x: 68, y: 104, width: 8, height: 12))
        ]

        let output = OCRCharacterGeometryComposer.apply(
            page: page,
            refinementsByBlockID: ["row": refinement(for: page, boxes: boxes)])

        XCTAssertEqual(output, page,
                       "The accurate shared parent includes the unknown source hole, so no member is refined alone")
        XCTAssertEqual(output.lines[0].tokens.map(\.geometryQuality), [.word, .unknown, .word])
        XCTAssertEqual(ContextOCRSelectionSource(page: output)?.entries.first?.word.text, "x_i")

        let fullCoverage = try boxes + [
            characterBox(UTF16Span(location: 1, length: 1), CGRect(x: 64, y: 104, width: 6, height: 12))
        ]
        let fullyRefined = OCRCharacterGeometryComposer.apply(
            page: page,
            refinementsByBlockID: ["row": refinement(for: page, boxes: fullCoverage)])
        XCTAssertEqual(fullyRefined.lines[0].tokens.map(\.geometryQuality),
                       Array(repeating: .verifiedCharacter, count: 3))
        XCTAssertEqual(fullyRefined.lines[0].tokenGeometry.count, 3,
                       "A sparse unknown token receives one geometry record only after the whole group validates")
        XCTAssertEqual(ContextOCRSelectionSource(page: fullyRefined)?.words.map(\.text), ["x", "_", "i"])
    }

    func testDisjointUnknownSymbolCanBePromotedWithItsOwnCompleteFastBox() throws {
        let wordFrame = CGRect(x: 50, y: 100, width: 58, height: 20)
        let page = try makePage(text: "word +", tokens: [
            token("word", at: 0, kind: .word, quality: .word, rect: wordFrame),
            token("+", at: 5, kind: .symbol, quality: .unknown, rect: nil)
        ], omitGeometryAt: [1])
        var boxes = try characterBoxes("word", sourceOffset: 0, x: 52, y: 104, width: 8, gap: 4)
        boxes += try [characterBox(UTF16Span(location: 5, length: 1), CGRect(x: 190, y: 104, width: 8, height: 12))]

        let output = OCRCharacterGeometryComposer.apply(
            page: page,
            refinementsByBlockID: ["row": refinement(for: page, boxes: boxes)])
        let line = try XCTUnwrap(output.lines.first)

        XCTAssertEqual(line.tokens.map(\.geometryQuality), [.verifiedCharacter, .verifiedCharacter])
        let plusGeometry = try XCTUnwrap(line.tokenGeometry.first { $0.tokenID == line.tokens[1].id })
        XCTAssertEqual(plusGeometry.quality, .verifiedCharacter)
        XCTAssertEqual(plusGeometry.rect,
                       try XCTUnwrap(SourceRect(x: 190, y: 104, width: 8, height: 12)))
        XCTAssertEqual(ContextOCRSelectionSource(page: output)?.words.map(\.text), ["word", "+"])
    }

    func testRejectsRawSourceMediaFallbackAndNonExactProvenance() throws {
        let page = try makePage(text: "a", tokens: [
            token("a", at: 0, kind: .word, quality: .word,
                  rect: CGRect(x: 50, y: 100, width: 20, height: 20))
        ])
        let oneBox = try characterBox(UTF16Span(location: 0, length: 1),
                                      CGRect(x: 54, y: 104, width: 8, height: 12))
        let wrongMedia = try XCTUnwrap(SourceRect(x: 1, y: 0, width: 400, height: 300))
        let invalidResults = try [
            refinement(for: page, boxes: [oneBox], sourceText: "b"),
            refinement(for: page, boxes: [oneBox], mediaBox: wrongMedia),
            refinement(for: page, boxes: [oneBox], fallback: .alignmentRejected),
            refinement(for: page, boxes: [characterBox(oneBox.sourceSpan,
                                                        CGRect(x: 54, y: 104, width: 8, height: 12),
                                                        geometrySource: .mandatoryExactMapping)]),
            refinement(for: page, boxes: [characterBox(oneBox.sourceSpan,
                                                        CGRect(x: 54, y: 104, width: 8, height: 12),
                                                        mappingSource: .visionFast)])
        ]

        for result in invalidResults {
            XCTAssertEqual(OCRCharacterGeometryComposer.apply(page: page,
                                                              refinementsByBlockID: ["row": result]), page)
        }
    }

    func testRejectsDuplicateInvalidOutOfBoundsAndNearlyIdenticalCharacterBoxes() throws {
        let wordFrame = CGRect(x: 50, y: 100, width: 40, height: 20)
        let oneCharacterPage = try makePage(text: "a", tokens: [
            token("a", at: 0, kind: .word, quality: .word, rect: wordFrame)
        ])
        let validBox = try characterBox(UTF16Span(location: 0, length: 1),
                                        CGRect(x: 54, y: 104, width: 8, height: 12))
        let duplicateSpan = try characterBox(validBox.sourceSpan,
                                             CGRect(x: 55, y: 104, width: 8, height: 12))
        let invalidRange = try characterBox(UTF16Span(location: 8, length: 1),
                                            CGRect(x: 54, y: 104, width: 8, height: 12))
        let outOfMedia = try characterBox(UTF16Span(location: 0, length: 1),
                                          CGRect(x: 410, y: 104, width: 8, height: 12))
        let outsideLineExpansion = try characterBox(UTF16Span(location: 0, length: 1),
                                                    CGRect(x: 54, y: 140, width: 8, height: 12))
        let oneCharacterCases = [
            [validBox, duplicateSpan],
            [invalidRange],
            [outOfMedia],
            [outsideLineExpansion]
        ]
        for boxes in oneCharacterCases {
            XCTAssertEqual(OCRCharacterGeometryComposer.apply(
                page: oneCharacterPage,
                refinementsByBlockID: ["row": refinement(for: oneCharacterPage, boxes: boxes)]), oneCharacterPage)
        }

        let twoCharacterPage = try makePage(text: "ab", tokens: [
            token("ab", at: 0, kind: .word, quality: .word, rect: wordFrame)
        ])
        let sameRect = CGRect(x: 58, y: 104, width: 8, height: 12)
        let nearlyDuplicate = try [
            characterBox(UTF16Span(location: 0, length: 1), sameRect),
            characterBox(UTF16Span(location: 1, length: 1), sameRect)
        ]
        XCTAssertEqual(OCRCharacterGeometryComposer.apply(
            page: twoCharacterPage,
            refinementsByBlockID: ["row": refinement(for: twoCharacterPage, boxes: nearlyDuplicate)]),
            twoCharacterPage,
            "Distinct source characters cannot share one indistinguishable box")
    }

    func testRejectsTokensWithMismatchedDocumentPageBlockOrSurface() throws {
        let pageSHA = "composer-fixture"
        let pageIndex = 3
        let media = try XCTUnwrap(SourceRect(x: 0, y: 0, width: 400, height: 300))
        let span = UTF16Span(location: 0, length: 1)
        let invalidTokens = [
            SourceToken(documentSHA256: "another-document", pageIndex: pageIndex, span: span,
                        sourceSurface: "a", kind: .word, blockID: "row", geometryQuality: .word),
            SourceToken(documentSHA256: pageSHA, pageIndex: pageIndex + 1, span: span,
                        sourceSurface: "a", kind: .word, blockID: "row", geometryQuality: .word),
            SourceToken(documentSHA256: pageSHA, pageIndex: pageIndex, span: span,
                        sourceSurface: "a", kind: .word, blockID: "another-row", geometryQuality: .word),
            SourceToken(documentSHA256: pageSHA, pageIndex: pageIndex, span: span,
                        sourceSurface: "b", kind: .word, blockID: "row", geometryQuality: .word),
            SourceToken(documentSHA256: pageSHA, pageIndex: pageIndex, span: UTF16Span(location: 1, length: 1),
                        sourceSurface: "a", kind: .word, blockID: "row", geometryQuality: .word)
        ]

        for token in invalidTokens {
            let geometry = SourceTokenGeometry(tokenID: token.id,
                                               span: token.span,
                                               rect: try XCTUnwrap(SourceRect(x: 50, y: 100, width: 20, height: 20)),
                                               quality: .word)
            let line = try makeRawLine(blockID: "row",
                                       text: "a",
                                       regionRect: CGRect(x: 10, y: 65, width: 300, height: 90),
                                       pageRect: CGRect(x: 20, y: 80, width: 250, height: 40),
                                       tokens: [token],
                                       geometries: [geometry])
            let page = ContextOCRPage(documentSHA256: pageSHA,
                                      pageIndex: pageIndex,
                                      revision: ContextOCRPage.currentRevision,
                                      mediaBox: media,
                                      lines: [line])
            let box = try characterBox(span, CGRect(x: 54, y: 104, width: 8, height: 12))

            XCTAssertEqual(OCRCharacterGeometryComposer.apply(
                page: page,
                refinementsByBlockID: ["row": refinement(for: page, boxes: [box])]), page)
        }
    }

    func testSourceAndTokenSurfaceComparisonsUseExactUTF16() throws {
        let page = try makePage(text: "é", tokens: [
            token("é", at: 0, kind: .word, quality: .word,
                  rect: CGRect(x: 50, y: 100, width: 20, height: 20))
        ])
        let canonicallyEquivalentButDifferentUTF16 = "e\u{301}"
        let box = try characterBox(UTF16Span(location: 0, length: 1),
                                   CGRect(x: 54, y: 104, width: 8, height: 12))
        let wrongRaw = refinement(for: page,
                                  boxes: [box],
                                  sourceText: canonicallyEquivalentButDifferentUTF16)
        XCTAssertEqual(OCRCharacterGeometryComposer.apply(page: page,
                                                          refinementsByBlockID: ["row": wrongRaw]), page)

        let wrongSurfaceToken = SourceToken(documentSHA256: page.documentSHA256,
                                            pageIndex: page.pageIndex,
                                            span: UTF16Span(location: 0, length: 1),
                                            sourceSurface: canonicallyEquivalentButDifferentUTF16,
                                            kind: .word,
                                            blockID: "row",
                                            geometryQuality: .word)
        let wrongSurfaceGeometry = SourceTokenGeometry(tokenID: wrongSurfaceToken.id,
                                                      span: wrongSurfaceToken.span,
                                                      rect: try XCTUnwrap(SourceRect(x: 50, y: 100, width: 20, height: 20)),
                                                      quality: .word)
        let wrongSurfaceLine = try makeRawLine(blockID: "row", text: "é",
                                               regionRect: CGRect(x: 10, y: 65, width: 300, height: 90),
                                               pageRect: CGRect(x: 20, y: 80, width: 250, height: 40),
                                               tokens: [wrongSurfaceToken], geometries: [wrongSurfaceGeometry])
        let wrongSurfacePage = ContextOCRPage(documentSHA256: page.documentSHA256,
                                              pageIndex: page.pageIndex,
                                              revision: page.revision,
                                              mediaBox: page.mediaBox,
                                              lines: [wrongSurfaceLine])
        XCTAssertEqual(OCRCharacterGeometryComposer.apply(
            page: wrongSurfacePage,
            refinementsByBlockID: ["row": refinement(for: wrongSurfacePage, boxes: [box])]), wrongSurfacePage)
    }

    func testMergePreservesLateVerifiedGeometryAndRetainsNewVerifiedLines() throws {
        let firstLine = try makeLine(text: "ab", tokens: [
            token("ab", at: 0, kind: .word, quality: .word,
                  rect: CGRect(x: 50, y: 100, width: 40, height: 20))
        ], blockID: "line-a")
        let basePage = makePage(lines: [firstLine])
        let firstRefinement = try refinement(for: basePage,
                                            lineIndex: 0,
                                            boxes: characterBoxes("ab", sourceOffset: 0, x: 54, y: 104,
                                                                  width: 8, gap: 5))
        let existing = OCRCharacterGeometryComposer.apply(
            page: basePage,
            refinementsByBlockID: ["line-a": firstRefinement])

        let secondLine = try makeLine(text: "cd", tokens: [
            token("cd", at: 0, kind: .word, quality: .word,
                  rect: CGRect(x: 50, y: 170, width: 40, height: 20))
        ], blockID: "line-b",
        lineRect: CGRect(x: 20, y: 150, width: 250, height: 40),
        regionRect: CGRect(x: 10, y: 140, width: 300, height: 90))
        let incomingBase = makePage(lines: [firstLine, secondLine], revision: basePage.revision)
        let secondRefinement = try refinement(for: incomingBase,
                                              lineIndex: 1,
                                              boxes: characterBoxes("cd", sourceOffset: 0, x: 54, y: 174,
                                                                    width: 8, gap: 5))
        let incoming = OCRCharacterGeometryComposer.apply(
            page: incomingBase,
            refinementsByBlockID: ["line-b": secondRefinement])

        let merged = OCRCharacterGeometryComposer.mergePreservingVerifiedGeometry(existing: existing,
                                                                                   incoming: incoming)

        XCTAssertEqual(merged.lines[0].tokens[0].geometryQuality, .verifiedCharacter,
                       "Late word-only OCR must not downgrade an existing verified line")
        XCTAssertEqual(merged.lines[1].tokens[0].geometryQuality, .verifiedCharacter,
                       "A newly arriving verified line remains intact")
        XCTAssertEqual(merged.lines[0].tokenGeometry[0].rect, existing.lines[0].tokenGeometry[0].rect)
        XCTAssertEqual(merged.lines[1].tokenGeometry[0].rect, incoming.lines[1].tokenGeometry[0].rect)
    }

    func testMergeDoesNotCarryVerifiedGeometryAcrossChangedSourceOrLayout() throws {
        let baseLine = try makeLine(text: "ab", tokens: [
            token("ab", at: 0, kind: .word, quality: .word,
                  rect: CGRect(x: 50, y: 100, width: 40, height: 20))
        ], blockID: "same-row")
        let basePage = makePage(lines: [baseLine])
        let refinement = try refinement(for: basePage,
                                       boxes: characterBoxes("ab", sourceOffset: 0, x: 54, y: 104,
                                                             width: 8, gap: 5))
        let existing = OCRCharacterGeometryComposer.apply(
            page: basePage,
            refinementsByBlockID: ["same-row": refinement])

        let changedTextLine = try makeLine(text: "ac", tokens: [
            token("ac", at: 0, kind: .word, quality: .word,
                  rect: CGRect(x: 50, y: 100, width: 40, height: 20))
        ], blockID: "same-row")
        let changedText = makePage(lines: [changedTextLine], revision: basePage.revision)
        XCTAssertEqual(OCRCharacterGeometryComposer.mergePreservingVerifiedGeometry(
            existing: existing, incoming: changedText), changedText)

        let changedLayoutLine = try makeLine(text: "ab", tokens: [
            token("ab", at: 0, kind: .word, quality: .word,
                  rect: CGRect(x: 50, y: 100, width: 40, height: 20))
        ], blockID: "same-row",
        lineRect: CGRect(x: 25, y: 80, width: 250, height: 40),
        regionRect: CGRect(x: 15, y: 65, width: 300, height: 90))
        let changedLayout = makePage(lines: [changedLayoutLine], revision: basePage.revision)
        XCTAssertEqual(OCRCharacterGeometryComposer.mergePreservingVerifiedGeometry(
            existing: existing, incoming: changedLayout), changedLayout)
    }

    func testMergePreservesVerifiedGeometryForSparseUnknownTokenInLateBasePage() throws {
        let sharedFrame = CGRect(x: 50, y: 100, width: 40, height: 20)
        let base = try makePage(text: "x_i", tokens: [
            token("x", at: 0, kind: .word, quality: .word, rect: sharedFrame),
            token("_", at: 1, kind: .symbol, quality: .unknown, rect: nil),
            token("i", at: 2, kind: .word, quality: .word, rect: sharedFrame)
        ], omitGeometryAt: [1])
        let verifiedBoxes = try [
            characterBox(UTF16Span(location: 0, length: 1), CGRect(x: 54, y: 104, width: 6, height: 12)),
            characterBox(UTF16Span(location: 1, length: 1), CGRect(x: 64, y: 104, width: 6, height: 12)),
            characterBox(UTF16Span(location: 2, length: 1), CGRect(x: 74, y: 104, width: 6, height: 12))
        ]
        let existing = OCRCharacterGeometryComposer.apply(
            page: base,
            refinementsByBlockID: ["row": refinement(for: base, boxes: verifiedBoxes)])

        let merged = OCRCharacterGeometryComposer.mergePreservingVerifiedGeometry(existing: existing,
                                                                                   incoming: base)
        let line = try XCTUnwrap(merged.lines.first)

        XCTAssertEqual(line.tokens.map(\.geometryQuality), Array(repeating: .verifiedCharacter, count: 3))
        XCTAssertEqual(line.tokenGeometry.count, 3)
        XCTAssertEqual(line.tokenGeometry.first { $0.tokenID == line.tokens[1].id }?.quality,
                       .verifiedCharacter)
    }

    private func makePage(text: String,
                          tokens: [TokenSpec],
                          blockID: String = "row",
                          pageIndex: Int = 3,
                          documentSHA256: String = "composer-fixture",
                          mediaBox: SourceRect? = nil,
                          omitGeometryAt: Set<Int> = [],
                          lineRect: CGRect = CGRect(x: 20, y: 80, width: 250, height: 40),
                          regionRect: CGRect = CGRect(x: 10, y: 65, width: 300, height: 90)) throws -> ContextOCRPage {
        let line = try makeLine(text: text,
                                tokens: tokens,
                                blockID: blockID,
                                documentSHA256: documentSHA256,
                                pageIndex: pageIndex,
                                omitGeometryAt: omitGeometryAt,
                                lineRect: lineRect,
                                regionRect: regionRect)
        return makePage(lines: [line],
                        documentSHA256: documentSHA256,
                        pageIndex: pageIndex,
                        mediaBox: mediaBox)
    }

    private func makePage(lines: [OCRLine],
                          documentSHA256: String = "composer-fixture",
                          pageIndex: Int = 3,
                          revision: Int = ContextOCRPage.currentRevision,
                          mediaBox: SourceRect? = nil) -> ContextOCRPage {
        ContextOCRPage(documentSHA256: documentSHA256,
                       pageIndex: pageIndex,
                       revision: revision,
                       mediaBox: mediaBox ?? SourceRect(x: 0, y: 0, width: 400, height: 300)!,
                       lines: lines)
    }

    private func makeLine(text: String,
                          tokens: [TokenSpec],
                          blockID: String = "row",
                          documentSHA256: String = "composer-fixture",
                          pageIndex: Int = 3,
                          omitGeometryAt: Set<Int> = [],
                          lineRect: CGRect = CGRect(x: 20, y: 80, width: 250, height: 40),
                          regionRect: CGRect = CGRect(x: 10, y: 65, width: 300, height: 90)) throws -> OCRLine {
        let pageRect = try XCTUnwrap(SourceRect(rect: lineRect))
        let region = try XCTUnwrap(SourceRect(rect: regionRect))
        let sourceTokens = tokens.map {
            SourceToken(documentSHA256: documentSHA256,
                        pageIndex: pageIndex,
                        span: $0.span,
                        sourceSurface: $0.text,
                        kind: $0.kind,
                        blockID: blockID,
                        geometryQuality: $0.quality)
        }
        let geometry = try zip(sourceTokens, tokens).enumerated().compactMap { index, pair -> SourceTokenGeometry? in
            guard !omitGeometryAt.contains(index) else { return nil }
            let token = pair.0
            let spec = pair.1
            return SourceTokenGeometry(tokenID: token.id,
                                       span: token.span,
                                       rect: try spec.rect.map { try XCTUnwrap(SourceRect(rect: $0)) },
                                       quality: spec.quality)
        }
        return OCRLine(blockID: blockID,
                       candidates: [OCRCandidate(text: text, confidence: 0.9)],
                       regionRect: region,
                       pageRect: pageRect,
                       tokens: sourceTokens,
                       tokenGeometry: geometry)
    }

    private func makeRawLine(blockID: String,
                             text: String,
                             regionRect: CGRect,
                             pageRect: CGRect,
                             tokens: [SourceToken],
                             geometries: [SourceTokenGeometry]) throws -> OCRLine {
        OCRLine(blockID: blockID,
                candidates: [OCRCandidate(text: text, confidence: 0.9)],
                regionRect: try XCTUnwrap(SourceRect(rect: regionRect)),
                pageRect: try XCTUnwrap(SourceRect(rect: pageRect)),
                tokens: tokens,
                tokenGeometry: geometries)
    }

    private func refinement(for page: ContextOCRPage,
                            lineIndex: Int = 0,
                            boxes: [OCRCharacterRefinedBox],
                            sourceText: String? = nil,
                            mediaBox: SourceRect? = nil,
                            roi: SourceRect? = nil,
                            fallback: OCRCharacterRefinementFallback? = nil) throws -> OCRCharacterRefinementResult {
        let line = try XCTUnwrap(page.lines.indices.contains(lineIndex) ? page.lines[lineIndex] : nil)
        return OCRCharacterRefinementResult(sourceText: sourceText ?? line.sourceText,
                                            mediaBox: mediaBox ?? page.mediaBox,
                                            roi: roi ?? line.regionRect,
                                            observations: [],
                                            selectedObservationOrdinal: 0,
                                            boxes: boxes,
                                            fallback: fallback)
    }

    private func token(_ text: String,
                       at location: Int,
                       kind: SourceTokenKind,
                       quality: SourceGeometryQuality,
                       rect: CGRect?) -> TokenSpec {
        TokenSpec(text: text,
                  span: UTF16Span(location: location, length: text.utf16.count),
                  kind: kind,
                  quality: quality,
                  rect: rect)
    }

    private func characterBox(_ span: UTF16Span,
                              _ rect: CGRect,
                              geometrySource: OCRCharacterRefinementSource = .visionFast,
                              mappingSource: OCRCharacterRefinementSource = .mandatoryExactMapping) throws -> OCRCharacterRefinedBox {
        OCRCharacterRefinedBox(sourceSpan: span,
                               actualRect: try XCTUnwrap(SourceRect(rect: rect)),
                               geometrySource: geometrySource,
                               mappingSource: mappingSource)
    }

    private func characterBoxes(_ text: String,
                                sourceOffset: Int,
                                x: CGFloat,
                                y: CGFloat,
                                width: CGFloat,
                                gap: CGFloat,
                                height: CGFloat = 12) throws -> [OCRCharacterRefinedBox] {
        let spans = composedSpans(in: text)
        return try spans.enumerated().map { index, span in
            try characterBox(UTF16Span(location: sourceOffset + span.location, length: span.length),
                             CGRect(x: x + CGFloat(index) * (width + gap), y: y,
                                    width: width, height: height))
        }
    }

    private func composedSpans(in text: String) -> [UTF16Span] {
        let nsText = text as NSString
        var spans: [UTF16Span] = []
        var offset = 0
        while offset < nsText.length {
            let range = nsText.rangeOfComposedCharacterSequence(at: offset)
            if let span = UTF16Span(composedRange: range, in: text) { spans.append(span) }
            offset += max(1, range.length)
        }
        return spans
    }

    private struct TokenSpec {
        let text: String
        let span: UTF16Span
        let kind: SourceTokenKind
        let quality: SourceGeometryQuality
        let rect: CGRect?
    }
}
