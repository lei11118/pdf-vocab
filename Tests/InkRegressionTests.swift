import XCTest
import UIKit
import PDFKit
import PencilKit
import MetalKit
@testable import PdfVocab

@MainActor
final class InkRegressionTests: XCTestCase {
    func testPositionalSmoothingReducesAlternatingSampleNoise() {
        let points = (0..<40).map { InkPoint(x: Double($0)*2, y: $0 % 2 == 0 ? -0.8 : 0.8, width: 5) }
        let smooth = InkBrush.smoothed(points)
        XCTAssertEqual(smooth.first, points.first)
        XCTAssertEqual(smooth.last?.x, points.last?.x)
        XCTAssertEqual(smooth.last!.y, points.last!.y, accuracy: 1e-9)
        let interior = smooth.filter { $0.x > 10 && $0.x < 68 }
        XCTAssertLessThan(interior.map { abs($0.y) }.max() ?? 1, 0.15)
    }

    func testVisualWordDoesNotMergeOrdinarySpace() {
        let text = "A magnitude 9 earthquake" as NSString
        let rects = (0..<text.length).map { CGRect(x: Double($0) * 5, y: 0, width: 4, height: 12) }
        let range = SelectionGeometry.visualWordRange(text: text, at: 4, bounds: { rects[$0] })
        XCTAssertEqual(range.map { text.substring(with: $0) }, "magnitude")
    }

    // Measured from the supplied OpenStax page 15: omitted spaces are 2.66–2.70pt
    // at 9.5pt glyph height. The old 0.45-height threshold joined these words.
    func testOpenStaxOmittedSpacesSeparateMagnitude() {
        let text = "Amagnitude9earthquake" as NSString
        let widths: [CGFloat] = [6.86,7.39,4.21,4.75,4.75,2.63,2.63,4.75,4.75,4.21,4.75,4.21,4.21,3.16,2.63,4.75,4.75,4.75,4.21,4.75,4.21]
        var boxes: [CGRect] = []
        var x: CGFloat = 0
        for i in 0..<text.length {
            if [1,10,11].contains(i) { x += 2.68 }
            boxes.append(CGRect(x: x, y: 0, width: widths[i], height: 9.5))
            x += widths[i]
        }
        let range = SelectionGeometry.visualWordRange(text: text, at: 5, bounds: { boxes[$0] })
        XCTAssertEqual(range.map { text.substring(with: $0) }, "magnitude")
    }

    func testBrushAndPenHaveDifferentPressureResponse() {
        let penLow = InkBrush.width(kind: .pen, base: 4, force: 0, altitude: .pi/2)
        let penHigh = InkBrush.width(kind: .pen, base: 4, force: 1, altitude: .pi/2)
        let brushLow = InkBrush.width(kind: .brush, base: 4, force: 0, altitude: .pi/2)
        let brushHigh = InkBrush.width(kind: .brush, base: 4, force: 1, altitude: .pi/2)
        XCTAssertGreaterThan(brushHigh / brushLow, penHigh / penLow)
        XCTAssertEqual(PencilToolKind(rawValue: "brush")?.label, "毛笔")
    }

    func testBrushPoliciesKeepMarkerConstantAndTransparent() {
        XCTAssertEqual(InkBrush.width(kind: .marker, base: 24, force: 0, altitude: .pi/2), 24)
        XCTAssertEqual(InkBrush.width(kind: .marker, base: 24, force: 1, altitude: .pi/6), 24)
        XCTAssertEqual(InkBrush.opacity(kind: .marker, colorAlpha: 1), 0.3)
        XCTAssertGreaterThan(InkBrush.width(kind: .pencil, base: 3, force: 1, altitude: .pi/6),
                             InkBrush.width(kind: .pencil, base: 3, force: 1, altitude: .pi/2))
    }

    func testPartialEraserSplitsLongSegmentAndWholeEraserRemovesIt() {
        let stroke = InkStroke(kind: .pen,r: 0,g: 0,b: 0,a: 1,
                               points: [InkPoint(x: 0,y: 0,width: 2),InkPoint(x: 100,y: 0,width: 2)])
        let a = CGPoint(x: 50,y: -30), b = CGPoint(x: 50,y: 30)
        let partial = InkEraser.erase([stroke],from: a,to: b,radius: 10,whole: false)
        XCTAssertTrue(partial.changed)
        XCTAssertEqual(partial.strokes.count,2)
        XCTAssertEqual(partial.strokes.first?.points.first?.x,0)
        XCTAssertEqual(partial.strokes.last?.points.last?.x,100)
        XCTAssertEqual(partial.strokes[0].points.last!.x,39,accuracy: 0.1)
        XCTAssertEqual(partial.strokes[1].points.first!.x,61,accuracy: 0.1)
        XCTAssertTrue(InkEraser.erase([stroke],from: a,to: b,radius: 10,whole: true).strokes.isEmpty)
        XCTAssertFalse(InkEraser.erase([stroke],from: CGPoint(x: 200,y: 0),to: CGPoint(x: 200,y: 0),radius: 10,whole: false).changed)
    }

