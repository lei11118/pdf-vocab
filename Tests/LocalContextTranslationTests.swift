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

    private func context(_ text: String, selected: NSRange) -> SentenceContext {
        let selection = UTF16Span(location: selected.location, length: selected.length)
        let whole = UTF16Span(location: 0, length: text.utf16.count)
        return SentenceContext(documentSHA256: "fixture", pageIndex: 0, blockID: "line",
                               text: text, displayLineText: text, displaySentenceText: text,
                               sourceSpan: whole, displaySpan: whole, selectedSourceSpans: [selection],
                               selectedDisplaySpans: [selection], kind: .completeSentence)
    }
}
