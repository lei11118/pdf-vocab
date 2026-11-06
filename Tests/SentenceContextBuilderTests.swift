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
}

private extension UTF16Span {
    func adding(offset: Int) -> UTF16Span {
        UTF16Span(location: location + offset, length: length)
    }
}
