import Foundation
import XCTest
@testable import PdfVocab

final class SentenceContextBuilderTests: XCTestCase {
    func testMapsRepeatedSelectionAndSentenceAcrossWhitespaceOnlyDisplayChange() throws {
        let source = "Charge first. Charge again?"
        let display = "Charge first.  Charge again?"
        let origin = 400
        let nsSource = source as NSString
        let first = nsSource.range(of: "Charge")
        let second = nsSource.range(of: "Charge",
                                    options: [],
                                    range: NSRange(location: NSMaxRange(first),
                                                   length: nsSource.length - NSMaxRange(first)))
        let again = nsSource.range(of: "again")
        let selected = [
            try XCTUnwrap(UTF16Span(range: second, in: source)).adding(offset: origin),
            try XCTUnwrap(UTF16Span(range: again, in: source)).adding(offset: origin)
        ]

        let context = try XCTUnwrap(SentenceContextBuilder.build(sourceText: source,
                                                                 sourceStartUTF16Offset: origin,
                                                                 displayText: display,
                                                                 selectedSourceSpans: selected,
                                                                 documentSHA256: "fixture-document",
                                                                 pageIndex: 7,
                                                                 blockID: "line-3"))

        XCTAssertEqual(context.documentSHA256, "fixture-document")
        XCTAssertEqual(context.pageIndex, 7)
        XCTAssertEqual(context.blockID, "line-3")
        XCTAssertEqual(context.text, "Charge again?")
        XCTAssertEqual(context.displayLineText, display)
        XCTAssertEqual(context.displaySentenceText, "Charge again?")
        XCTAssertEqual(context.kind, .completeSentence)
        XCTAssertEqual(context.sourceSpan, UTF16Span(location: origin + second.location,
                                                     length: nsSource.length - second.location))
        XCTAssertEqual(context.selectedSourceSpans, selected)
        XCTAssertEqual(context.displaySpan.substring(in: context.displayLineText), context.displaySentenceText)
        XCTAssertEqual(context.selectedDisplaySpans.compactMap { $0.substring(in: display) },
                       ["Charge", "again"])
    }

    func testLowercaseAndMissingTerminalPunctuationAreFragments() throws {
        for (source, selectedText) in [("lower-case sentence.", "sentence"),
                                       ("Uppercase fragment", "fragment")] {
            let ns = source as NSString
            let selected = try XCTUnwrap(UTF16Span(range: ns.range(of: selectedText), in: source))
            let span = selected.adding(offset: 50)
            let context = try XCTUnwrap(SentenceContextBuilder.build(sourceText: source,
                                                                     sourceStartUTF16Offset: 50,
                                                                     displayText: source,
                                                                     selectedSourceSpans: [span],
                                                                     documentSHA256: "doc",
                                                                     pageIndex: 0,
                                                                     blockID: "block"))
            XCTAssertEqual(context.kind, .fragment)
        }
    }

    func testKeepsLineLocalOCRSpansAtZeroOrigin() throws {
        let source = "A line-local sentence."
        let selection = try XCTUnwrap(UTF16Span(range: (source as NSString).range(of: "line-local"),
                                               in: source))

        let context = try XCTUnwrap(SentenceContextBuilder.build(sourceText: source,
                                                                 sourceStartUTF16Offset: 0,
                                                                 displayText: source,
                                                                 selectedSourceSpans: [selection],
                                                                 documentSHA256: "doc",
                                                                 pageIndex: 2,
                                                                 blockID: "line-4"))

        XCTAssertEqual(context.sourceSpan, UTF16Span(location: 0, length: (source as NSString).length))
        XCTAssertEqual(context.selectedSourceSpans, [selection])
    }

    func testRejectsSelectionContainingWhitespaceTrimmedFromSentence() throws {
        let source = "  A sentence.  "
        let selected = try XCTUnwrap(UTF16Span(range: NSRange(location: 0,
                                                              length: (source as NSString).length),
                                              in: source))

        XCTAssertNil(SentenceContextBuilder.build(sourceText: source,
                                                  sourceStartUTF16Offset: 0,
                                                  displayText: source,
                                                  selectedSourceSpans: [selected],
                                                  documentSHA256: "doc",
                                                  pageIndex: 0,
                                                  blockID: "line"))
    }

