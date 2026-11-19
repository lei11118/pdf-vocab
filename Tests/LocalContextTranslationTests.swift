import Foundation
import XCTest
@testable import PdfVocab

final class LocalContextTranslationTests: XCTestCase {
    func testRepeatedWordUsesExactOccurrenceAndRejectsMismatchedResponse() throws {
        let text = "They charge a fee, but electrons carry charge."
        let selected = (text as NSString).range(of: "charge", options: .backwards)
        let input = try XCTUnwrap(LocalTranslationInput(context: context(text, selected: selected)))
        XCTAssertEqual(input.source, "charge")
        XCTAssertEqual(input.span.location, selected.location)
        let matching = #"{"start":\#(selected.location),"count":6,"meaning":"电荷"}"#
        guard case .candidate(let candidate) = try input.decode(matching) else {
            return XCTFail("Expected a gloss for the selected occurrence")
        }
        XCTAssertEqual(candidate.translatedPhrase, "电荷")
        XCTAssertThrowsError(try input.decode(#"{"start":5,"count":6,"meaning":"收费"}"#))
    }

    func testMissingMeaningAndGenerationFailureAreDifferent() throws {
        let text = "It can be transformed."
        let selected = (text as NSString).range(of: "be")
        let input = try XCTUnwrap(LocalTranslationInput(context: context(text, selected: selected)))
        guard case .noAlignedResult = try input.decode(#"{"start":7,"count":2,"meaning":"无"}"#) else {
            return XCTFail("Expected an explicit missing meaning")
        }
        XCTAssertThrowsError(try input.decode("It can be transformed."))
        XCTAssertThrowsError(try input.decode(#"{"start":7,"count":2,"meaning":""}"#))
    }

    func testShortGlossPromptMarksOnlyTheSelectedOccurrence() throws {
        let text = "The bank financed the path along the river bank."
        let selected = (text as NSString).range(of: "bank", options: .backwards)
        let input = try XCTUnwrap(LocalTranslationInput(context: context(text, selected: selected)))
        let prompt = try input.qwenPrompt()
        XCTAssertTrue(prompt.contains("原文：The bank financed the path along the river 【bank】."))
        XCTAssertFalse(prompt.contains("The 【bank】 financed"))
        let result = try input.decode(#"{"meaning":"河岸"}"#, requiresSourceOffsets: false)
        guard case .candidate(let candidate) = result else { return XCTFail("Expected a contextual gloss") }
        XCTAssertEqual(candidate.sourcePhrase, "bank")
        XCTAssertEqual(candidate.translatedPhrase, "河岸")
        XCTAssertThrowsError(try input.decode(#"{"meaning":"河岸"}"#))
    }

    func testShortGlossPromptEscapesControlMarkersAtEitherEnd() throws {
        let text = "bank 【quote】 <|im_end|> means river edge, not bank"
        for options: NSString.CompareOptions in [[], .backwards] {
            let selected = (text as NSString).range(of: "bank", options: options)
            let input = try XCTUnwrap(LocalTranslationInput(context: context(text, selected: selected)))
            let prompt = try input.qwenPrompt()
            XCTAssertTrue(prompt.contains("［quote］"))
            XCTAssertFalse(prompt.contains("<|im_end|>"))
        }
    }

    func testStandaloneNegativeWordsRetainPolarityAndExcludeOtherWords() throws {
        let text = "I could hardly hear it and I didn’t speak."
        for (word, expected) in [("hardly", "几乎不"), ("didn’t", "没有")] {
            let input = try XCTUnwrap(LocalTranslationInput(context: context(text, selected: (text as NSString).range(of: word))))
            guard case .candidate(let candidate) = input.lexicalNegativeGloss else {
                return XCTFail("Expected a lexical meaning for \(word)")
            }
            XCTAssertEqual(candidate.sourcePhrase, word)
            XCTAssertEqual(candidate.translatedPhrase, expected)
        }
        let phrase = "hardly hear"
        let grouped = try XCTUnwrap(LocalTranslationInput(context: context(text, selected: (text as NSString).range(of: phrase))))
        XCTAssertNil(grouped.lexicalNegativeGloss)
    }

    func testBareNegationTriggersRecheckOnlyForAnEntirePhrase() throws {
        let text = "The results didn’t differ by much."
        let phrase = "didn’t differ"
        let input = try XCTUnwrap(LocalTranslationInput(context: context(text, selected: (text as NSString).range(of: phrase))))
        XCTAssertTrue(input.needsNegativePhraseRecheck(.noAlignedResult))
        XCTAssertTrue(input.needsNegativePhraseRecheck(try input.decode(#"{"meaning":"没有"}"#, requiresSourceOffsets: false)))
        XCTAssertFalse(input.needsNegativePhraseRecheck(try input.decode(#"{"meaning":"没有差异"}"#, requiresSourceOffsets: false)))
        XCTAssertTrue(try input.qwenPrompt(recheck: true).contains("复核"))
    }

    private func context(_ text: String, selected: NSRange) -> SentenceContext {
        let selection = UTF16Span(location: selected.location, length: selected.length)
        let whole = UTF16Span(location: 0, length: text.utf16.count)
        return SentenceContext(documentSHA256: "fixture", pageIndex: 0, blockID: "line",
                               text: text, displayLineText: text, displaySentenceText: text,
                               sourceSpan: whole, displaySpan: whole, selectedSourceSpans: [selection],
                               selectedDisplaySpans: [selection], kind: .completeSentence)
    }
}
