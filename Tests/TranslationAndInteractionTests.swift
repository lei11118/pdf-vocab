import XCTest
import UIKit
import PDFKit
@testable import PdfVocab

final class TranslationAndInteractionTests: XCTestCase {
    func testRepeatedWordsAreBoundToOccurrenceNotWordGlobalKey() throws {
        let source = "A function has a purpose. A function can be mathematical."
        let sentences = TranslationAlignment.sentences(text:source,page:4)
        XCTAssertEqual(sentences.count,2)
        XCTAssertNotEqual(sentences[0].id,sentences[1].id)
        var first = sentences[0],second = sentences[1]
        first.target = "一个功能有其用途。"; second.target = "一个函数可以是数学的。"
        first.links = TranslationAlignment.align(source:first.source,target:first.target,lookup:{ _ in "功能；函数" })
        second.links = TranslationAlignment.align(source:second.source,target:second.target,lookup:{ _ in "功能；函数" })
        let a = try XCTUnwrap(first.links.first { $0.word == "function" })
        let b = try XCTUnwrap(second.links.first { $0.word == "function" })
        XCTAssertEqual(a.meaning,"功能"); XCTAssertEqual(b.meaning,"函数")
        XCTAssertFalse(a.reviewed); XCTAssertLessThan(a.confidence,1)
        let detail = TranslationAlignment.correction(in:[first,second],term:"function",location:TranslationLocation(page:4,character:second.start+b.sourceStart))
        XCTAssertTrue(detail.contains("函数")); XCTAssertTrue(detail.contains("自动链接·待校对"))
        XCTAssertFalse(detail.contains("一个功能有其用途"))
    }
    func testMissingLinkNeverInventsVerifiedMeaningAndUTF16RangesRoundTrip() throws {
        var sentence = try XCTUnwrap(TranslationAlignment.sentences(text:"🧮 A function exists.",page:1).first)
        sentence.target = "存在某种关系。"
        sentence.links = TranslationAlignment.align(source:sentence.source,target:sentence.target,lookup:{ _ in "功能；函数" })
        let link = try XCTUnwrap(sentence.links.first { $0.word == "function" })
        XCTAssertNil(link.meaning); XCTAssertNil(link.targetStart)
        XCTAssertEqual((sentence.source as NSString).substring(with:NSRange(location:link.sourceStart,length:link.sourceLength)),"function")
        let detail = TranslationAlignment.correction(in:[sentence],term:"function",location:TranslationLocation(page:1,character:sentence.start+link.sourceStart))
        XCTAssertTrue(detail.contains("尚无可靠词语链接")); XCTAssertFalse(detail.contains("人工已确认"))
        XCTAssertEqual(try JSONDecoder().decode(TranslatedSentence.self,from:JSONEncoder().encode(sentence)),sentence)
    }
    @MainActor func testTranslationCachePersistsReviewedOccurrence() async throws {
        let db = try XCTUnwrap(AppDatabase.shared),doc = "translation-test-\(UUID().uuidString)"
        let repository = DocumentTranslationRepository(db:db)
        _ = try repository.load(doc:doc)
        defer { try? db.dbQueue.write { db in try db.execute(sql:"DELETE FROM document_translation WHERE doc=?",arguments:[doc]) } }
        var value = try XCTUnwrap(TranslationAlignment.sentences(text:"A function exists.",page:2).first)
        value.target = "函数存在。"; value.reviewed = true
        value.links = TranslationAlignment.align(source:value.source,target:value.target,lookup:{ _ in "函数" })
        let index = try XCTUnwrap(value.links.firstIndex { $0.word == "function" })
        value.links[index].reviewed = true
        try repository.save(doc:doc,records:[value])
        XCTAssertEqual(try repository.load(doc:doc),[value])
        var obsolete = value; obsolete.target = "stale machine output"; obsolete.reviewed = false
        for index in obsolete.links.indices { obsolete.links[index].reviewed = false }
        try repository.save(doc:doc,records:[obsolete],preservingReviews:true)
        XCTAssertEqual(try repository.load(doc:doc),[value],"Background results must never overwrite a human correction")
        XCTAssertTrue(TranslationAlignment.correction(in:[value],term:"function",location:TranslationLocation(page:2,character:value.start+value.links[index].sourceStart)).contains("人工已确认"))
    }
    @MainActor func testDeletingDocumentRemovesItsFullTextTranslationCache() throws {
        let db = try XCTUnwrap(AppDatabase.shared),store = DocumentStore(db:db)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("translation-delete-\(UUID().uuidString).pdf")
        let data = UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:300,height:300)).pdfData { context in
            context.beginPage(); ("A function exists." as NSString).draw(at:CGPoint(x:30,y:60),withAttributes:[.font:UIFont.systemFont(ofSize:18)])
        }
        try data.write(to:url); defer { try? FileManager.default.removeItem(at:url) }
        let record = try store.importFile(from:url)
        let repository = DocumentTranslationRepository(db:db)
        _ = try repository.load(doc:record.sha256)
        let sentence = try XCTUnwrap(TranslationAlignment.sentences(text:"A function exists.",page:0).first)
        try repository.save(doc:record.sha256,records:[sentence])
        XCTAssertEqual(try repository.load(doc:record.sha256).count,1)
        try store.delete(record)
        XCTAssertTrue(try repository.load(doc:record.sha256).isEmpty)
    }
    @MainActor func testSameTermHoverMovesWithoutClearingTheCurrentPreview() async throws {
        let session = WordInteractionSession()
        session.setCorrection("【校对】第一处")
        session.hover("function",at:CGPoint(x:40,y:60))
        for _ in 0..<30 where session.preview == nil { try await Task.sleep(for:.milliseconds(30)) }
        XCTAssertNotNil(session.preview)
        session.setCorrection("【校对】第二处")
        session.hover("function",at:CGPoint(x:80,y:120))
        XCTAssertEqual(session.preview?.point,CGPoint(x:80,y:120))
        XCTAssertTrue(session.preview?.detail.contains("第二处") ?? false)
        XCTAssertFalse(session.preview?.detail.contains("第一处") ?? true)
        session.clear()
    }
    @MainActor func testSqueezeDuplicateRoutesDoNotToggleTwice() {
        let gate = ReaderSqueezeGate()
        XCTAssertTrue(gate.accept(at:10))
        XCTAssertFalse(gate.accept(at:10.001))
        XCTAssertFalse(gate.accept(at:10.05))
        XCTAssertTrue(gate.accept(at:10.15))
    }
    @MainActor func testSelectingCustomPenDoesNotRestoreOtherToolsOldPreferences() throws {
        let defaults = UserDefaults.standard
        let savedState = defaults.data(forKey:PencilToolStateStore.globalKey)
        let savedPresets = defaults.data(forKey:"pencil.customPresets.v1")
        defer {
            if let savedState { defaults.set(savedState,forKey:PencilToolStateStore.globalKey) } else { defaults.removeObject(forKey:PencilToolStateStore.globalKey) }
            if let savedPresets { defaults.set(savedPresets,forKey:"pencil.customPresets.v1") } else { defaults.removeObject(forKey:"pencil.customPresets.v1") }
        }
        let session = PencilToolSession()
        session.select(kind:.pen); session.setWidth(1); session.savePreset(name:"Test fine pen")
        let preset = try XCTUnwrap(session.presets.last)
        session.select(kind:.brush); session.setWidth(4)
        session.activate(PencilArcItem(id:preset.id,kind:.pen,name:preset.name,preset:preset))
        XCTAssertEqual(session.kind,.pen); XCTAssertEqual(session.widthIndex,1)
        session.select(kind:.brush); XCTAssertEqual(session.widthIndex,4)
    }
    func testFullDictionaryDetailKeepsAllSourcesAndEnglishDefinitions() {
        let entry = DictEntry(word:"function",phonetic:"fʌŋkʃən",translation:"【通用】\n功能\n【数学】\n函数\n【医学】\n机能",definition:"【WordNet】\na mathematical relation",pos:nil,collins:0,oxford:false,tags:[],bnc:0,frq:0)
        let detail = WordInteraction.fullDetail(entry)
        for value in ["fʌŋkʃən","功能","函数","机能","a mathematical relation"] { XCTAssertTrue(detail.contains(value)) }
    }
    @MainActor func testPagePreparationStreamsCurrentPageAndReadsCachedPhotoOCR() async throws {
        let db = try XCTUnwrap(AppDatabase.shared),doc = "stream-test-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(doc).pdf")
        let data = UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:400,height:500)).pdfData { context in
            context.beginPage()
            ("Native text can be translated immediately." as NSString).draw(at:CGPoint(x:20,y:60),withAttributes:[.font:UIFont.systemFont(ofSize:18)])
            context.beginPage() // photo page with a saved OCR checkpoint
        }
        try data.write(to:url)
        let ocr = OCRStore(db:db)
        ocr.save(docSha:doc,page:1,words:[OCRWord(text:"A function has 42 inputs.",x:0.1,y:0.1,w:0.6,h:0.05,line:0)])
        let model = DocumentTranslationModel(doc:doc,db:db)
        model.prioritize(1)
        var prepared:[Int] = []
        model.onPagePrepared = { page in
            prepared.append(page)
            if prepared.count == 1 { XCTAssertTrue(model.ready); XCTAssertEqual(model.parsedPages,1); XCTAssertEqual(model.records.first?.page,1) }
        }
        defer {
            try? FileManager.default.removeItem(at:url)
            try? db.dbQueue.write { db in
                for table in ["document_translation","ocr_word","ocr_status","ocr_page_status"] {
                    try db.execute(sql:"DELETE FROM \(table) WHERE \(table == "document_translation" ? "doc" : "docSha")=?",arguments:[doc])
                }
            }
        }
        await model.prepare(url:url,ocr:ocr)
        XCTAssertEqual(prepared,[1,0]); XCTAssertEqual(model.parsedPages,2)
        XCTAssertTrue(model.records.contains { $0.source.contains("42") && $0.source.contains(".") })
        XCTAssertEqual(model.pending.first?.page,1)
    }
    func testPhotoOCRPreservesNumbersAndSentenceBoundaries() throws {
        let size = CGSize(width:800,height:1000)
        let image = UIGraphicsImageRenderer(size:size).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin:.zero,size:size))
            ("A function has 42 inputs." as NSString).draw(at:CGPoint(x:80,y:200),withAttributes:[.font:UIFont.systemFont(ofSize:34),.foregroundColor:UIColor.black])
        }
        let data = UIGraphicsPDFRenderer(bounds:CGRect(origin:.zero,size:size)).pdfData { context in
            context.beginPage(); image.draw(in:CGRect(origin:.zero,size:size))
        }
        let page = try XCTUnwrap(PDFDocument(data:data)?.page(at:0))
        XCTAssertTrue(OCRService.needsOCR(page:page))
        let words = OCRService.recognize(page:page)
        XCTAssertTrue(words.contains { $0.text == "42" })
        XCTAssertTrue(words.contains { $0.text == "." })
        XCTAssertTrue(words.contains { $0.text.lowercased() == "function" })
    }
    @MainActor func testContextMeaningCanDifferFromLiteralSentenceAndSurviveSentenceTranslation() async throws {
        let db = try XCTUnwrap(AppDatabase.shared),doc = "context-test-\(UUID().uuidString)"
        let model = DocumentTranslationModel(doc:doc,db:db)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(doc).pdf")
        let data = UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:400,height:500)).pdfData { context in
            context.beginPage(); ("A function maps inputs to outputs." as NSString).draw(at:CGPoint(x:20,y:60),withAttributes:[.font:UIFont.systemFont(ofSize:18)])
        }
        try data.write(to:url)
        defer {
            try? FileManager.default.removeItem(at:url)
            try? db.dbQueue.write { db in
                try db.execute(sql:"DELETE FROM document_translation WHERE doc=?",arguments:[doc])
                try db.execute(sql:"DELETE FROM ocr_status WHERE docSha=?",arguments:[doc])
            }
        }
        await model.prepare(url:url,ocr:OCRStore(db:db))
        let original = try XCTUnwrap(model.records.first)
        let token = try XCTUnwrap(original.links.first { $0.word == "function" })
        try await model.acceptContext(sentence:original.id,offset:token.sourceStart,meaning:"数学中的映射关系",reason:"maps inputs to outputs 限定数学语境")
        var translated = original; translated.target = "输入与输出之间存在函数映射。"
        try await model.accept([translated])
        let result = try XCTUnwrap(model.records.first)
        XCTAssertEqual(result.links.first { $0.word == "function" }?.meaning,"数学中的映射关系")
        XCTAssertNil(result.links.first { $0.word == "function" }?.targetStart)
        let detail = model.correction(term:"function",location:TranslationLocation(page:0,character:token.sourceStart))
        XCTAssertTrue(detail.contains("语境释义·模型建议")); XCTAssertTrue(detail.contains("数学中的映射关系"))
    }

}
