import XCTest
@testable import PdfVocab

final class MathCardRoutingTests: XCTestCase {
    private let formula = "E=mc²"

    func testMasterAndMathSwitchesGateOnlyTheMathRoute() {
        XCTAssertNil(MathCardRouting.resolve(sourceText: formula,
                                             contextReadingEnabled: false,
                                             mathEnabled: true))
        XCTAssertNil(MathCardRouting.resolve(sourceText: formula,
                                             contextReadingEnabled: true,
                                             mathEnabled: false))
        XCTAssertNil(MathCardRouting.resolve(sourceText: "function",
                                             contextReadingEnabled: true,
                                             mathEnabled: true),
                      "Ordinary words stay on the existing dictionary route")
    }

    func testResolvedMathCreatesEquatableMathCardContent() throws {
        let result = try XCTUnwrap(MathCardRouting.resolve(sourceText: formula,
                                                           contextReadingEnabled: true,
                                                           mathEnabled: true))
        XCTAssertEqual(result.sourceText, formula)
        XCTAssertEqual(result.status, .parsedText)
        XCTAssertEqual(ReaderCardContent.math(result), .math(result))
    }

    func testStaleContextSelectionCannotRouteToMathCard() {
        XCTAssertNil(MathCardRouting.resolve(sourceText: formula,
                                             contextReadingEnabled: true,
                                             mathEnabled: true,
                                             contextualSelectionIsCurrent: false))
    }

    func testTruncatedReaderDisplayCannotBeMarkedAsParsedMath() {
        let truncated = String(repeating: "x^2+", count: 120) + "…"
        XCTAssertGreaterThan(truncated.count, 400)
        XCTAssertNil(MathCardRouting.resolve(sourceText: truncated,
                                             contextReadingEnabled: true,
                                             mathEnabled: true),
                      "The coordinator's truncated display string cannot be treated as complete formula text")
    }
}
