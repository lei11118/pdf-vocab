import XCTest
import UIKit
import PDFKit
@testable import PdfVocab

@MainActor final class PhotoHoverRegressionTests:XCTestCase {
    func testPhotoPageHoverUsesOCRBoxAndQuotedOccurrenceOffset() throws {
        let db = try XCTUnwrap(AppDatabase.shared),sha = "ocr-hover-\(UUID().uuidString)"
        let ocr = OCRStore(db:db)
        let words = [OCRWord(text:"A",x:0.1,y:0.3,w:0.02,h:0.04,line:0),OCRWord(text:"“function.”",x:0.14,y:0.3,w:0.2,h:0.04,line:0)]
        ocr.save(docSha:sha,page:0,words:words)
        defer { try? db.dbQueue.write { db in
            try db.execute(sql:"DELETE FROM ocr_word WHERE docSha=?",arguments:[sha])
            try db.execute(sql:"DELETE FROM ocr_page_status WHERE docSha=?",arguments:[sha])
        } }
        let bytes = UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:400,height:600)).pdfData { $0.beginPage() }
        let document = try XCTUnwrap(PDFDocument(data:bytes)),page = try XCTUnwrap(document.page(at:0))
        let view = VocabPDFView(frame:CGRect(x:0,y:0,width:900,height:1100))
        view.document = document; view.layoutDocumentView()
        let coordinator = ReaderCoordinator(onPageChanged:{_ in},onSelectionInfo:{_ in})
        coordinator.pdfView = view; coordinator.ocrStore = ocr; coordinator.docSha = sha
        var term = "",anchor = CGPoint.zero
        coordinator.onHoverUpdate = { value,_,point in term = value; anchor = point }
        let rect = OCRService.pageRect(from:words[1],pageBounds:page.bounds(for:.mediaBox))
        coordinator.perform(NSSelectorFromString("handleHover:"),with:BeganWordHover(point:view.convert(CGPoint(x:rect.midX,y:rect.midY),from:page)))
        XCTAssertEqual(term,"function")
        XCTAssertEqual(anchor.y,view.convert(rect,from:page).minY,accuracy:0.5)
        coordinator.clearHover()
    }
}
@MainActor
private final class BeganWordHover:UIHoverGestureRecognizer {
    let point:CGPoint
    init(point:CGPoint) { self.point = point; super.init(target:nil,action:nil) }
    override var state:UIGestureRecognizer.State { get { .began } set {} }
    override func location(in view:UIView?) -> CGPoint { point }
}
