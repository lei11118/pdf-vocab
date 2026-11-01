import XCTest
import UIKit
import PDFKit
import MetalKit
@testable import PdfVocab

@MainActor
final class InteractionPolishTests:XCTestCase {
    func testWordPickingStartsWithOneWordAndRejectsWhitespace() throws {
        XCTAssertTrue(SelectionGeometry.isSingleWordText("don't"))
        XCTAssertTrue(SelectionGeometry.isSingleWordText("well-known"))
        XCTAssertFalse(SelectionGeometry.isSingleWordText("word word"))
        XCTAssertFalse(SelectionGeometry.isSingleWordText("whole line selected"))
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
        func alpha(_ x:Int,_ y:Int)->UInt8 {
            let row:Int=y*256
            let offset:Int=(row+x)*4+3
            return bytes[offset]
        }
        let edge:UInt8=alpha(88,128)
        XCTAssertGreaterThan(edge,0);XCTAssertLessThan(edge,255)
        XCTAssertEqual(alpha(128,128),255)
        XCTAssertEqual(alpha(80,128),0)
    }
    func testVisualWordRepairsSplitGlyphsButPreservesRealWordSpace() {
        let text="h e l l o world" as NSString
        let xs:[CGFloat]=[0,8,8,16,16,24,24,32,32,40,48,56,64,72,80]
        func box(_ i:Int)->CGRect { CGRect(x:xs[i],y:0,width:8,height:20) }
        XCTAssertEqual(SelectionGeometry.visualWordRange(text:text,at:4,bounds:box),NSRange(location:0,length:9))
        XCTAssertEqual(SelectionGeometry.visualWordRange(text:text,at:12,bounds:box),NSRange(location:10,length:5))
        XCTAssertNil(SelectionGeometry.visualWordRange(text:text,at:9,bounds:box))
        XCTAssertFalse(SelectionGeometry.joinsWord(CGRect(x:0,y:0,width:8,height:20),CGRect(x:8,y:30,width:8,height:20),acrossSpace:true))
    }

    func testFullGraphLabelsCannotOverlapEvenWhenLoadedAtOnePoint() {
        let ids=(1...60).map { Int64($0) }
        var points=Dictionary(uniqueKeysWithValues:ids.map { ($0,CGPoint.zero) })
        let sizes=Dictionary(uniqueKeysWithValues:ids.map { ($0,CGSize(width:CGFloat(60+Int($0%5)*30),height:34)) })
        var velocities:[Int64:CGVector]=[:]
        VocabGraphPhysics.resolveCollisions(positions:&points,velocities:&velocities,pinned:[30],sizes:sizes)
        XCTAssertEqual(points[30],.zero)
        func check() {
            for i in ids { for j in ids where j>i {
                let a=points[i]!,b=points[j]!,sa=sizes[i]!,sb=sizes[j]!
                XCTAssertTrue(abs(a.x-b.x)>=(sa.width+sb.width)/2+7.9 || abs(a.y-b.y)>=(sa.height+sb.height)/2+7.9)
            } }
        }
        check()
        let edges=ids.dropFirst().map { VocabGraphEdge(id:"\($0)",a:1,b:$0,morphology:false,evidence:"") }
        for _ in 0..<30 {
            VocabGraphPhysics.step(positions:&points,velocities:&velocities,edges:edges,pinned:[30],sizes:sizes)
            check()
        }
    }