    func testRejectsSelectionAcrossSentencesAndNonWhitespaceChanges() throws {
        let source = "First sentence. Second sentence."
        let ns = source as NSString
        let first = try XCTUnwrap(UTF16Span(range: ns.range(of: "First"), in: source))
        let second = try XCTUnwrap(UTF16Span(range: ns.range(of: "Second"), in: source))

        XCTAssertNil(SentenceContextBuilder.build(sourceText: source,
                                                  sourceStartUTF16Offset: 0,
                                                  displayText: source,
                                                  selectedSourceSpans: [first, second],
                                                  documentSHA256: "doc",
                                                  pageIndex: 0,
                                                  blockID: "block"))
        XCTAssertNil(SentenceContextBuilder.build(sourceText: "The original word.",
                                                  sourceStartUTF16Offset: 0,
                                                  displayText: "The changed word.",
                                                  selectedSourceSpans: [UTF16Span(location: 4, length: 8)],
                                                  documentSHA256: "doc",
                                                  pageIndex: 0,
                                                  blockID: "block"))
    }

    func testRejectsUnicodeNormalizationDifferencesAndSplitGraphemeSelection() throws {
        let composed = "Caf\u{00E9} works."
        let decomposedDisplay = "Cafe\u{0301} works."
        XCTAssertNil(SentenceContextBuilder.build(sourceText: composed,
                                                  sourceStartUTF16Offset: 0,
                                                  displayText: decomposedDisplay,
                                                  selectedSourceSpans: [UTF16Span(location: 0, length: 3)],
                                                  documentSHA256: "doc",
                                                  pageIndex: 0,
                                                  blockID: "block"))

        let source = "Cafe\u{0301} works."
        XCTAssertNil(SentenceContextBuilder.build(sourceText: source,
                                                  sourceStartUTF16Offset: 0,
                                                  displayText: source,
                                                  selectedSourceSpans: [UTF16Span(location: 3, length: 1)],
                                                  documentSHA256: "doc",
                                                  pageIndex: 0,
                                                  blockID: "block"),
                   "The selected UTF-16 range splits the composed e-acute grapheme")
    }

    func testRejectsInvalidOffsetsLineBreaksAndAlignerLimits() throws {
        let source = "A short sentence."
        XCTAssertNil(SentenceContextBuilder.build(sourceText: source,
                                                  sourceStartUTF16Offset: Int.max,
                                                  displayText: source,
                                                  selectedSourceSpans: [UTF16Span(location: 0, length: 1)],
                                                  documentSHA256: "doc",
                                                  pageIndex: 0,
                                                  blockID: "block"))
        XCTAssertNil(SentenceContextBuilder.build(sourceText: source,
                                                  sourceStartUTF16Offset: 0,
                                                  displayText: source,
                                                  selectedSourceSpans: [UTF16Span(location: Int.max, length: 1)],
                                                  documentSHA256: "doc",
                                                  pageIndex: 0,
                                                  blockID: "block"))
        XCTAssertNil(SentenceContextBuilder.build(sourceText: "One line.\nSecond line.",
                                                  sourceStartUTF16Offset: 0,
                                                  displayText: "One line.\nSecond line.",
                                                  selectedSourceSpans: [UTF16Span(location: 0, length: 3)],
                                                  documentSHA256: "doc",
                                                  pageIndex: 0,
                                                  blockID: "block"))

        let tooManyGraphemes = String(repeating: "a", count: OCRCharacterAligner.maximumGraphemes + 1)
        XCTAssertNil(SentenceContextBuilder.build(sourceText: tooManyGraphemes,
                                                  sourceStartUTF16Offset: 0,
                                                  displayText: tooManyGraphemes,
                                                  selectedSourceSpans: [UTF16Span(location: 0, length: 1)],
                                                  documentSHA256: "doc",
                                                  pageIndex: 0,
                                                  blockID: "block"))

        let tooManyUTF16Units = "a" + String(repeating: "\u{0301}", count: OCRCharacterAligner.maximumUTF16Units)
        XCTAssertNil(SentenceContextBuilder.build(sourceText: tooManyUTF16Units,
                                                  sourceStartUTF16Offset: 0,
                                                  displayText: tooManyUTF16Units,
                                                  selectedSourceSpans: [UTF16Span(location: 0, length: 1)],
                                                  documentSHA256: "doc",
                                                  pageIndex: 0,
                                                  blockID: "block"))
    }