    func testMetalMarkerSelfOverlapUsesOneLayerOfAlpha() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let canvas = InkMetalCanvasView()
        canvas.frame = CGRect(x: 0,y: 0,width: 64,height: 64)
        let stroke = InkStroke(kind: .marker,r: 1,g: 1,b: 0,a: 0.3,
                               points: [10.0,54,10,54].map { InkPoint(x: $0,y: 32,width: 20) })
        canvas.renderItems = [InkRenderItem(stroke: stroke,clip: canvas.bounds)]
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: 64,height: 64,mipmapped: false)
        desc.usage = [.renderTarget,.shaderRead]; desc.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: desc))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func alpha() throws -> Double {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(canvas.encodeFrame(to: target,commandBuffer: command))
            command.commit(); command.waitUntilCompleted()
            XCTAssertNil(command.error)
            var bytes = [UInt8](repeating: 0,count: 64*64*4)
            bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow: 64*4,from: MTLRegionMake2D(0,0,64,64),mipmapLevel: 0) }
            return Double(bytes[(32*64+32)*4+3])/255
        }
        XCTAssertEqual(try alpha(),0.3,accuracy: 2.0/255)
        XCTAssertEqual(try alpha(),0.3,accuracy: 2.0/255) // Cached dry frame must match.
        canvas.renderItems.append(InkRenderItem(stroke: stroke,clip: canvas.bounds))
        XCTAssertEqual(try alpha(),0.51,accuracy: 2.0/255)
        var dot = stroke
        dot.points = [InkPoint(x: 32,y: 32,width: 20),InkPoint(x: 32,y: 32,width: 20)]
        canvas.renderItems = [InkRenderItem(stroke: dot,clip: canvas.bounds)]
        XCTAssertEqual(try alpha(),0.3,accuracy: 2.0/255)
    }

    func testMetalInkSharesPDFDocumentTransformDuringScroll() throws {
        let view = PDFView(frame: CGRect(x: 0,y: 0,width: 400,height: 400))
        view.displayMode = .singlePageContinuous
        let doc = PDFDocument()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400,height: 600)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0,y: 0,width: 400,height: 600))
        }
        doc.insert(try XCTUnwrap(PDFPage(image: image)),at: 0)
        doc.insert(try XCTUnwrap(PDFPage(image: image)),at: 1)
        view.document = doc; view.layoutDocumentView()
        let host = MetalInkHost(); host.attach(to: view,store: nil,docSha: "scroll-test")
        let documentView = try XCTUnwrap(view.documentView)
        XCTAssertTrue(host.superview === documentView)
        let page = try XCTUnwrap(doc.page(at: 0))
        let pdfPoint = CGPoint(x: 100,y: 300)
        let local = host.convert(view.convert(pdfPoint,from: page),from: view)
        let scroll = try XCTUnwrap(documentView.superview as? UIScrollView)
        scroll.contentOffset.y += 100
        let inkPoint = host.convert(local,to: view)
        let paperPoint = view.convert(pdfPoint,from: page)
        XCTAssertEqual(inkPoint.x,paperPoint.x,accuracy: 0.01)
        XCTAssertEqual(inkPoint.y,paperPoint.y,accuracy: 0.01)
    }

    func testMetalEraserPersistsAndUndoRedoRestoreOriginalPage() throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let store = PencilInkStore(db: db)
        let sha = "ink-regression-" + UUID().uuidString
        defer { store.delete(docSha: sha,page: 0) }
        let original = InkStroke(kind: .pen,r: 0,g: 0,b: 0,a: 1,
                                 points: [InkPoint(x: 50,y: 100,width: 2),InkPoint(x: 250,y: 100,width: 2)])
        store.save(docSha: sha,page: 0,data: InkPage(strokes: [original]).data(),scale: 1)
        let view = PDFView(frame: CGRect(x: 0,y: 0,width: 400,height: 400))
        let doc = PDFDocument()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400,height: 600)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0,y: 0,width: 400,height: 600))
        }
        let page = try XCTUnwrap(PDFPage(image: image)); doc.insert(page,at: 0)
        view.document = doc; view.layoutDocumentView()
        let host = MetalInkHost(); host.attach(to: view,store: store,docSha: sha)
        host.applyTool(kind: .eraser,color: .black,baseWidth: 0,eraserRadius: 10,whole: false)
        let box = page.bounds(for: .cropBox)
        let point = host.convert(view.convert(CGPoint(x: box.minX+150,y: box.maxY-100),from: page),from: view)
        host.erase(at: point); host.finishErase()
        func saved() throws -> InkPage {
            let record = try XCTUnwrap(store.drawing(docSha: sha,page: 0))
            return try XCTUnwrap(InkPage.decode(record.data))
        }
        XCTAssertEqual(try saved().strokes.count,2)
        host.undo()
        XCTAssertEqual(try saved().strokes.count,1)
        XCTAssertEqual(try saved().strokes[0].points.count,2)
        host.redo()
        XCTAssertEqual(try saved().strokes.count,2)
        host.applyTool(kind: .eraser,color: .black,baseWidth: 0,eraserRadius: 300,whole: true)
        host.erase(at: point); host.finishErase()
        XCTAssertTrue(try saved().isEmpty)
        host.undo()
        XCTAssertEqual(try saved().strokes.count,2)
    }

    func testMetalShaderCompilesAndEmptyFrameCanDraw() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable") }
        let canvas = InkMetalCanvasView()
        XCTAssertTrue(canvas.isReady, "The runtime Metal shader must compile before accepting Pencil input")
        canvas.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        canvas.renderItems = []
        canvas.draw(in: canvas)
    }

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
        _ = try XCTUnwrap(view.documentView)
        let box = page.bounds(for: .cropBox)
        func location(_ x: CGFloat) -> CGPoint {
            surface.canvas.convert(view.convert(CGPoint(x: box.minX + x, y: box.maxY - 50), from: page), from: view)
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
