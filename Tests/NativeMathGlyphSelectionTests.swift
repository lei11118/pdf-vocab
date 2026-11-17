import PDFKit
import UIKit
import XCTest
@testable import PdfVocab

@MainActor
final class NativeMathGlyphSelectionTests: XCTestCase {
    func testMapsRepeatedStemsToExactDiscontiguousNumeratorAndDenominator() throws {
        let (document, page) = try makeFractionPage()
        XCTAssertEqual(document.pageCount, 1)
        let source = try XCTUnwrap(page.string) as NSString
        let numeratorCandidate = source.range(of: "x+1")
        let denominatorCandidate = source.range(of: "x+2")
        let numeratorRange = try XCTUnwrap(numeratorCandidate.location == NSNotFound ? nil : numeratorCandidate)
        let denominatorRange = try XCTUnwrap(denominatorCandidate.location == NSNotFound ? nil : denominatorCandidate)

        let layoutGlyphs = PDFTextLayout.glyphs(on: page)
        let numeratorGlyphs = try sourceGlyphs(in: numeratorRange, source: source,
                                               layoutGlyphs: layoutGlyphs, page: page)
        let denominatorGlyphs = try sourceGlyphs(in: denominatorRange, source: source,
                                                 layoutGlyphs: layoutGlyphs, page: page)
        XCTAssertEqual(numeratorGlyphs.map(\.text).joined(), "x+1")
        XCTAssertEqual(denominatorGlyphs.map(\.text).joined(), "x+2")

        let firstGlyphRange = NSRange(location: numeratorRange.location, length: 1)
        let firstGlyph = try XCTUnwrap(page.selection(for: firstGlyphRange))
        let firstGlyphBounds = firstGlyph.bounds(for: page)
        let characterIndex = page.characterIndex(at: CGPoint(x: firstGlyphBounds.midX,
                                                              y: firstGlyphBounds.midY))
        XCTAssertNotEqual(characterIndex, NSNotFound)

        let mapping = try XCTUnwrap(NativeMathGlyphSelection.map(
            numeratorGlyphs + denominatorGlyphs,
            on: page,
            anchoredAt: characterIndex))

        XCTAssertEqual(mapping.entries.map(\.glyphIndex), Array(0..<6))
        XCTAssertEqual(mapping.ranges, [
            NSRange(location: numeratorRange.location, length: 1),
            NSRange(location: numeratorRange.location + 1, length: 1),
            NSRange(location: numeratorRange.location + 2, length: 1),
            NSRange(location: denominatorRange.location, length: 1),
            NSRange(location: denominatorRange.location + 1, length: 1),
            NSRange(location: denominatorRange.location + 2, length: 1)
        ])

        let numeratorMerge = try XCTUnwrap(NativeMathGlyphSelection.merge(
            Array(mapping.entries.prefix(3)), on: page))
        XCTAssertEqual(numeratorMerge.ranges, Array(mapping.ranges.prefix(3)))
        XCTAssertEqual(coalesced((0..<numeratorMerge.selection.numberOfTextRanges(on: page))
            .map { numeratorMerge.selection.range(at: $0, on: page) }), [numeratorRange])

        let mergedRanges = (0..<mapping.mergedSelection.numberOfTextRanges(on: page))
            .map { mapping.mergedSelection.range(at: $0, on: page) }
        XCTAssertEqual(coalesced(mergedRanges), [numeratorRange, denominatorRange]
            .sorted { $0.location < $1.location })

        let repeatedStemCandidate = source.range(of: "x+x")
        let repeatedStemRange = try XCTUnwrap(repeatedStemCandidate.location == NSNotFound ? nil : repeatedStemCandidate)
        XCTAssertTrue(mergedRanges.allSatisfy { NSIntersectionRange($0, repeatedStemRange).length == 0 },
                      "The merged selection must contain only the mapped numerator and denominator glyphs")
    }