    func testNativeBuilderUsesSelectedRepeatedOccurrenceAndPageRelativeRanges() throws {
        let source = "Charge first. Charge again?"
        let ns = source as NSString
        let first = ns.range(of: "Charge")
        let second = ns.range(of: "Charge",
                              options: [],
                              range: NSRange(location: NSMaxRange(first),
                                             length: ns.length - NSMaxRange(first)))
        let selected = try XCTUnwrap(UTF16Span(range: second, in: source))

        let context = try XCTUnwrap(NativeSentenceContextBuilder.build(sourceText: source,
                                                                        selectedSourceSpans: [selected],
                                                                        displaySurface: "Charge",
                                                                        documentSHA256: "native-repeat",
                                                                        pageIndex: 4))

        XCTAssertEqual(context.text, "Charge again?")
        XCTAssertEqual(context.sourceSpan.location, second.location)
        XCTAssertEqual(context.selectedSourceSpans, [selected])
        XCTAssertEqual(context.selectedDisplaySpans, [UTF16Span(location: 0, length: selected.length)])
        XCTAssertEqual(context.kind, .completeSentence)
    }

    func testNativeBuilderNormalizesOneLineBreakWithoutChangingUTF16Offsets() throws {
        let source = "A sentence continues\non the next line."
        let selectionRange = (source as NSString).range(of: "continues")
        let selected = try XCTUnwrap(UTF16Span(range: selectionRange, in: source))

        XCTAssertNil(NativeSentenceContextBuilder.build(sourceText: source,
                                                        selectedSourceSpans: [selected],
                                                        displaySurface: "continues",
                                                        documentSHA256: "native-wrap",
                                                        pageIndex: 0),
                   "A line break needs PDF geometry validation before it can be joined")

        let context = try XCTUnwrap(NativeSentenceContextBuilder.build(sourceText: source,
                                                                        selectedSourceSpans: [selected],
                                                                        displaySurface: "continues",
                                                                        documentSHA256: "native-wrap",
                                                                        pageIndex: 0,
                                                                        allowsLineBreaks: true))
        XCTAssertEqual(context.text, "A sentence continues on the next line.")
        XCTAssertEqual(context.sourceSpan.substring(in: source), "A sentence continues\non the next line.")
        XCTAssertEqual(context.selectedSourceSpans, [selected])
        XCTAssertEqual(context.selectedDisplaySpans.first?.location,
                       selectionRange.location - context.sourceSpan.location)

        let crlfSource = "A sentence continues\r\non the next line."
        let crlfRange = (crlfSource as NSString).range(of: "continues")
        let crlfSelection = try XCTUnwrap(UTF16Span(range: crlfRange, in: crlfSource))
        let crlfContext = try XCTUnwrap(NativeSentenceContextBuilder.build(sourceText: crlfSource,
                                                                            selectedSourceSpans: [crlfSelection],
                                                                            displaySurface: "continues",
                                                                            documentSHA256: "native-crlf",
                                                                            pageIndex: 0,
                                                                            allowsLineBreaks: true))
        XCTAssertEqual(crlfContext.text, "A sentence continues  on the next line.")
        XCTAssertEqual(crlfContext.sourceSpan.location, 0)
        XCTAssertEqual(crlfContext.selectedSourceSpans, [crlfSelection])
    }

