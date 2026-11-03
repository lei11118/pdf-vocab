import XCTest
import UIKit
import PDFKit
@testable import PdfVocab

final class KnowledgeGraphTests: XCTestCase {
    func testUndirectedEdgesDeduplicateAndCascadeOnDelete() throws {
        var graph = KnowledgeGraph(id:"test",docId:"doc")
        let a = KnowledgeNode(graphId:graph.id,kind:.text,frame:CGRect(x:0,y:0,width:300,height:200))
        let b = KnowledgeNode(graphId:graph.id,kind:.ink,frame:CGRect(x:500,y:300,width:300,height:200))
        graph.nodes = [a,b]
        graph.connect(from:a.id,anchor:.right,to:b.id,target:.left)
        graph.connect(from:b.id,anchor:.left,to:a.id,target:.right)
        graph.connect(from:a.id,anchor:.top,to:a.id,target:.bottom)
        XCTAssertEqual(graph.edges.count,1)
        let restored = try JSONDecoder().decode(KnowledgeGraph.self,from:JSONEncoder().encode(graph))
        XCTAssertEqual(restored,graph)
        graph.delete(a.id)
        XCTAssertEqual(graph.nodes.count,1); XCTAssertTrue(graph.edges.isEmpty)
    }
    func testArcChordMidpointAndPolarHitWithMirroring() {
        for left in [false,true] {
          for size in [CGSize(width:1000,height:1000),CGSize(width:480,height:600)] {
            let geometry = ToolArcGeometry(anchor:CGPoint(x:size.width/2,y:size.height/2),bounds:size,count:9,leftHanded:left)
            let r = geometry.radius, d = r*cos(ToolArcConfig.sweep/2)
            let c = geometry.center
            XCTAssertEqual(c.y-d*cos(geometry.mid),geometry.anchor.y,accuracy:0.001)
            XCTAssertEqual(c.x+d*sin(geometry.mid)*(left ? -1 : 1),geometry.anchor.x,accuracy:0.001)
            XCTAssertEqual(ToolArcConfig.sweep * 180 / .pi,108,accuracy:0.001)
            XCTAssertEqual(geometry.mid * 180 / .pi,-53,accuracy:0.001)
            XCTAssertGreaterThanOrEqual(geometry.initialCount,5)
            for i in 0..<9 {
                let p = geometry.position(i,count:9,upper:false)
                XCTAssertEqual(geometry.index(at:p,count:9,upper:false),i)
            }
            XCTAssertNil(geometry.index(at:CGPoint.zero,count:9,upper:false))
          }
        }
    }
    func testNormalizedWordBoxesDoNotSnapAcrossWhitespace() {
        let words = [GraphWord(text:"alpha",rect:CGRect(x:0.1,y:0.2,width:0.2,height:0.1)),GraphWord(text:"beta",rect:CGRect(x:0.5,y:0.2,width:0.15,height:0.1))]
        XCTAssertEqual(WordInteraction.hit(CGPoint(x:0.2,y:0.25),words:words),0)
        XCTAssertEqual(WordInteraction.hit(CGPoint(x:0.6,y:0.25),words:words),1)
        XCTAssertNil(WordInteraction.hit(CGPoint(x:0.4,y:0.25),words:words))
        XCTAssertNil(WordInteraction.hit(CGPoint(x:0.2,y:0.5),words:words))
    }
    func testAssetPathsCannotEscapeDirectory() {
        XCTAssertThrowsError(try GraphAssets.url("../secret"))
        XCTAssertThrowsError(try GraphAssets.url("a/b.png"))
        XCTAssertThrowsError(try GraphAssets.url("a\\b.png"))
    }
    @MainActor func testCaptureWordBoxesFollowPDFRotation() throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let data = UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:400,height:500)).pdfData { context in
            context.beginPage()
            ("alpha beta gamma" as NSString).draw(at:CGPoint(x:40,y:80),withAttributes:[.font:UIFont.systemFont(ofSize:24)])
        }
        let document = try XCTUnwrap(PDFDocument(data:data)),page = try XCTUnwrap(document.page(at:0))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene:scene),controller = UIViewController()
        window.frame = CGRect(x:0,y:0,width:900,height:900); window.rootViewController = controller
        let view = PDFView(frame:window.bounds); controller.view.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        view.document = document; view.autoScales = true
        for rotation in [0,90,180,270] {
            page.rotation = rotation; view.layoutDocumentView(); view.layoutIfNeeded()
            let native = try XCTUnwrap(page.selection(for:NSRange(location:0,length:5)))
            let rect = view.convert(native.bounds(for:page),from:page).insetBy(dx:-5,dy:-5)
            let result = try GraphCapture.render(view:view,rect:rect,docId:"capture-test",ink:PencilInkStore(db:db))
            let word = try XCTUnwrap(result.words.first { $0.text == "alpha" },"rotation=\(rotation)")
            XCTAssertGreaterThan(result.image.size.width,rect.width/view.scaleFactor)
            XCTAssertGreaterThanOrEqual(word.rect.minX,0); XCTAssertLessThanOrEqual(word.rect.maxX,1.001)
            XCTAssertGreaterThanOrEqual(word.rect.minY,0); XCTAssertLessThanOrEqual(word.rect.maxY,1.001)
            let expected = view.convert(SelectionGeometry.placedBounds(of:native,on:page),from:page)
            XCTAssertEqual(word.rect.midX,(expected.midX-rect.minX)/rect.width,accuracy:0.02)
            XCTAssertEqual(word.rect.midY,(expected.midY-rect.minY)/rect.height,accuracy:0.02)
        }
    }
}
