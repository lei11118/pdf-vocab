import PDFKit
import UIKit
import XCTest
@testable import PdfVocab

@MainActor
final class PDFMathRuleGeometryTests: XCTestCase {
    func testScanReportsHorizontalStrokesInPageCoordinatesAndRestoresGraphicsState() throws {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { renderer in
            renderer.beginPage()
            let context = renderer.cgContext

            context.setLineWidth(0.625)
            context.saveGState()
            context.translateBy(x: 20, y: 30)
            context.scaleBy(x: 2, y: 2)
            context.move(to: CGPoint(x: 10, y: 10))
            context.addLine(to: CGPoint(x: 20, y: 10))
            context.strokePath()
            context.restoreGState()

            context.move(to: CGPoint(x: 5, y: 60))
            context.addLine(to: CGPoint(x: 15, y: 60))
            context.strokePath()
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let scan = PDFTextLayout.scan(on: page)

        XCTAssertEqual(scan.horizontalRules.count, 2)
        let first = try XCTUnwrap(scan.horizontalRules.first)
        let second = try XCTUnwrap(scan.horizontalRules.dropFirst().first)
        XCTAssertEqual(first.start.x, 40, accuracy: 0.02)
        XCTAssertEqual(first.start.y, 150, accuracy: 0.02)
        XCTAssertEqual(first.end.x, 60, accuracy: 0.02)
        XCTAssertEqual(first.lineWidth, 1.25, accuracy: 0.02)
        XCTAssertEqual(second.start.x, 5, accuracy: 0.02)
        XCTAssertEqual(second.start.y, 140, accuracy: 0.02)
        XCTAssertEqual(second.end.x, 15, accuracy: 0.02)
        XCTAssertEqual(second.lineWidth, 0.625, accuracy: 0.02)
        XCTAssertTrue(scan.horizontalRules.allSatisfy { $0.start.y.isFinite && $0.end.y.isFinite })
    }

    func testScanRejectsDiagonalCurvedAndCancelledPaths() throws {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { renderer in
            renderer.beginPage()
            let context = renderer.cgContext
            context.setLineWidth(1)

            context.move(to: CGPoint(x: 10, y: 10))
            context.addLine(to: CGPoint(x: 40, y: 25))
            context.strokePath()

            context.move(to: CGPoint(x: 10, y: 40))
            context.addCurve(to: CGPoint(x: 50, y: 40),
                             control1: CGPoint(x: 20, y: 10),
                             control2: CGPoint(x: 40, y: 70))
            context.strokePath()

            context.move(to: CGPoint(x: 10, y: 80))
            context.addLine(to: CGPoint(x: 50, y: 80))
            context.beginPath()

            context.move(to: CGPoint(x: 60, y: 100))
            context.addLine(to: CGPoint(x: 100, y: 100))
            context.strokePath()
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let scan = PDFTextLayout.scan(on: page)

        XCTAssertEqual(scan.horizontalRules.count, 1)
        let rule = try XCTUnwrap(scan.horizontalRules.first)
        XCTAssertEqual(rule.end.x - rule.start.x, 40, accuracy: 0.02)
    }
}