    func testNativeBuilderRejectsBlankLineAndUntrustedColumnGeometry() throws {
        let source = "A sentence begins\n \nand then ends."
        let ns = source as NSString
        let first = try XCTUnwrap(UTF16Span(range: ns.range(of: "begins"), in: source))
        let last = try XCTUnwrap(UTF16Span(range: ns.range(of: "ends"), in: source))
        XCTAssertNil(NativeSentenceContextBuilder.build(sourceText: source,
                                                        selectedSourceSpans: [first, last],
                                                        displaySurface: "begins ends",
                                                        documentSHA256: "native-blank-line",
                                                        pageIndex: 0,
                                                        allowsLineBreaks: true))

        XCTAssertTrue(NativeSentenceContextBuilder.hasTrustedAdjacentLineGeometry([
            CGRect(x: 40, y: 200, width: 180, height: 16),
            CGRect(x: 42, y: 180, width: 140, height: 16)
        ]))
        XCTAssertFalse(NativeSentenceContextBuilder.hasTrustedAdjacentLineGeometry([
            CGRect(x: 35, y: 200, width: 180, height: 16),
            CGRect(x: 430, y: 180, width: 160, height: 16)
        ]), "Separate columns cannot be joined")
        XCTAssertFalse(NativeSentenceContextBuilder.hasTrustedAdjacentLineGeometry([
            CGRect(x: 40, y: 250, width: 180, height: 16),
            CGRect(x: 42, y: 180, width: 140, height: 16)
        ]), "A large vertical jump is not an adjacent row")
        XCTAssertFalse(NativeSentenceContextBuilder.hasTrustedAdjacentLineGeometry([
            CGRect(x: 40, y: 220, width: 180, height: 32),
            CGRect(x: 42, y: 200, width: 140, height: 16)
        ]), "A heading-sized row cannot join body text")
    }

    func testTrustedSourceBlockStopsAtHeadingColumnAndBlankRows() throws {
        let source = "Large heading\nBody sentence starts\nand continues here.\n\nOther column"
        let selected = try XCTUnwrap(UTF16Span(range: (source as NSString).range(of: "sentence"), in: source))
        let lineBounds: [CGRect?] = [
            CGRect(x: 40, y: 270, width: 220, height: 32),
            CGRect(x: 42, y: 230, width: 180, height: 16),
            CGRect(x: 44, y: 210, width: 160, height: 16),
            nil,
            CGRect(x: 400, y: 190, width: 150, height: 16)
        ]

        let block = try XCTUnwrap(NativeSentenceContextBuilder.trustedSourceBlock(
            sourceText: source,
            selectedSourceSpans: [selected],
            lineBounds: lineBounds
        ))
        XCTAssertEqual(block.sourceSpan.substring(in: source), "Body sentence starts\nand continues here.")
        XCTAssertEqual(block.sourceSpan.location, (source as NSString).range(of: "Body").location)
        XCTAssertFalse(block.leadingEdgeTruncated)
        XCTAssertFalse(block.trailingEdgeTruncated)

        let selectedBodySentence = try XCTUnwrap(UTF16Span(range: (source as NSString).range(of: "starts"), in: source))
        let context = try XCTUnwrap(NativeSentenceContextBuilder.build(sourceText: source,
                                                                        selectedSourceSpans: [selectedBodySentence],
                                                                        displaySurface: "starts",
                                                                        documentSHA256: "native-heading-boundary",
                                                                        pageIndex: 0,
                                                                        allowsLineBreaks: true,
                                                                        trustedSourceBlock: block))
        XCTAssertEqual(context.text, "Body sentence starts and continues here.")
        XCTAssertEqual(context.kind, .completeSentence)
    }

