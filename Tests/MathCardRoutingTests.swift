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

    func testMathDetailKeepsSingleDigitsAndVariablesOnTheMathRoute() throws {
        XCTAssertNil(MathCardRouting.resolve(sourceText: "E",
                                             contextReadingEnabled: true,
                                             mathEnabled: true),
                     "An ordinary single-letter selection is not reclassified without math-detail intent")

        let variable = try XCTUnwrap(MathCardRouting.resolve(sourceText: "E",
                                                              contextReadingEnabled: true,
                                                              mathEnabled: true,
                                                              isMathDetail: true))
        XCTAssertEqual(variable.sourceText, "E")
        XCTAssertEqual(variable.status, .parsedText)
        XCTAssertEqual(variable.latex, "E")
        XCTAssertTrue(variable.explanation.contains("变量"))

        let digit = try XCTUnwrap(MathCardRouting.resolve(sourceText: "5",
                                                          contextReadingEnabled: true,
                                                          mathEnabled: true,
                                                          isMathDetail: true))
        XCTAssertEqual(digit.sourceText, "5")
        XCTAssertEqual(digit.ast?.kind, .number)

        let superscript = try XCTUnwrap(MathCardRouting.resolve(sourceText: "²",
                                                                contextReadingEnabled: true,
                                                                mathEnabled: true,
                                                                isMathDetail: true))
        XCTAssertEqual(superscript.sourceText, "²", "The selected glyph stays available verbatim")
        XCTAssertEqual(superscript.latex, "{}^{2}", "The standalone superscript has a safe display base")

        let radical = try XCTUnwrap(MathCardRouting.resolve(sourceText: "√",
                                                            contextReadingEnabled: true,
                                                            mathEnabled: true,
                                                            isMathDetail: true))
        XCTAssertEqual(radical.sourceText, "√")
        XCTAssertEqual(radical.status, .needsReview)
        XCTAssertNil(radical.latex, "A bare radical never reaches the renderer as an incomplete \\sqrt command")
    }

    func testUnknownMathDetailStaysOnMathCardWithoutInventedLatex() throws {
        let result = try XCTUnwrap(MathCardRouting.resolve(sourceText: "◌",
                                                           contextReadingEnabled: true,
                                                           mathEnabled: true,
                                                           isMathDetail: true))
        XCTAssertEqual(result.sourceText, "◌")
        XCTAssertEqual(result.status, .needsReview)
        XCTAssertNil(result.latex)
        XCTAssertNil(MathCardRouting.resolve(sourceText: "◌",
                                             contextReadingEnabled: true,
                                             mathEnabled: true),
                     "Only an explicit native math-detail selection bypasses ordinary dictionary routing")
    }
}
