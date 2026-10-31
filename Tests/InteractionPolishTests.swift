import XCTest
import UIKit
import PDFKit
import MetalKit
@testable import PdfVocab

@MainActor
final class InteractionPolishTests:XCTestCase {
    func testWordPickingStartsWithOneWordAndRejectsWhitespace() throws {
        let data=UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:400,height:300)).pdfData { ctx in
            ctx.beginPage()
            ("Hello world again" as NSString).draw(at:CGPoint(x:30,y:60),withAttributes:[.font:UIFont.systemFont(ofSize:24)])
        }
        let page=try XCTUnwrap(PDFDocument(data:data)?.page(at:0))
        let hello=try XCTUnwrap(page.selection(for:NSRange(location:0,length:5)))
        let bounds=hello.bounds(for:page)
        let picked=try XCTUnwrap(SelectionGeometry.initialWord(on:page,at:CGPoint(x:bounds.midX,y:bounds.midY)))
        XCTAssertEqual(picked.string?.trimmingCharacters(in:.whitespacesAndNewlines),"Hello")
        XCTAssertNil(SelectionGeometry.initialWord(on:page,at:CGPoint(x:350,y:250)))
    }
    func testRulerTracksDocumentInsteadOfViewport() {
        let host=UIView(frame:CGRect(x:0,y:0,width:500,height:500))
        let document=UIView(frame:CGRect(x:0,y:0,width:500,height:1500));host.addSubview(document)
        let ruler=SmartRulerView(length:700,host:host);host.addSubview(ruler)
        ruler.bindDocument(document);ruler.setPose(position:CGPoint(x:150,y:250),angle:.pi/4)
        XCTAssertEqual(ruler.angleLabel,"45°")
        let anchor=document.convert(ruler.rulerPosition,from:ruler)
        document.frame.origin.y = -100;ruler.syncDocumentPose()
        XCTAssertEqual(ruler.rulerPosition.y,150,accuracy:0.001)
        XCTAssertEqual(document.convert(ruler.rulerPosition,from:ruler).y,anchor.y,accuracy:0.001)
        document.transform=CGAffineTransform(scaleX:2,y:2);ruler.syncDocumentPose()
        XCTAssertEqual(ruler.poseScale,2,accuracy:0.001)
        XCTAssertEqual(document.convert(ruler.rulerPosition,from:ruler).x,anchor.x,accuracy:0.001)
        ruler.resetInHost();XCTAssertEqual(ruler.rulerPosition,CGPoint(x:250,y:250))
    }
    func testGraphSpringsPinnedNodeDampingAndFiniteBounds() {
        var points:[Int64:CGPoint]=[1:.zero,2:CGPoint(x:400,y:0)]
        var velocities:[Int64:CGVector]=[:]
        let edge=VocabGraphEdge(id:"test",a:1,b:2,morphology:false,evidence:"")
        VocabGraphPhysics.step(positions:&points,velocities:&velocities,edges:[edge],pinned:[1])
        XCTAssertEqual(points[1],.zero);XCTAssertLessThan(points[2]!.x,400)
        for _ in 0..<300 { VocabGraphPhysics.step(positions:&points,velocities:&velocities,edges:[edge],pinned:[1]) }
        XCTAssertTrue(points.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertLessThan(abs(velocities[2]!.dx),2)
        var isolated:[Int64:CGPoint]=[1:.zero],motion:[Int64:CGVector]=[1:CGVector(dx:100,dy:0)]
        VocabGraphPhysics.step(positions:&isolated,velocities:&motion,edges:[],pinned:[])
        XCTAssertLessThan(motion[1]!.dx,100);XCTAssertGreaterThan(isolated[1]!.x,0)
    }
    func testRoundInkHasCoverageOutsideGeometricBoundary() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let canvas=InkMetalCanvasView();canvas.frame=CGRect(x:0,y:0,width:64,height:64);canvas.drawableSize=CGSize(width:256,height:256)
        let dot=InkPoint(x:32.2,y:32.2,width:20)
        canvas.renderItems=[InkRenderItem(stroke:InkStroke(kind:.pen,r:0,g:0,b:0,a:1,points:[dot,dot]),clip:canvas.bounds)]
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:256,height:256,mipmapped:false)
        descriptor.storageMode = .shared;descriptor.usage=[.renderTarget,.shaderRead]
        let target=try XCTUnwrap(device.makeTexture(descriptor:descriptor)),queue=try XCTUnwrap(device.makeCommandQueue()),command=try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(canvas.encodeFrame(to:target,commandBuffer:command));command.commit();command.waitUntilCompleted()
        var bytes=[UInt8](repeating:0,count:256*256*4)
        bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow:256*4,from:MTLRegionMake2D(0,0,256,256),mipmapLevel:0) }
        let edge=bytes[(128*256+88)*4+3]
        XCTAssertGreaterThan(edge,0);XCTAssertLessThan(edge,255)
        XCTAssertEqual(bytes[(128*256+128)*4+3],255)
        XCTAssertEqual(bytes[(128*256+80)*4+3],0)
    }
}
