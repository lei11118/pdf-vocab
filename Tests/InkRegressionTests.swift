import XCTest
import UIKit
import PDFKit
import PencilKit
@testable import PdfVocab

@MainActor
final class InkRegressionTests: XCTestCase {
    func testPencilObserverCannotBlockOrBeBlockedByScrolling() {
        let pan = UIPanGestureRecognizer()
        let grab = InkPencilGrabRecognizer(target: nil, action: nil)
        XCTAssertFalse(grab.canPrevent(pan))
        XCTAssertFalse(grab.canBePrevented(by: pan))
        XCTAssertFalse(grab.cancelsTouchesInView)
        XCTAssertEqual(grab.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.pencil.rawValue)])
        let observer = PencilTouchObserver()
        XCTAssertFalse(observer.canPrevent(pan))
        XCTAssertFalse(observer.canBePrevented(by: pan))
    }

    func testRulerLocksNearestEdgeAndLeavesFreehandAlone() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let ruler = SmartRulerView(length: 900, host: host)
        XCTAssertNil(ruler.projector(startingAt: CGPoint(x: 400, y: 260)))
        ruler.isOn = true
        let upper = try XCTUnwrap(ruler.projector(startingAt: CGPoint(x: 400, y: 257)))
        XCTAssertEqual(upper(CGPoint(x: 450, y: 320)).y, 260, accuracy: 0.001)
        let lower = try XCTUnwrap(ruler.projector(startingAt: CGPoint(x: 400, y: 343)))
        XCTAssertEqual(lower(CGPoint(x: 450, y: 280)).y, 340, accuracy: 0.001)
        XCTAssertNil(ruler.projector(startingAt: CGPoint(x: 400, y: 180)))
    }

    func testSurfaceKeepsLastRunAndPersistsErasedPage() throws {
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let document = PDFDocument()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 500)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 500))
        }
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        view.document = document
        view.layoutDocumentView()
        let surface = DocumentInkSurface()
        surface.attach(to: view)
        surface.refreshWindow()
        XCTAssertFalse(surface.canvas.panGestureRecognizer.isEnabled)
        surface.setRulerActive(true)
        XCTAssertTrue(surface.canvas.isRulerActive)

        let page = try XCTUnwrap(document.page(at: 0))
        let docView = try XCTUnwrap(view.documentView)
        let box = page.bounds(for: .cropBox)
        func location(_ x: CGFloat) -> CGPoint {
            docView.convert(view.convert(CGPoint(x: box.minX + x, y: box.maxY - 50), from: page), from: view)
        }
        let points = [50, 80, 110].map { x in
            PKStrokePoint(location: location(CGFloat(x)), timeOffset: Double(x) / 100,
                          size: CGSize(width: 3, height: 3), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .black),
                              path: PKStrokePath(controlPoints: points, creationDate: Date()))
        var saved: [Int: PKDrawing] = [:]
        surface.onPageInkChanged = { saved[$0] = $1 }
        surface.canvas.drawing = PKDrawing(strokes: [stroke])
        surface.canvasViewDrawingDidChange(surface.canvas)
        let drawing = try XCTUnwrap(saved[0])
        XCTAssertEqual(drawing.strokes.count, 1)
        let first = try XCTUnwrap(drawing.strokes.first)
        let p = try XCTUnwrap(first.path.first).location.applying(first.transform)
        XCTAssertEqual(p.x, 50, accuracy: 1)
        XCTAssertEqual(p.y, 50, accuracy: 1)
        surface.canvas.drawing = PKDrawing()
        surface.canvasViewDrawingDidChange(surface.canvas)
        XCTAssertEqual(saved[0]?.strokes.count, 0)
    }
}
