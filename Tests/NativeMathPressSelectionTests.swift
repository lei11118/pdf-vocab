import PDFKit
import UIKit
import XCTest
@testable import PdfVocab

@MainActor
final class NativeMathLineTests: XCTestCase {
    func testNativeMathLineExpandsSpacedLineFromRightmostGlyph() throws {
        let bounds = CGRect(x: 0, y: 0, width: 360, height: 240)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("F = ma" as NSString).draw(at: CGPoint(x: 45, y: 135),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 30)])
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let source = try XCTUnwrap(page.string) as NSString
        let formulaRange = try XCTUnwrap(source.range(of: "F = ma").location == NSNotFound
            ? nil : source.range(of: "F = ma"))
        let aRange = try XCTUnwrap(source.range(of: "a", options: [], range: formulaRange).location == NSNotFound
            ? nil : source.range(of: "a", options: [], range: formulaRange))
        let glyph = try XCTUnwrap(page.selection(for: aRange))
        let rect = glyph.bounds(for: page)

        let target = try XCTUnwrap(SelectionGeometry.nativeMathLine(
            on: page, at: CGPoint(x: rect.midX, y: rect.midY)),
            "A right-edge hit must recover the complete spaced formula from verified neighboring glyph geometry")
        XCTAssertEqual(target.lineRange, formulaRange,
                       "The leftward scan must preserve every operator and intervening space")
        XCTAssertEqual(source.substring(with: target.lineRange), "F = ma")
    }

    func testNativeMathLineRejectsProseLongWordsAndStackedText() throws {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 360)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("The answer is x=1." as NSString).draw(at: CGPoint(x: 35, y: 290),
                                                    withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            ("force = mass × acceleration" as NSString).draw(at: CGPoint(x: 35, y: 230),
                                                             withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            ("x =" as NSString).draw(at: CGPoint(x: 35, y: 160),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            ("1" as NSString).draw(at: CGPoint(x: 95, y: 174),
                                   withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            ("2" as NSString).draw(at: CGPoint(x: 95, y: 142),
                                   withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            context.cgContext.fill(CGRect(x: 90, y: 165, width: 22, height: 1))
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let source = try XCTUnwrap(page.string) as NSString

        for token in ["x=1", "force", "1", "2"] {
            let range = source.range(of: token)
            XCTAssertNotEqual(range.location, NSNotFound, "Synthetic fixture includes \(token)")
            let selection = try XCTUnwrap(page.selection(for: range))
            let rect = selection.bounds(for: page)
            let target = SelectionGeometry.nativeMathLine(
                on: page, at: CGPoint(x: rect.midX, y: rect.midY))
            let details = target.map {
                "line=\(NSStringFromRange($0.lineRange))"
            } ?? "nil"
            XCTAssertNil(target,
                         "Prose, long variable names, and stacked text do not qualify as one native formula line: \(token); target=\(details)")
        }

        let stackedLine = source.range(of: "x =")
        XCTAssertNotEqual(stackedLine.location, NSNotFound)
        let xGlyph = try XCTUnwrap(page.selection(for: NSRange(location: stackedLine.location, length: 1)))
        let xRect = xGlyph.bounds(for: page)
        let xTarget = SelectionGeometry.nativeMathLine(
            on: page, at: CGPoint(x: xRect.midX, y: xRect.midY))
        XCTAssertNil(xTarget,
                     "Starting from the equation's x must also reject the nearby stacked fraction; got \(xTarget.map { NSStringFromRange($0.lineRange) } ?? "nil")")
    }

    func testNativeMathTargetHandlesLongTextPagesAndDecimalFormulaLine() throws {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 600)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            for line in 0..<8 {
                ("Chapter (line) explains the surrounding physical model in ordinary prose." as NSString)
                    .draw(at: CGPoint(x: 35, y: 530 - CGFloat(line) * 34),
                          withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
            }
            ("8.86/9.50" as NSString).draw(at: CGPoint(x: 80, y: 90),
                                          withAttributes: [.font: UIFont.systemFont(ofSize: 26)])
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let source = try XCTUnwrap(page.string) as NSString
        XCTAssertGreaterThan(source.length, 256, "The page source is larger than a single short fixture")
        let formulaRange = try XCTUnwrap(source.range(of: "8.86/9.50").location == NSNotFound
            ? nil : source.range(of: "8.86/9.50"))
        let formula = try XCTUnwrap(page.selection(for: formulaRange))
        let rect = formula.bounds(for: page)

        let target = SelectionGeometry.nativeMathLine(
            on: page, at: CGPoint(x: rect.midX, y: rect.midY))
        let targetDetails = target.map {
            "line=\(NSStringFromRange($0.lineRange)) text=\($0.lineSelection.string ?? "nil")"
        } ?? "nil"
        XCTAssertEqual(target?.lineSelection.string?.trimmingCharacters(in: .whitespacesAndNewlines), "8.86/9.50",
                       "Decimal points between digits remain part of a compact math line; target=\(targetDetails)")
    }
}