    func testTrustedTitleBoundaryKeepsCompleteBodySentenceEligible() throws {
        let source = "Large title\nBody starts here.\nBody continues."
        let selected = try XCTUnwrap(UTF16Span(range: (source as NSString).range(of: "starts"), in: source))
        let block = try XCTUnwrap(NativeSentenceContextBuilder.trustedSourceBlock(
            sourceText: source,
            selectedSourceSpans: [selected],
            lineBounds: [
                CGRect(x: 40, y: 270, width: 220, height: 32),
                CGRect(x: 42, y: 230, width: 180, height: 16),
                CGRect(x: 44, y: 210, width: 160, height: 16)
            ]
        ))
        XCTAssertFalse(block.leadingEdgeTruncated)

        let context = try XCTUnwrap(NativeSentenceContextBuilder.build(sourceText: source,
                                                                        selectedSourceSpans: [selected],
                                                                        displaySurface: "starts",
                                                                        documentSHA256: "native-title-body",
                                                                        pageIndex: 0,
                                                                        allowsLineBreaks: true,
                                                                        trustedSourceBlock: block))
        XCTAssertEqual(context.text, "Body starts here.")
        XCTAssertEqual(context.kind, .completeSentence)
    }

    func testEightRowCapMarksOnlySentenceAtTruncatedEdgesAsFragment() throws {
        var lines = Array(repeating: "continues", count: 21)
        lines[0] = "Earlier page text."
        lines[1] = "More page text."
        lines[2] = "First sentence begins"
        lines[10] = "selected first sentence ends."
        lines[11] = "Second sentence begins"
        lines[19] = "selected second sentence ends."
        lines[20] = "Following body sentence."
        let source = lines.joined(separator: "\n")
        let lineBounds = lines.indices.map { index in
            Optional(CGRect(x: 40, y: 600 - CGFloat(index) * 20, width: 180, height: 16))
        }

        let firstSelected = try XCTUnwrap(UTF16Span(range: (source as NSString).range(of: "selected"), in: source))
        let firstBlock = try XCTUnwrap(NativeSentenceContextBuilder.trustedSourceBlock(
            sourceText: source,
            selectedSourceSpans: [firstSelected],
            lineBounds: lineBounds
        ))
        XCTAssertTrue(firstBlock.leadingEdgeTruncated)
        XCTAssertTrue(firstBlock.trailingEdgeTruncated)
        let firstContext = try XCTUnwrap(NativeSentenceContextBuilder.build(sourceText: source,
                                                                             selectedSourceSpans: [firstSelected],
                                                                             displaySurface: "selected",
                                                                             documentSHA256: "native-leading-row-cap",
                                                                             pageIndex: 0,
                                                                             allowsLineBreaks: true,
                                                                             trustedSourceBlock: firstBlock))
        XCTAssertEqual(firstContext.kind, .fragment,
                       "A sentence touching the capped leading edge is not complete evidence")

        let lastSelected = try XCTUnwrap(UTF16Span(range: (source as NSString).range(of: "Second"), in: source))
        let lastBlock = try XCTUnwrap(NativeSentenceContextBuilder.trustedSourceBlock(
            sourceText: source,
            selectedSourceSpans: [lastSelected],
            lineBounds: lineBounds
        ))
        XCTAssertTrue(lastBlock.trailingEdgeTruncated)
        let lastContext = try XCTUnwrap(NativeSentenceContextBuilder.build(sourceText: source,
                                                                            selectedSourceSpans: [lastSelected],
                                                                            displaySurface: "Second",
                                                                            documentSHA256: "native-trailing-row-cap",
                                                                            pageIndex: 0,
                                                                            allowsLineBreaks: true,
                                                                            trustedSourceBlock: lastBlock))
        XCTAssertEqual(lastContext.kind, .fragment,
                       "A sentence touching the capped trailing edge is not complete evidence")
    }

