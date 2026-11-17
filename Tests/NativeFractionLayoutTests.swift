import XCTest
import UIKit
@testable import PdfVocab

@MainActor
final class NativeFractionLayoutTests: XCTestCase {
    private let barY: CGFloat = 684.75
    private let lineWidth: CGFloat = 0.625

    func testDetectsOverlappingGlyphBoundsAndBaselineMayFallBelowRule() throws {
        let rule = PDFTextLayout.HorizontalRule(start: CGPoint(x: 317.0666, y: 684.75),
                                                end: CGPoint(x: 323.3996, y: 684.75),
                                                lineWidth: 0.625)
        let upper = glyph("n", x: 318.1, y: 683.5, width: 4.2, height: 5,
                          baselineY: 684.5)
        let lower = glyph("d", x: 318.1, y: 679.125, width: 4.2, height: 5,
                          baselineY: 681.3)
        let overlap = upper.rect.intersection(lower.rect)
        XCTAssertEqual(overlap.height, 0.625, accuracy: 0.001)
        XCTAssertLessThan(upper.baseline.y, barY)

        let fraction = try XCTUnwrap(NativeFractionLayout.detect(
            in: PDFTextLayout.PageScan(glyphs: [upper, lower], horizontalRules: [rule])).first)

        XCTAssertEqual(fraction.rule.start.x, 317.0666, accuracy: 0.001)
        XCTAssertEqual(fraction.orderedGlyphs.map(\.glyph.text), ["n", "d"])
        XCTAssertEqual(fraction.numerator.glyphs.map(\.sourceIndex), [0])
        XCTAssertEqual(fraction.denominator.glyphs.map(\.sourceIndex), [1])
    }

    func testAdjacentFractionsKeepTheirOriginalGlyphIdentityAndMultiGlyphRows() throws {
        let firstRule = rule(x: 20, length: 6)
        let secondRule = rule(x: 40, length: 6)
        let glyphs = [
            glyph("a", x: 21.0, y: 683.5, width: 1.4, height: 5, baselineY: 684.5), // 0, first numerator
            glyph("u", x: 41.0, y: 683.5, width: 1.4, height: 5, baselineY: 684.5), // 1, second numerator
            glyph("b", x: 21.0, y: 679.125, width: 1.4, height: 5, baselineY: 681.3), // 2, first denominator
            glyph("v", x: 41.0, y: 679.125, width: 1.4, height: 5, baselineY: 681.3), // 3, second denominator
            glyph("+", x: 22.7, y: 683.5, width: 1.4, height: 5, baselineY: 684.5), // 4
            glyph("-", x: 42.7, y: 683.5, width: 1.4, height: 5, baselineY: 684.5), // 5
            glyph("c", x: 22.7, y: 679.125, width: 1.4, height: 5, baselineY: 681.3), // 6
            glyph("w", x: 42.7, y: 679.125, width: 1.4, height: 5, baselineY: 681.3), // 7
            glyph("d", x: 24.4, y: 683.5, width: 1.4, height: 5, baselineY: 684.5), // 8
            glyph("x", x: 44.4, y: 683.5, width: 1.4, height: 5, baselineY: 684.5), // 9
            glyph("e", x: 24.4, y: 679.125, width: 1.4, height: 5, baselineY: 681.3), // 10
            glyph("y", x: 44.4, y: 679.125, width: 1.4, height: 5, baselineY: 681.3)  // 11
        ]
        let fractions = NativeFractionLayout.detect(
            in: PDFTextLayout.PageScan(glyphs: glyphs,
                                       horizontalRules: [firstRule, secondRule]))

        XCTAssertEqual(fractions.count, 2)
        guard fractions.count == 2 else { return }
        let first = fractions[0]
        let second = fractions[1]
        XCTAssertEqual(first.numerator.glyphs.map(\.sourceIndex), [0, 4, 8])
        XCTAssertEqual(first.denominator.glyphs.map(\.sourceIndex), [2, 6, 10])
        XCTAssertEqual(second.numerator.glyphs.map(\.sourceIndex), [1, 5, 9])
        XCTAssertEqual(second.denominator.glyphs.map(\.sourceIndex), [3, 7, 11])
        XCTAssertEqual(first.orderedGlyphs.map(\.glyph.text), ["a", "+", "d", "b", "c", "e"])
        XCTAssertEqual(second.orderedGlyphs.map(\.glyph.text), ["u", "-", "x", "v", "w", "y"])
    }

