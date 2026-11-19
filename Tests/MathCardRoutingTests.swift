import XCTest
@testable import PdfVocab

final class MathCardRoutingTests: XCTestCase {
    func testSelectedSymbolKeepsItsVerbatimSource() {
        let variable = MathSymbolReading.detail("E")
        XCTAssertEqual(variable.sourceText, "E")
        XCTAssertEqual(variable.status, .parsedText)
        XCTAssertEqual(variable.latex, "E")
        XCTAssertTrue(variable.explanation.contains("变量"))

        let digit = MathSymbolReading.detail("5")
        XCTAssertEqual(digit.sourceText, "5")
        XCTAssertEqual(digit.ast?.kind, .number)

        let superscript = MathSymbolReading.detail("²")
        XCTAssertEqual(superscript.sourceText, "²")
        XCTAssertEqual(superscript.latex, "{}^{2}")
    }

    func testIncompleteAndUnknownSymbolsKeepTheSourceCropWithoutInventingLatex() {
        for source in ["√", "◌"] {
            let detail = MathSymbolReading.detail(source)
            XCTAssertEqual(detail.sourceText, source)
            XCTAssertEqual(detail.status, .needsReview)
            XCTAssertNil(detail.latex)
        }
    }
}