    func testNativeBuilderIntersectsTrustedBlockWithBlankLineParagraphAndKeepsOffsets() throws {
        let source = "Title\n\nBody starts here.\nBody continues?\n\nFooter"
        let selectedRange = (source as NSString).range(of: "starts")
        let selected = try XCTUnwrap(UTF16Span(range: selectedRange, in: source))
        let trustedBlock = TrustedSourceBlock(sourceSpan: UTF16Span(location: 0, length: (source as NSString).length),
                                              leadingEdgeTruncated: false,
                                              trailingEdgeTruncated: false)

        let context = try XCTUnwrap(NativeSentenceContextBuilder.build(sourceText: source,
                                                                        selectedSourceSpans: [selected],
                                                                        displaySurface: "starts",
                                                                        documentSHA256: "native-trusted-intersection",
                                                                        pageIndex: 2,
                                                                        allowsLineBreaks: true,
                                                                        trustedSourceBlock: trustedBlock))
        XCTAssertEqual(context.text, "Body starts here.")
        XCTAssertEqual(context.sourceSpan.substring(in: source), "Body starts here.")
        XCTAssertEqual(context.sourceSpan.location,
                       (source as NSString).range(of: "Body starts here.").location)
        XCTAssertEqual(context.selectedSourceSpans, [selected])
    }

    func testTrustedBlockBoundaryKeepsSentenceAsNonTranslatableFragment() throws {
        let source = "Heading\nBody starts here.\nNext body line continues."
        let bodyRange = (source as NSString).range(of: "Body starts here.\nNext body line continues.")
        let trustedBlock = TrustedSourceBlock(sourceSpan: try XCTUnwrap(UTF16Span(range: bodyRange, in: source)),
                                              leadingEdgeTruncated: true,
                                              trailingEdgeTruncated: false)
        let selected = try XCTUnwrap(UTF16Span(range: (source as NSString).range(of: "starts"), in: source))

        let context = try XCTUnwrap(NativeSentenceContextBuilder.build(sourceText: source,
                                                                        selectedSourceSpans: [selected],
                                                                        displaySurface: "starts",
                                                                        documentSHA256: "native-trusted-fragment",
                                                                        pageIndex: 0,
                                                                        allowsLineBreaks: true,
                                                                        trustedSourceBlock: trustedBlock))
        XCTAssertEqual(context.text, "Body starts here.")
        XCTAssertEqual(context.kind, .fragment)
    }

    func testNativeBuilderUsesNearestBlankLineParagraphAndPreservesPageUTF16Offsets() throws {
        let source = "📘 Heading\r\n\r\nA paragraph has a charge here.\r\n\r\nMore text."
        let ns = source as NSString
        let selectedRange = ns.range(of: "charge")
        let selected = try XCTUnwrap(UTF16Span(range: selectedRange, in: source))
        let paragraphRange = ns.range(of: "A paragraph has a charge here.")

        let context = try XCTUnwrap(NativeSentenceContextBuilder.build(sourceText: source,
                                                                        selectedSourceSpans: [selected],
                                                                        displaySurface: "charge",
                                                                        documentSHA256: "native-paragraph-window",
                                                                        pageIndex: 3,
                                                                        allowsLineBreaks: true))
        XCTAssertEqual(context.text, "A paragraph has a charge here.")
        XCTAssertEqual(context.sourceSpan.location, paragraphRange.location)
        XCTAssertEqual(context.sourceSpan.length, paragraphRange.length)
        XCTAssertEqual(context.sourceSpan.substring(in: source), "A paragraph has a charge here.")
        XCTAssertEqual(context.selectedSourceSpans, [selected])
        XCTAssertEqual(context.selectedDisplaySpans,
                       [UTF16Span(location: selectedRange.location - paragraphRange.location,
                                  length: selectedRange.length)])
    }

    func testNativeBuilderAcceptsFirstAndLastSentenceAtParagraphEdges() throws {
        let source = "Heading.\n\nFirst sentence ends here. Last sentence ends here?\n\nFooter."
        for surface in ["First", "Last"] {
            let selected = try XCTUnwrap(UTF16Span(range: (source as NSString).range(of: surface), in: source))
            let context = try XCTUnwrap(NativeSentenceContextBuilder.build(sourceText: source,
                                                                            selectedSourceSpans: [selected],
                                                                            displaySurface: surface,
                                                                            documentSHA256: "native-paragraph-edge-\(surface)",
                                                                            pageIndex: 0))
            XCTAssertEqual(context.text, surface == "First"
                           ? "First sentence ends here."
                           : "Last sentence ends here?")
        }
    }

