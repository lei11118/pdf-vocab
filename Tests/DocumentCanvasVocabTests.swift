import XCTest
import UIKit
@testable import PdfVocab

@MainActor
final class DocumentCanvasVocabTests: XCTestCase {
    private let boxes = [0:CGRect(x:0,y:0,width:100,height:100),1:CGRect(x:0,y:100,width:100,height:100)]
    private let maps = [0:CGAffineTransform.identity,1:CGAffineTransform(translationX:0,y:100)]
    private func stroke() -> InkStroke {
        InkStroke(kind:.pen,r:0,g:0,b:0,a:1,points:[InkPoint(x:30,y:80,width:2,force:0.2),InkPoint(x:30,y:120,width:6,force:0.8)])
    }
    func testExactCrossPageIntersectionAndLogicalJoin() throws {
        let pieces=InkContinuity.partition(stroke(),boxes:boxes,maps:maps)
        XCTAssertEqual(pieces.count,2)
        XCTAssertEqual(pieces.map(\.page),[0,1])
        XCTAssertEqual(pieces[0].stroke.strokeID,pieces[1].stroke.strokeID)
        XCTAssertNotNil(pieces[0].stroke.strokeID)
        XCTAssertEqual(pieces[0].stroke.points.last!.y,100,accuracy:1e-6)
        XCTAssertEqual(pieces[1].stroke.points.first!.y,0,accuracy:1e-6)
        XCTAssertEqual(pieces[0].stroke.points.last!.width,4,accuracy:1e-6)
        XCTAssertEqual(pieces[0].stroke.points.last!.force,0.5,accuracy:1e-6)
        let items=pieces.map { piece -> InkRenderItem in
            var s=piece.stroke
            s.points=s.points.map { p in var q=p;let v=p.cg.applying(maps[piece.page]!);q.x=Double(v.x);q.y=Double(v.y);return q }
            return InkRenderItem(stroke:s,clip:boxes[piece.page]!)
        }
        let joined=InkContinuity.joined(items.reversed())
        XCTAssertEqual(joined.count,1)
        XCTAssertEqual(joined[0].stroke.points.map(\.y),[80,100,120])
        XCTAssertEqual(joined[0].clip.height,200)
    }
    func testBoundaryTouchDoesNotCreateEmptyFragment() {
        var s=stroke();s.points[1].y=100
        XCTAssertEqual(InkContinuity.partition(s,boxes:boxes,maps:maps).map(\.page),[0])
    }
    func testLegacyJSONHasNoIdentityAndEraserGapIsNotBridged() throws {
        let json=Data(#"{"strokes":[{"kind":"pen","r":0,"g":0,"b":0,"a":1,"points":[]}]}"#.utf8)
        XCTAssertNil(try XCTUnwrap(InkPage.decode(json)).strokes[0].strokeID)
        var a=stroke();a.strokeID=UUID();a.fragmentOrder=0
        var b=a;b.fragmentOrder=1;b.points=b.points.map { p in var q=p;q.y+=80;return q }
        XCTAssertEqual(InkContinuity.joined([InkRenderItem(stroke:a,clip:boxes[0]!),InkRenderItem(stroke:b,clip:boxes[1]!)]).count,2)
    }
    func testLinkedFragmentLookupIsDocumentScoped() throws {
        let store=PencilInkStore(db:try XCTUnwrap(AppDatabase.shared))
        let sha="continuity-"+UUID().uuidString,other=sha+"-other"
        defer { store.delete(docSha:sha,page:0);store.delete(docSha:sha,page:7);store.delete(docSha:other,page:2) }
        var s=stroke();s.strokeID=UUID()
        for page in [0,7] { store.save(docSha:sha,page:page,data:InkPage(strokes:[s]).data(),scale:1) }
        store.save(docSha:other,page:2,data:InkPage(strokes:[s]).data(),scale:1)
        XCTAssertEqual(store.pages(containing:[s.strokeID!],docSha:sha),[0,7])
        XCTAssertEqual(store.pages(containing:[UUID()],docSha:sha),[])
    }
    func testInfiniteRulerPoseAndReset() throws {
        let host=UIView(frame:CGRect(x:0,y:0,width:400,height:600))
        let ruler=SmartRulerView(length:100,host:host);ruler.isOn=true
        ruler.setPose(position:CGPoint(x:10000,y:200),angle:0)
        let project=try XCTUnwrap(ruler.projector(startingAt:CGPoint(x:20,y:240)))
        XCTAssertEqual(project(CGPoint(x:-5000,y:500)).y,240,accuracy:1e-6)
        host.bounds.size=CGSize(width:600,height:400);ruler.updateHostBounds()
        XCTAssertEqual(ruler.rulerPosition,CGPoint(x:10000,y:200))
        ruler.resetInHost();XCTAssertEqual(ruler.rulerPosition,CGPoint(x:300,y:200))
    }
    func testLaserTrailIsBoundedAndClears() {
        let laser=InkLaserOverlay(frame:.zero);laser.begin(at:.zero)
        for i in 0..<1000 { laser.append(CGPoint(x:i,y:i)) }
        XCTAssertEqual(laser.pointCount,192)
        laser.finish();laser.begin(at:.zero);XCTAssertEqual(laser.pointCount,1)
        laser.clear();XCTAssertEqual(laser.pointCount,0)
    }
    func testGridReorderingBothDirections() {
        XCTAssertEqual(VocabReorderPolicy.moving([1,2,3],source:1,target:2),[2,1,3])
        XCTAssertEqual(VocabReorderPolicy.moving([1,2,3],source:3,target:1),[3,1,2])
        XCTAssertEqual(VocabReorderPolicy.moving([1,2,3],source:7,target:1),[1,2,3])
    }
    func testOfflineRelationsUseSensesAndExplicitMorphology() {
        let senses=VocabRelationService.build(words:[(1,"quick"),(2,"fast"),(3,"banana")],mode:.synonym)
        XCTAssertTrue(senses.available);XCTAssertFalse(senses.edges.isEmpty)
        XCTAssertTrue(senses.edges.allSatisfy { $0.a==1 && $0.b==2 && !$0.morphology && $0.evidence.contains("oewn-") })
        let roots=VocabRelationService.build(words:[(1,"transport"),(2,"export"),(3,"transporterzz")],mode:.morphology)
        XCTAssertTrue(roots.available);XCTAssertFalse(roots.edges.isEmpty)
        XCTAssertTrue(roots.edges.allSatisfy { $0.a==1 && $0.b==2 && $0.morphology && $0.evidence.contains("MIT") })
        let ids=Array(Int64(1)...Int64(250))
        let layout=VocabRelationService.layout(ids:ids,edges:senses.edges)
        XCTAssertEqual(layout.count,250);XCTAssertTrue(layout.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertEqual(layout,VocabRelationService.layout(ids:ids,edges:senses.edges))
    }
    func testNewMaterialIsBundled() { XCTAssertNotNil(UIImage(named:"ink-material-atlas-v2")?.cgImage) }
}