    func testRejectsSourceTextMismatchAndImpossiblePageGeometry() throws {
        let (document, page) = try makeFractionPage()
        XCTAssertEqual(document.pageCount, 1)
        let source = try XCTUnwrap(page.string) as NSString
        let numeratorCandidate = source.range(of: "x+1")
        let numeratorRange = try XCTUnwrap(numeratorCandidate.location == NSNotFound ? nil : numeratorCandidate)
        let firstRange = NSRange(location: numeratorRange.location, length: 1)
        let selection = try XCTUnwrap(page.selection(for: firstRange))
        let bounds = selection.bounds(for: page)
        let anchor = page.characterIndex(at: CGPoint(x: bounds.midX, y: bounds.midY))
        let nativeGlyph = try XCTUnwrap(sourceGlyphs(in: firstRange, source: source,
                                                     layoutGlyphs: PDFTextLayout.glyphs(on: page),
                                                     page: page).first)

        let mismatch = PDFTextLayout.Glyph(text: "y", rect: nativeGlyph.rect,
                                           baseline: nativeGlyph.baseline)
        XCTAssertNil(NativeMathGlyphSelection.map([mismatch], on: page, anchoredAt: anchor))
        XCTAssertNil(NativeMathGlyphSelection.map([nativeGlyph, nativeGlyph], on: page, anchoredAt: anchor),
                     "One page glyph cannot satisfy two entries")

        let outsidePage = PDFTextLayout.Glyph(text: nativeGlyph.text,
                                              rect: CGRect(x: -10_000, y: -10_000,
                                                           width: nativeGlyph.rect.width,
                                                           height: nativeGlyph.rect.height),
                                              baseline: nativeGlyph.baseline)
        XCTAssertNil(NativeMathGlyphSelection.map([outsidePage], on: page, anchoredAt: anchor))
    }

    private func makeFractionPage() throws -> (PDFDocument, PDFPage) {
        let bounds = CGRect(x: 0, y: 0, width: 420, height: 340)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("x+x" as NSString).draw(at: CGPoint(x: 48, y: 270),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            ("x+1;" as NSString).draw(at: CGPoint(x: 170, y: 115),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 26)])
            ("x+2;" as NSString).draw(at: CGPoint(x: 170, y: 195),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 26)])
            context.cgContext.setLineWidth(1)
            context.cgContext.move(to: CGPoint(x: 165, y: 168))
            context.cgContext.addLine(to: CGPoint(x: 235, y: 168))
            context.cgContext.strokePath()
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        return (document, try XCTUnwrap(document.page(at: 0)))
    }

    private func sourceGlyphs(in range: NSRange,
                              source: NSString,
                              layoutGlyphs: [PDFTextLayout.Glyph],
                              page: PDFPage) throws -> [PDFTextLayout.Glyph] {
        var result: [PDFTextLayout.Glyph] = []
        var cursor = range.location
        let end = NSMaxRange(range)
        while cursor < end {
            let composed = source.rangeOfComposedCharacterSequence(at: cursor)
            XCTAssertLessThanOrEqual(NSMaxRange(composed), end)
            let expected = source.substring(with: composed).precomposedStringWithCanonicalMapping
            let selection = try XCTUnwrap(page.selection(for: composed))
            let bounds = selection.bounds(for: page).insetBy(dx: -2, dy: -2)
            let matches = layoutGlyphs.filter {
                $0.text.precomposedStringWithCanonicalMapping == expected && $0.rect.intersects(bounds)
            }
            XCTAssertEqual(matches.count, 1, "Synthetic source glyph \(expected) must have one matching layout glyph")
            result.append(try XCTUnwrap(matches.first))
            cursor = NSMaxRange(composed)
        }
        return result
    }

    private func coalesced(_ ranges: [NSRange]) -> [NSRange] {
        let ordered = ranges.sorted { $0.location < $1.location }
        var result: [NSRange] = []
        for range in ordered {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSRange(location: last.location,
                                                   length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
