import CoreText
import Foundation
import PDFKit
import UIKit
import XCTest
@testable import PdfVocab

@MainActor
final class ContextOCRWorkerTests: XCTestCase {
    func testNativeTextPageReturnsNilEvenWithStoredContextOCR() async throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let url = try makePDFFile(text: "A native searchable PDF page with enough text.")
        defer { try? FileManager.default.removeItem(at: url) }

        let documentSHA256 = "context-ocr-worker-\(UUID().uuidString)"
        try insertDocumentRecord(documentSHA256, pageCount: 1, hasTextLayer: true, db: db)
        defer { try? deleteDocumentRecord(documentSHA256, db: db) }

        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let cachedPage = ContextOCRPage(documentSHA256: documentSHA256,
                                        pageIndex: 0,
                                        revision: ContextOCRPage.currentRevision,
                                        mediaBox: try XCTUnwrap(SourceRect(rect: page.bounds(for: .mediaBox))),
                                        lines: [])
        let contextStore = ContextOCRStore(db: db)
        try contextStore.save(cachedPage)

        let result = try await ContextOCRWorker.shared.recognizeContextPage(
            url: url,
            documentSHA256: documentSHA256,
            pageIndex: 0,
            db: db)

        XCTAssertNil(result)
        let refined = try await ContextOCRWorker.shared.refineContextLine(url: url,
                                                                          documentSHA256: documentSHA256,
                                                                          pageIndex: 0,
                                                                          blockID: "native-block",
                                                                          db: db)
        XCTAssertNil(refined, "Native text pages must not enter the fast OCR path")
        XCTAssertEqual(try contextStore.load(documentSHA256: documentSHA256,
                                             pageIndex: 0,
                                             revision: ContextOCRPage.currentRevision), cachedPage)
    }

    func testMissingBlockDoesNotCreateOrRewriteContextPage() async throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let url = try makePDFFile(text: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        let documentSHA256 = "missing-context-ocr-block-\(UUID().uuidString)"
        try insertDocumentRecord(documentSHA256, pageCount: 1, hasTextLayer: false, db: db)
        defer { try? deleteDocumentRecord(documentSHA256, db: db) }

        let media = try XCTUnwrap(SourceRect(x: 0, y: 0, width: 612, height: 792))
        let region = try XCTUnwrap(SourceRect(x: 0, y: 0, width: 612, height: 792))
        let lineRect = try XCTUnwrap(SourceRect(x: 40, y: 700, width: 200, height: 24))
        let line = OCRLine(blockID: "present-block",
                           candidates: [OCRCandidate(text: "scanned source line", confidence: 0.9)],
                           regionRect: region,
                           pageRect: lineRect,
                           tokens: [],
                           tokenGeometry: [])
        let basePage = ContextOCRPage(documentSHA256: documentSHA256,
                                      pageIndex: 0,
                                      revision: ContextOCRPage.currentRevision,
                                      mediaBox: media,
                                      lines: [line])
        let store = ContextOCRStore(db: db)
        try store.save(basePage)

        let result = try await ContextOCRWorker.shared.refineContextLine(url: url,
                                                                         documentSHA256: documentSHA256,
                                                                         pageIndex: 0,
                                                                         blockID: "missing-block",
                                                                         db: db)

        XCTAssertNil(result)
        XCTAssertEqual(try store.load(documentSHA256: documentSHA256,
                                      pageIndex: 0,
                                      revision: ContextOCRPage.currentRevision), basePage)
    }

    func testInvalidURLAndPageIndexThrowExplicitErrors() async throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextOCRWorker-\(UUID().uuidString).pdf")

        do {
            _ = try await ContextOCRWorker.shared.recognizeContextPage(
                url: missingURL,
                documentSHA256: "missing-\(UUID().uuidString)",
                pageIndex: 0,
                db: db)
            XCTFail("An unavailable PDF URL must fail explicitly")
        } catch ContextOCRWorkerError.invalidDocument {
            // Expected.
        } catch {
            XCTFail("Unexpected worker error: \(error)")
        }

        let url = try makePDFFile(text: "A native searchable PDF page with enough text.")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await ContextOCRWorker.shared.recognizeContextPage(
                url: url,
                documentSHA256: "wrong-page-\(UUID().uuidString)",
                pageIndex: 1,
                db: db)
            XCTFail("An index past the document end must fail explicitly")
        } catch let error as ContextOCRWorkerError {
            guard case .invalidPageIndex(index: 1, pageCount: 1) = error else {
                return XCTFail("Unexpected worker error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

    }

    func testPreCancelledTaskDoesNotPersistEitherOCRRepresentation() async throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let url = try makePDFFile(text: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        let documentSHA256 = "cancelled-context-ocr-worker-\(UUID().uuidString)"
        try insertDocumentRecord(documentSHA256, pageCount: 1, hasTextLayer: false, db: db)
        defer { try? deleteDocumentRecord(documentSHA256, db: db) }

        let gate = WorkerTestGate()
        let task = Task<ContextOCRPage?, Error> {
            await gate.pause()
            return try await ContextOCRWorker.shared.recognizeContextPage(
                url: url,
                documentSHA256: documentSHA256,
                pageIndex: 0,
                db: db)
        }
        await gate.waitUntilPaused()
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("A pre-cancelled OCR task must throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected worker error: \(error)")
        }

        XCTAssertNil(try ContextOCRStore(db: db).load(documentSHA256: documentSHA256,
                                                      pageIndex: 0,
                                                      revision: ContextOCRPage.currentRevision))
        XCTAssertTrue(OCRStore(db: db).words(docSha: documentSHA256, page: 0).isEmpty)
    }

    func testBlankScanPersistsEmptyContextPageAndLegacyPageCanReusePass() async throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let url = try makePDFFile(text: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        let documentSHA256 = "blank-context-ocr-worker-\(UUID().uuidString)"
        try insertDocumentRecord(documentSHA256, pageCount: 1, hasTextLayer: false, db: db)
        defer {
            try? db.dbQueue.write { database in
                try database.execute(sql: "DELETE FROM ocr_word WHERE docSha = ?", arguments: [documentSHA256])
                try database.execute(sql: "DELETE FROM ocr_status WHERE docSha = ?", arguments: [documentSHA256])
                try database.execute(sql: "DELETE FROM document WHERE sha256 = ?", arguments: [documentSHA256])
            }
        }

        try await db.dbQueue.write { database in
            try database.execute(sql: """
                INSERT INTO context_ocr_page (docSha, page, revision, payload)
                VALUES (?, ?, ?, ?)
                """, arguments: [documentSHA256, 0, ContextOCRPage.currentRevision, Data("{".utf8)])
        }

        let worker = ContextOCRWorker.shared
        let actualPageCount = try await worker.pageCount(url: url, documentSHA256: documentSHA256)
        XCTAssertEqual(actualPageCount, 1)
        let generated = try await worker.recognizeContextPage(url: url,
                                                               documentSHA256: documentSHA256,
                                                               pageIndex: 0,
                                                               db: db)
        let page = try XCTUnwrap(generated)
        XCTAssertTrue(page.lines.isEmpty, "A successfully recognized blank scan is a stored empty page, not nil")
        XCTAssertEqual(try ContextOCRStore(db: db).load(documentSHA256: documentSHA256,
                                                        pageIndex: 0,
                                                        revision: ContextOCRPage.currentRevision), page)

        let legacyWords = try await worker.recognizeLegacyPage(url: url,
                                                                documentSHA256: documentSHA256,
                                                                pageIndex: 0,
                                                                store: OCRStore(db: db))
        XCTAssertTrue(legacyWords.isEmpty)
        XCTAssertTrue(OCRStore(db: db).words(docSha: documentSHA256, page: 0).isEmpty)
    }

    func testPhotoOnlyPageRefinementPersistsOnlyDerivedGeometryAndReusesIt() async throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let sourceText = "charge + beta 3.2"
        let url = try makePhotoOnlyPDFFile(text: sourceText)
        defer { try? FileManager.default.removeItem(at: url) }

        let documentSHA256 = "context-ocr-refinement-worker-\(UUID().uuidString)"
        try insertDocumentRecord(documentSHA256, pageCount: 1, hasTextLayer: false, db: db)
        defer {
            try? db.dbQueue.write { database in
                try database.execute(sql: "DELETE FROM ocr_word WHERE docSha = ?", arguments: [documentSHA256])
                try database.execute(sql: "DELETE FROM ocr_status WHERE docSha = ?", arguments: [documentSHA256])
                try database.execute(sql: "DELETE FROM document WHERE sha256 = ?", arguments: [documentSHA256])
            }
        }

        let pdfPage = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        XCTAssertTrue((pdfPage.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "The fixture must contain only a raster image, without a searchable text layer")

        let worker = ContextOCRWorker.shared
        let recognizedBase = try await worker.recognizeContextPage(url: url,
                                                                   documentSHA256: documentSHA256,
                                                                   pageIndex: 0,
                                                                   db: db)
        let basePage = try XCTUnwrap(recognizedBase)
        let baseLine = try XCTUnwrap(basePage.lines.first(where: {
            !$0.blockID.isEmpty && !$0.sourceText.isEmpty && $0.pageRect != nil && !$0.tokens.isEmpty
        }), "Accurate OCR should provide a source line with semantic tokens")
        let baseWords = OCRStore(db: db).words(docSha: documentSHA256, page: 0)
        XCTAssertFalse(baseWords.isEmpty, "The shared accurate pass should retain legacy word boxes")
        XCTAssertFalse(baseLine.tokens.contains { $0.geometryQuality == .verifiedCharacter })

        let refinedResult = try await worker.refineContextLine(url: url,
                                                               documentSHA256: documentSHA256,
                                                               pageIndex: 0,
                                                               blockID: baseLine.blockID,
                                                               db: db)
        let refinedPage = try XCTUnwrap(refinedResult)
        let refinedLine = try XCTUnwrap(refinedPage.lines.first(where: { $0.blockID == baseLine.blockID }))
        XCTAssertTrue(refinedLine.tokens.contains { $0.geometryQuality == .verifiedCharacter },
                      "The actor's fast OCR result should promote at least one token through the composer")
        XCTAssertTrue(refinedLine.sourceText.utf16.elementsEqual(baseLine.sourceText.utf16))
        XCTAssertEqual(refinedLine.candidates.count, baseLine.candidates.count)
        for (oldCandidate, newCandidate) in zip(baseLine.candidates, refinedLine.candidates) {
            XCTAssertTrue(newCandidate.text.utf16.elementsEqual(oldCandidate.text.utf16))
            XCTAssertEqual(newCandidate.confidence, oldCandidate.confidence)
        }
        XCTAssertEqual(refinedLine.tokens.map(\.id), baseLine.tokens.map(\.id))
        XCTAssertEqual(refinedLine.tokens.map(\.span), baseLine.tokens.map(\.span))

        let contextStore = ContextOCRStore(db: db)
        XCTAssertEqual(try contextStore.load(documentSHA256: documentSHA256,
                                             pageIndex: 0,
                                             revision: ContextOCRPage.currentRevision), basePage,
                       "The derived page must not overwrite the accurate base OCR payload")
        assertLegacyWords(baseWords, equalTo: OCRStore(db: db).words(docSha: documentSHA256, page: 0))

        let cachedResult = try await worker.recognizeContextPage(url: url,
                                                                 documentSHA256: documentSHA256,
                                                                 pageIndex: 0,
                                                                 db: db)
        let cachedPage = try XCTUnwrap(cachedResult)
        XCTAssertEqual(cachedPage, refinedPage,
                       "A later page load should revalidate and compose the persisted character geometry")
        XCTAssertEqual(try contextStore.load(documentSHA256: documentSHA256,
                                             pageIndex: 0,
                                             revision: ContextOCRPage.currentRevision), basePage)
        assertLegacyWords(baseWords, equalTo: OCRStore(db: db).words(docSha: documentSHA256, page: 0))
    }

    private func makePDFFile(text: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextOCRWorker-\(UUID().uuidString).pdf")
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            if let text {
                (text as NSString).draw(at: CGPoint(x: 48, y: 80), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 20)
                ])
            }
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func makePhotoOnlyPDFFile(text: String) throws -> URL {
        let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let baseline = CGPoint(x: 82, y: 406)
        let font = CTFontCreateWithName("Helvetica" as CFString, 52, nil)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let attributedText = NSAttributedString(string: text, attributes: [fontKey: font])
        let ctLine = CTLineCreateWithAttributedString(attributedText)
        let nativePDF = UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
            context.beginPage()
            let cgContext = context.cgContext
            cgContext.saveGState()
            cgContext.translateBy(x: 0, y: pageBounds.height)
            cgContext.scaleBy(x: 1, y: -1)
            cgContext.textMatrix = .identity
            cgContext.textPosition = baseline
            cgContext.setFillColor(UIColor.black.cgColor)
            CTLineDraw(ctLine, cgContext)
            cgContext.restoreGState()
        }
        let nativePage = try XCTUnwrap(PDFDocument(data: nativePDF)?.page(at: 0))
        let raster = nativePage.thumbnail(of: CGSize(width: pageBounds.width * 2,
                                                     height: pageBounds.height * 2),
                                          for: .mediaBox)
        let photoPDF = UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
            context.beginPage()
            raster.draw(in: pageBounds)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextOCRWorker-photo-\(UUID().uuidString).pdf")
        try photoPDF.write(to: url, options: .atomic)
        return url
    }

    private func assertLegacyWords(_ actual: [OCRWord],
                                   equalTo expected: [OCRWord],
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualWord, expectedWord) in zip(actual, expected) {
            XCTAssertEqual(actualWord.text, expectedWord.text, file: file, line: line)
            XCTAssertEqual(actualWord.x, expectedWord.x, file: file, line: line)
            XCTAssertEqual(actualWord.y, expectedWord.y, file: file, line: line)
            XCTAssertEqual(actualWord.w, expectedWord.w, file: file, line: line)
            XCTAssertEqual(actualWord.h, expectedWord.h, file: file, line: line)
            XCTAssertEqual(actualWord.line, expectedWord.line, file: file, line: line)
        }
    }

    private func insertDocumentRecord(_ documentSHA256: String,
                                      pageCount: Int,
                                      hasTextLayer: Bool,
                                      db: AppDatabase) throws {
        try db.dbQueue.write { database in
            try database.execute(sql: """
                INSERT INTO document (sha256, title, fileName, pageCount, hasTextLayer, importedAt,
                                      lastPage, pageX, pageY, zoom, zoomAuto)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [documentSHA256, "Context OCR worker fixture", "fixture.pdf", pageCount,
                                hasTextLayer, Date(), 0, 0, 0, 1, true])
        }
    }

    private func deleteDocumentRecord(_ documentSHA256: String, db: AppDatabase) throws {
        try db.dbQueue.write { database in
            try database.execute(sql: "DELETE FROM document WHERE sha256 = ?", arguments: [documentSHA256])
        }
    }
}

private actor WorkerTestGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var arrivalContinuation: CheckedContinuation<Void, Never>?
    private var hasArrived = false

    func pause() async {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            hasArrived = true
            arrivalContinuation?.resume()
            arrivalContinuation = nil
        }
    }

    func waitUntilPaused() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { continuation in
            arrivalContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
