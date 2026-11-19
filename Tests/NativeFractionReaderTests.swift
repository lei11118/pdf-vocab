import PDFKit
import UIKit
import XCTest
@testable import PdfVocab

@MainActor
final class NativeFractionReaderTests: XCTestCase {
    #if DEBUG
    func testReaderAuditFractionKeepsItsRuleAndGlyphsAfterPDFRewrite() throws {
        let document = try XCTUnwrap(PDFDocument(data: HumanReadingAuditFixture.nativePDF()))
        let page = try XCTUnwrap(document.page(at: 0))
        let scan = PDFTextLayout.scan(on: page)
        let neighbors = scan.glyphs.filter { $0.rect.midX > 365 && $0.rect.midY < 265 }
            .map { "\($0.text) rect=\($0.rect) base=\($0.baseline)" }
        let rules = scan.horizontalRules.map { "\($0.start) \($0.end) width=\($0.lineWidth)" }
        let fraction = try XCTUnwrap(NativeFractionLayout.detect(in: scan).first,
                                     "PDF glyphs: \(neighbors), PDF rules: \(rules)")
        let reading = try XCTUnwrap(NativeFractionReadingSelection.build(fraction: fraction, on: page),
                                    "Detected region \(fraction.region), glyphs \(fraction.orderedGlyphs.map(\.sourceIndex))")
        XCTAssertEqual(reading.whole.readingResult?.latex, "\\frac{73}{91}")
    }
    #endif

}