    func testNativeBuilderRejectsSentenceCutByUTF16WindowLimit() throws {
        let source = String(repeating: "a", count: 2_400) + " charge appears here."
        let selected = try XCTUnwrap(UTF16Span(range: (source as NSString).range(of: "charge"), in: source))

        XCTAssertNil(NativeSentenceContextBuilder.build(sourceText: source,
                                                        selectedSourceSpans: [selected],
                                                        displaySurface: "charge",
                                                        documentSHA256: "native-window-cut",
                                                        pageIndex: 0),
                   "A sentence that starts before the bounded paragraph window is incomplete")
    }

    func testNativeBuilderKeepsEmojiAndCombiningMarkUTF16Coordinates() throws {
        let source = "😀 Cafe\u{0301} first. 😀 Cafe\u{0301} second."
        let ns = source as NSString
        let selectedRange = ns.range(of: "Cafe\u{0301}", options: .backwards)
        let sentenceRange = ns.range(of: "😀 Cafe\u{0301} second.", options: .backwards)
        let selected = try XCTUnwrap(UTF16Span(range: selectedRange, in: source))

        let context = try XCTUnwrap(NativeSentenceContextBuilder.build(sourceText: source,
                                                                        selectedSourceSpans: [selected],
                                                                        displaySurface: "Cafe\u{0301}",
                                                                        documentSHA256: "native-unicode",
                                                                        pageIndex: 1))
        XCTAssertEqual(context.sourceSpan.location, sentenceRange.location)
        XCTAssertEqual(context.sourceSpan.length, sentenceRange.length)
        XCTAssertEqual(context.selectedDisplaySpans,
                       [UTF16Span(location: selectedRange.location - sentenceRange.location,
                                  length: selectedRange.length)])
        XCTAssertEqual(context.text, "😀 Cafe\u{0301} second.")
    }

    func testNativeBuilderRejectsSelectionDisplayMismatch() throws {
        let source = "A charge appears here."
        let selected = try XCTUnwrap(UTF16Span(range: (source as NSString).range(of: "charge"), in: source))
        XCTAssertNil(NativeSentenceContextBuilder.build(sourceText: source,
                                                        selectedSourceSpans: [selected],
                                                        displaySurface: "change",
                                                        documentSHA256: "native-mismatch",
                                                        pageIndex: 0))
    }

    func testNativeBuilderCropsLongPageAndEnforcesSentenceLimit() throws {
        let prefix = String(repeating: "Earlier. ", count: 600)
        let source = prefix + "Charge second."
        let sourceLength = (source as NSString).length
        XCTAssertGreaterThan(sourceLength, OCRCharacterAligner.maximumUTF16Units)
        let selectedRange = (source as NSString).range(of: "Charge", options: .backwards)
        let selected = try XCTUnwrap(UTF16Span(range: selectedRange, in: source))

        let context = try XCTUnwrap(NativeSentenceContextBuilder.build(sourceText: source,
                                                                        selectedSourceSpans: [selected],
                                                                        displaySurface: "Charge",
                                                                        documentSHA256: "native-long-page",
                                                                        pageIndex: 0))
        XCTAssertEqual(context.text, "Charge second.")
        XCTAssertEqual(context.sourceSpan.location, selectedRange.location)

        let longSentence = "A " + String(repeating: "word ", count: 410) + "end."
        let longSelection = try XCTUnwrap(UTF16Span(range: (longSentence as NSString).range(of: "word"),
                                                   in: longSentence))
        XCTAssertNil(NativeSentenceContextBuilder.build(sourceText: longSentence,
                                                        selectedSourceSpans: [longSelection],
                                                        displaySurface: "word",
                                                        documentSHA256: "native-long-sentence",
                                                        pageIndex: 0))
    }
}

private extension UTF16Span {
    func adding(offset: Int) -> UTF16Span {
        UTF16Span(location: location + offset, length: length)
    }
}