    func testCurvedWideInkHasNoRadialCracks() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let canvas=InkMetalCanvasView();canvas.frame=CGRect(x:0,y:0,width:128,height:128);canvas.drawableSize=CGSize(width:512,height:512)
        let points=(0...80).map { i in
            let t=Double(i)/80*Double.pi*1.7
            return InkPoint(x:64+32*cos(t),y:64+32*sin(t),width:24)
        }
        canvas.renderItems=[InkRenderItem(stroke:InkStroke(kind:.pen,r:0,g:0,b:0,a:1,points:points),clip:canvas.bounds)]
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:512,height:512,mipmapped:false)
        descriptor.storageMode = .shared;descriptor.usage=[.renderTarget,.shaderRead]
        let texture=try XCTUnwrap(device.makeTexture(descriptor:descriptor)),command=try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        XCTAssertTrue(canvas.encodeFrame(to:texture,commandBuffer:command));command.commit();command.waitUntilCompleted()
        XCTAssertNil(command.error)
        var bytes=[UInt8](repeating:0,count:512*512*4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:512*4,from:MTLRegionMake2D(0,0,512,512),mipmapLevel:0) }
        var holes=0,sampled=0
        for i in 1..<800 {
            let angle=Double(i)/800*Double.pi*1.7
            for radius in stride(from:40.0,through:43.0,by:0.5) {
                let x=Int((64+radius*cos(angle))*4),y=Int((64+radius*sin(angle))*4)
                let offset=(y*512+x)*4+3
                sampled+=1
                if bytes[offset]<240 { holes+=1 }
            }
        }
        XCTAssertGreaterThan(sampled,5000);XCTAssertEqual(holes,0)
    }

    func testOCRCanonicalRasterIgnoresPageRotationAndCrop() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            context.beginPage()
            UIColor.black.setFill()
            UIBezierPath(rect: CGRect(x: 70, y: 100, width: 130, height: 40)).fill()
        }
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let size = OCRService.renderingSize(for: page.bounds(for: .mediaBox))
        let baseline = try XCTUnwrap(OCRService.recognitionImage(page: page, size: size)?.dataProvider?.data)
        page.setBounds(CGRect(x: 40, y: 60, width: 320, height: 480), for: .cropBox)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let image = try XCTUnwrap(OCRService.recognitionImage(page: page, size: size))
            XCTAssertEqual(try XCTUnwrap(image.dataProvider?.data) as Data, baseline as Data)
        }
    }

    func testOCRBoxesAlignWithRenderedText() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            context.beginPage()
            ("Alignment" as NSString).draw(at: CGPoint(x: 80, y: 120), withAttributes: [
                .font: UIFont.systemFont(ofSize: 32), .foregroundColor: UIColor.black])
        }
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        page.setBounds(CGRect(x: 40, y: 60, width: 320, height: 480), for: .cropBox)
        let words = OCRService.recognize(page: page)
        let word = try XCTUnwrap(words.first { $0.text.lowercased() == "alignment" })
        let rect = OCRService.pageRect(from: word, pageBounds: page.bounds(for: .mediaBox))
        XCTAssertEqual(rect.minX, 80, accuracy: 8)
        XCTAssertEqual(rect.midY, 458, accuracy: 12)
        XCTAssertGreaterThan(rect.width, 100)
        XCTAssertEqual(OCRService.wordIndex(at: CGPoint(x: rect.midX, y: rect.midY), in: words,
            pageBounds: page.bounds(for: .mediaBox)), words.firstIndex { $0.text == word.text })
    }

    func testOCRMediaOriginRoundTripAndLegacyCacheInvalidation() throws {
        let bounds = CGRect(x: 31, y: -27, width: 400, height: 600)
        let word = OCRWord(text: "test", x: 0.2, y: 0.3, w: 0.25, h: 0.05, line: 0)
        let rect = OCRService.pageRect(from: word, pageBounds: bounds)
        XCTAssertEqual(rect.minX, 111, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 363, accuracy: 0.001)
        XCTAssertEqual(OCRService.wordIndex(at: CGPoint(x: rect.midX, y: rect.midY), in: [word], pageBounds: bounds), 0)
        let db = try XCTUnwrap(AppDatabase.shared), sha = "ocr-test-" + UUID().uuidString
        defer { try? db.dbQueue.write { try $0.execute(sql: "DELETE FROM ocr_status WHERE docSha = ?", arguments: [sha]) } }
        try db.dbQueue.write { try $0.execute(sql: "INSERT INTO ocr_status (docSha, done, updatedAt) VALUES (?, 1, ?)", arguments: [sha, Date()]) }
        let store = OCRStore(db: db)
        XCTAssertFalse(store.isDone(docSha: sha))
        store.markDone(docSha: sha)
        XCTAssertTrue(store.isDone(docSha: sha))
    }

}
