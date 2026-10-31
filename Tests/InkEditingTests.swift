import XCTest
import UIKit
import PDFKit
import MetalKit
@testable import PdfVocab

@MainActor
final class InkEditingTests: XCTestCase {
    private func fixture() throws -> (PDFView,PDFDocument,MetalInkHost,PencilInkStore,String) {
        let store=PencilInkStore(db:try XCTUnwrap(AppDatabase.shared))
        let sha="edit-regression-"+UUID().uuidString
        let view=VocabPDFView(frame:CGRect(x:0,y:0,width:400,height:500))
        view.displayMode = .singlePageContinuous; view.displaysPageBreaks = false
        let doc=PDFDocument()
        let image=UIGraphicsImageRenderer(size:CGSize(width:400,height:600)).image { ctx in
            UIColor.white.setFill();ctx.fill(CGRect(x:0,y:0,width:400,height:600))
        }
        for i in 0..<2 { doc.insert(try XCTUnwrap(PDFPage(image:image)),at:i) }
        view.document=doc; view.scaleFactor=1;view.layoutDocumentView()
        let host=MetalInkHost();host.attach(to:view,store:store,docSha:sha)
        return (view,doc,host,store,sha)
    }
    func testLassoMoveResizeAcrossPagesAndUndoPersist() throws {
        let (view,doc,host,store,sha)=try fixture()
        defer { for i in 0..<2 { store.delete(docSha:sha,page:i) } }
        let first=try XCTUnwrap(doc.page(at:0)), second=try XCTUnwrap(doc.page(at:1))
        func point(_ x:CGFloat,_ y:CGFloat,page:PDFPage)->CGPoint {
            let box=page.bounds(for:.cropBox)
            return view.convert(CGPoint(x:box.minX+x,y:box.maxY-y),from:page)
        }
        let points=[point(60,80,page:first),point(100,100,page:first)]
        host.commit(InkStroke(kind:.pen,r:0,g:0,b:0,a:1,points:points.map {
            let p=host.convert($0,from:view);return InkPoint(x:Double(p.x),y:Double(p.y),width:2)
        }))
        host.applyTool(kind:.lasso,color:.black,baseWidth:2,eraserRadius:10,whole:false)
        let r=InkEditGeometry.bounds(points).insetBy(dx:-10,dy:-10)
        host.selectInk(in:[CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)])
        XCTAssertEqual(host.selectedInkCount,1)
        let target=point(60,80,page:second)
        host.beginInkTransform()
        host.transformSelectedInk(CGAffineTransform(translationX:target.x-points[0].x,y:target.y-points[0].y))
        host.endInkTransform(cancelled:false)
        func saved(_ i:Int)throws->InkPage { try XCTUnwrap(InkPage.decode(try XCTUnwrap(store.drawing(docSha:sha,page:i)).data)) }
        XCTAssertTrue(try saved(0).isEmpty); XCTAssertEqual(try saved(1).strokes.count,1)
        XCTAssertEqual(try saved(1).strokes[0].points[0].x,60,accuracy:0.1)
        host.beginInkTransform()
        let anchor=point(60,80,page:second)
        let transform=CGAffineTransform(translationX:-anchor.x,y:-anchor.y).concatenating(CGAffineTransform(scaleX:2,y:2)).concatenating(CGAffineTransform(translationX:anchor.x,y:anchor.y))
        host.transformSelectedInk(transform); host.endInkTransform(cancelled:false)
        XCTAssertEqual(try saved(1).strokes[0].points.last!.x,140,accuracy:0.1)
        XCTAssertEqual(try saved(1).strokes[0].points[0].width,4,accuracy:0.1)
        host.undo();XCTAssertEqual(try saved(1).strokes[0].points.last!.x,100,accuracy:0.1)
        host.undo();XCTAssertEqual(try saved(0).strokes.count,1);XCTAssertTrue(try saved(1).isEmpty)
        host.redo();XCTAssertEqual(try saved(1).strokes.count,1)
    }
    func testAllShapesPreviewCommitAndUndoAsOneOperation() throws {
        let (view,_,host,store,sha)=try fixture()
        defer { for i in 0..<2 { store.delete(docSha:sha,page:i) } }
        for shape in PencilShapeKind.allCases {
            host.applyTool(kind:.shape,color:.blue,baseWidth:2,eraserRadius:10,whole:false,shape:shape)
            host.beginEdit(at:CGPoint(x:120,y:120));host.moveEdit(to:CGPoint(x:220,y:220));host.endEdit()
            let record=try XCTUnwrap(store.drawing(docSha:sha,page:0))
            let page=try XCTUnwrap(InkPage.decode(record.data))
            XCTAssertEqual(page.strokes.count,shape == .arrow ? 2 : 1)
            host.undo()
            XCTAssertTrue(try XCTUnwrap(InkPage.decode(try XCTUnwrap(store.drawing(docSha:sha,page:0)).data)).isEmpty)
        }
        _ = view
    }
    func testLassoFindsLongSegmentCrossingPolygonAndRejectsMiss() {
        let square=[CGPoint(x:20,y:20),CGPoint(x:40,y:20),CGPoint(x:40,y:40),CGPoint(x:20,y:40)]
        XCTAssertTrue(InkEditGeometry.intersects([CGPoint(x:0,y:30),CGPoint(x:100,y:30)],polygon:square))
        XCTAssertFalse(InkEditGeometry.intersects([CGPoint(x:0,y:0),CGPoint(x:100,y:0)],polygon:square))
        let r=CGRect(x:10,y:10,width:100,height:50)
        let t=InkEditGeometry.resize(bounds:r,corner:CGPoint(x:110,y:60),to:CGPoint(x:210,y:110))
        XCTAssertEqual(CGPoint(x:10,y:10).applying(t).x,10,accuracy:0.01)
        XCTAssertEqual(t.a,2,accuracy:0.01)
    }
    func testZoomedVectorEdgeAndMemoryCacheRebuild() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let canvas=InkMetalCanvasView();canvas.frame=CGRect(x:0,y:0,width:64,height:64)
        let stroke=InkStroke(kind:.marker,r:1,g:1,b:0,a:0.3,points:[InkPoint(x:10,y:32,width:20),InkPoint(x:54,y:32,width:20)])
        canvas.renderItems=[InkRenderItem(stroke:stroke,clip:canvas.bounds)]
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:512,height:512,mipmapped:false)
        desc.storageMode = .shared;desc.usage=[.renderTarget,.shaderRead]
        let target=try XCTUnwrap(device.makeTexture(descriptor:desc))
        let queue=try XCTUnwrap(device.makeCommandQueue())
        func render() throws -> [UInt8] {
            let command=try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(canvas.encodeFrame(to:target,commandBuffer:command));command.commit();command.waitUntilCompleted()
            XCTAssertNil(command.error)
            var bytes=[UInt8](repeating:0,count:512*512*4)
            bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow:512*4,from:MTLRegionMake2D(0,0,512,512),mipmapLevel:0) }
            return bytes
        }
        let first=try render()
        XCTAssertEqual(Double(first[(179*512+256)*4+3])/255,0.3,accuracy:2.0/255)
        XCTAssertEqual(first[(174*512+256)*4+3],0)
        canvas.releaseCachedResources()
        let second=try render()
        XCTAssertEqual(first,second)
    }

    func testPressureRangeAndSmoothingPreserveEndpoints() {
        XCTAssertEqual(InkBrush.normalizedPressure(force:2,maximum:4),0.5)
        XCTAssertEqual(InkBrush.normalizedPressure(force:8,maximum:4),1)
        XCTAssertEqual(InkBrush.normalizedPressure(force:.nan,maximum:4),0.5)
        let light=InkBrush.width(kind:.pen,base:3,force:0.05,altitude:.pi/2)
        let heavy=InkBrush.width(kind:.pen,base:3,force:0.9,altitude:.pi/2)
        XCTAssertGreaterThan(heavy/light,3)
        let points=(0..<8).map { InkPoint(x:Double($0)*10,y:sin(Double($0)),width:2) }
        let smooth=InkBrush.smoothed(points)
        XCTAssertEqual(smooth.first?.x,points.first?.x)
        XCTAssertEqual(smooth.last?.x,points.last?.x)
        XCTAssertTrue(smooth.allSatisfy { $0.x.isFinite && $0.width>0 })
    }
    func testHandleExpandedTargetWinsOverPDFContentAndScrollIsUnlocked() throws {
        let (view,doc,host,_,_)=try fixture()
        let handle=SelectionHandleView(isStart:true)
        handle.frame=CGRect(x:180,y:180,width:14,height:32);view.addSubview(handle)
        let p=CGPoint(x:168,y:190)
        XCTAssertTrue(view.hitTest(p,with:nil) === handle)
        let scroll=try XCTUnwrap(view.documentView?.superview as? UIScrollView)
        XCTAssertFalse(scroll.isDirectionalLockEnabled)
        _ = doc
        host.detach()
        XCTAssertNil(host.superview)
        XCTAssertFalse(view.subviews.contains { $0 is InkEditingOverlay })
    }
}