    func testRejectsMissingSideCrowdedRowsAndWideTableRule() {
        let narrowRule = rule(x: 20, length: 6)
        let upper = glyph("n", x: 21, y: 683.5, width: 4.2, height: 5, baselineY: 684.5)
        let lower = glyph("d", x: 21, y: 679.125, width: 4.2, height: 5, baselineY: 681.3)

        XCTAssertTrue(NativeFractionLayout.detect(
            in: PDFTextLayout.PageScan(glyphs: [upper], horizontalRules: [narrowRule])).isEmpty)

        let crowdedUpper = glyph("s", x: 21, y: 687, width: 4.2, height: 5, baselineY: 687.5)
        XCTAssertTrue(NativeFractionLayout.detect(
            in: PDFTextLayout.PageScan(glyphs: [upper, crowdedUpper, lower],
                                       horizontalRules: [narrowRule])).isEmpty)

        let tableRule = rule(x: 0, length: 120)
        let centeredUpper = glyph("n", x: 58, y: 683.5, width: 4.2, height: 5, baselineY: 684.5)
        let centeredLower = glyph("d", x: 58, y: 679.125, width: 4.2, height: 5, baselineY: 681.3)
        XCTAssertTrue(NativeFractionLayout.detect(
            in: PDFTextLayout.PageScan(glyphs: [centeredUpper, centeredLower],
                                       horizontalRules: [tableRule])).isEmpty)
    }

    func testHitTestDistinguishesGlyphRowRuleAndOutsideBounds() throws {
        let rule = rule(x: 20, length: 6)
        let glyphs = [
            glyph("a", x: 20.4, y: 683.5, width: 1.4, height: 5, baselineY: 684.5),
            glyph("+", x: 22.2, y: 683.5, width: 1.4, height: 5, baselineY: 684.5),
            glyph("b", x: 24.0, y: 683.5, width: 1.4, height: 5, baselineY: 684.5),
            glyph("c", x: 20.4, y: 679.125, width: 1.4, height: 5, baselineY: 681.3),
            glyph("-", x: 22.2, y: 679.125, width: 1.4, height: 5, baselineY: 681.3),
            glyph("d", x: 24.0, y: 679.125, width: 1.4, height: 5, baselineY: 681.3)
        ]
        let fraction = try XCTUnwrap(NativeFractionLayout.detect(
            in: PDFTextLayout.PageScan(glyphs: glyphs, horizontalRules: [rule])).first)

        guard case let .glyph(sourceIndex, position)? = fraction.hitTest(CGPoint(x: 21.1, y: 686)) else {
            return XCTFail("Expected a leaf glyph hit")
        }
        XCTAssertEqual(sourceIndex, 0)
        XCTAssertEqual(position, .numerator)

        guard case let .row(rowPosition)? = fraction.hitTest(CGPoint(x: 22.0, y: 686)) else {
            return XCTFail("Expected a numerator row hit in the inter-glyph gap")
        }
        XCTAssertEqual(rowPosition, .numerator)

        guard case .rule? = fraction.hitTest(CGPoint(x: 23, y: barY)) else {
            return XCTFail("Expected a rule hit")
        }
        XCTAssertNil(fraction.hitTest(CGPoint(x: 10, y: 686)))
    }

    func testFarSameColumnGlyphsDoNotExhaustTheNearRuleLimit() {
        let rule = rule(x: 20, length: 6)
        let upper = glyph("n", x: 21, y: 683.5, width: 4.2, height: 5, baselineY: 684.5)
        let lower = glyph("d", x: 21, y: 679.125, width: 4.2, height: 5, baselineY: 681.3)
        let farGlyphs = (0..<70).map { index in
            let y = CGFloat(700 + index * 6)
            return glyph("q", x: 21, y: y, width: 4.2, height: 5, baselineY: y + 1)
        }

        let fractions = NativeFractionLayout.detect(
            in: PDFTextLayout.PageScan(glyphs: [upper, lower] + farGlyphs,
                                       horizontalRules: [rule]))

        XCTAssertEqual(fractions.count, 1)
    }

    private func rule(x: CGFloat, length: CGFloat) -> PDFTextLayout.HorizontalRule {
        PDFTextLayout.HorizontalRule(start: CGPoint(x: x, y: barY),
                                     end: CGPoint(x: x + length, y: barY),
                                     lineWidth: lineWidth)
    }

    private func glyph(_ text: String,
                       x: CGFloat,
                       y: CGFloat,
                       width: CGFloat,
                       height: CGFloat,
                       baselineY: CGFloat) -> PDFTextLayout.Glyph {
        PDFTextLayout.Glyph(text: text,
                            rect: CGRect(x: x, y: y, width: width, height: height),
                            baseline: CGPoint(x: x, y: baselineY))
    }
}
