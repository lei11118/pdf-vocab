import XCTest
import UIKit
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
            let geometry = ToolArcGeometry(anchor:CGPoint(x:500,y:500),bounds:CGSize(width:1000,height:1000),count:9,leftHanded:left)
            let r = ToolArcConfig.radius, d = r*cos(ToolArcConfig.sweep/2)
            let c = geometry.center
            XCTAssertEqual(c.y-d*cos(geometry.mid),geometry.anchor.y,accuracy:0.001)
            XCTAssertEqual(c.x+d*sin(geometry.mid)*(left ? -1 : 1),geometry.anchor.x,accuracy:0.001)
            XCTAssertEqual(geometry.initialCount,5)
            for i in 0..<9 {
                let p = geometry.position(i,count:9,upper:false)
                XCTAssertEqual(geometry.index(at:p,count:9,upper:false),i)
            }
            XCTAssertNil(geometry.index(at:CGPoint.zero,count:9,upper:false))
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
}
