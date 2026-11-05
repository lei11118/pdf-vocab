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
        XCTAssertEqual(try contextStore.load(documentSHA256: documentSHA256,
                                             pageIndex: 0,
                                             revision: ContextOCRPage.currentRevision), cachedPage)
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

        try db.dbQueue.write { database in
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
