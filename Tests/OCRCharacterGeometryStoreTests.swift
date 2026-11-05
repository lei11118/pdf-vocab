import Foundation
import GRDB
import XCTest
@testable import PdfVocab

@MainActor
final class OCRCharacterGeometryStoreTests: XCTestCase {
    func testFallbackPayloadRoundTripsWithFullCacheIdentity() throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let fixture = try makeFixture(documentSHA256: uniqueSHA(), pageIndex: 0)
        try insertDocument(fixture.page.documentSHA256, db: db)
        defer { cleanupDocument(fixture.page.documentSHA256, db: db) }

        let key = try OCRCharacterGeometryCacheKey.make(page: fixture.page,
                                                        line: fixture.line,
                                                        engineVersion: "vision-fast-ios-test")
        let payload = makePayload(key: key, page: fixture.page, line: fixture.line,
                                  fallback: .tooManyCandidates(17))
        let store = OCRCharacterGeometryStore(db: db)

        try store.save(payload)
        XCTAssertEqual(try store.load(key: key), payload)
        XCTAssertTrue(payload.refinement.boxes.isEmpty)
        XCTAssertEqual(payload.refinement.fallback, .tooManyCandidates(17))
    }

    func testCacheKeyChangesWithPageSourceLayoutOrEngine() throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let sha = uniqueSHA()
        let original = try makeFixture(documentSHA256: sha, pageIndex: 0)
        try insertDocument(sha, db: db)
        defer { cleanupDocument(sha, db: db) }

        let originalKey = try OCRCharacterGeometryCacheKey.make(page: original.page,
                                                                 line: original.line,
                                                                 engineVersion: "vision-fast-ios-test")
        let changedPage = try makeFixture(documentSHA256: sha, pageIndex: 1)
        let changedLayout = try makeFixture(documentSHA256: sha, pageIndex: 0, regionX: 11)
        let changedText = try makeFixture(documentSHA256: sha, pageIndex: 0, text: "words")
        let pageKey = try OCRCharacterGeometryCacheKey.make(page: changedPage.page,
                                                            line: changedPage.line,
                                                            engineVersion: "vision-fast-ios-test")
        let layoutKey = try OCRCharacterGeometryCacheKey.make(page: changedLayout.page,
                                                              line: changedLayout.line,
                                                              engineVersion: "vision-fast-ios-test")
        let textKey = try OCRCharacterGeometryCacheKey.make(page: changedText.page,
                                                            line: changedText.line,
                                                            engineVersion: "vision-fast-ios-test")
        let engineKey = try OCRCharacterGeometryCacheKey.make(page: original.page,
                                                              line: original.line,
                                                              engineVersion: "vision-fast-ios-test-2")

        XCTAssertNotEqual(originalKey.cacheKey, pageKey.cacheKey)
        XCTAssertNotEqual(originalKey.cacheKey, layoutKey.cacheKey)
        XCTAssertNotEqual(originalKey.cacheKey, textKey.cacheKey)
        XCTAssertNotEqual(originalKey.cacheKey, engineKey.cacheKey)
        XCTAssertEqual(originalKey.sourceRevision, 2)
        XCTAssertEqual(originalKey.geometryRevision, 1)
        XCTAssertEqual(originalKey.sourceTextSHA256.count, 64)
        XCTAssertEqual(originalKey.layoutSHA256.count, 64)

        let store = OCRCharacterGeometryStore(db: db)
        try store.save(makePayload(key: originalKey,
                                   page: original.page,
                                   line: original.line,
                                   fallback: .noSpatialCandidate))
        XCTAssertNil(try store.load(key: pageKey))
        XCTAssertNil(try store.load(key: layoutKey))
        XCTAssertNil(try store.load(key: textKey))
        XCTAssertNil(try store.load(key: engineKey))

        let stalePage = ContextOCRPage(documentSHA256: original.page.documentSHA256,
                                       pageIndex: original.page.pageIndex,
                                       revision: original.page.revision - 1,
                                       mediaBox: original.page.mediaBox,
                                       lines: original.page.lines)
        XCTAssertThrowsError(try OCRCharacterGeometryCacheKey.make(page: stalePage,
                                                                   line: original.line,
                                                                   engineVersion: "vision-fast-ios-test"))
    }

    func testCorruptAndMismatchedPayloadsAreRecoverableMisses() throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let fixture = try makeFixture(documentSHA256: uniqueSHA(), pageIndex: 0)
        try insertDocument(fixture.page.documentSHA256, db: db)
        defer { cleanupDocument(fixture.page.documentSHA256, db: db) }

        let key = try OCRCharacterGeometryCacheKey.make(page: fixture.page,
                                                        line: fixture.line,
                                                        engineVersion: "vision-fast-ios-test")
        let payload = makePayload(key: key, page: fixture.page, line: fixture.line,
                                  fallback: .alignmentRejected)
        let store = OCRCharacterGeometryStore(db: db)
        try store.save(payload)

        try db.dbQueue.write { database in
            try database.execute(sql: "UPDATE ocr_character_geometry SET payload = ? WHERE cacheKey = ?",
                                 arguments: [Data("{".utf8), key.cacheKey])
        }
        XCTAssertNil(try store.load(key: key), "Malformed JSON must be a recoverable cache miss")
        try store.save(payload)
        XCTAssertEqual(try store.load(key: key), payload)

        let mismatchedSource = OCRCharacterRefinementResult(sourceText: "different raw source",
                                                            mediaBox: payload.refinement.mediaBox,
                                                            roi: payload.refinement.roi,
                                                            observations: payload.refinement.observations,
                                                            selectedObservationOrdinal: payload.refinement.selectedObservationOrdinal,
                                                            boxes: payload.refinement.boxes,
                                                            fallback: payload.refinement.fallback)
        let mismatchedSourcePayload = OCRCharacterGeometryCachePayload(key: key,
                                                                       refinement: mismatchedSource)
        XCTAssertThrowsError(try store.save(mismatchedSourcePayload)) { error in
            guard let storeError = error as? OCRCharacterGeometryStoreError,
                  case .payloadIdentityMismatch = storeError else {
                return XCTFail("Expected an explicit payload identity error, received \(error)")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try db.dbQueue.write { database in
            try database.execute(sql: "UPDATE ocr_character_geometry SET payload = ? WHERE cacheKey = ?",
                                 arguments: [try encoder.encode(mismatchedSourcePayload), key.cacheKey])
        }
        XCTAssertNil(try store.load(key: key), "A source text digest mismatch must be a recoverable cache miss")
        try store.save(payload)
        XCTAssertEqual(try store.load(key: key), payload)

        let otherKey = try OCRCharacterGeometryCacheKey.make(page: fixture.page,
                                                             line: fixture.line,
                                                             engineVersion: "different-engine")
        let mismatchedPayload = makePayload(key: otherKey, page: fixture.page, line: fixture.line,
                                            fallback: .noSpatialCandidate)
        try db.dbQueue.write { database in
            try database.execute(sql: "UPDATE ocr_character_geometry SET payload = ? WHERE cacheKey = ?",
                                 arguments: [try encoder.encode(mismatchedPayload), key.cacheKey])
        }
        XCTAssertNil(try store.load(key: key), "Payload identity mismatch must be a recoverable cache miss")
        try store.save(payload)
        XCTAssertEqual(try store.load(key: key), payload)

        try db.dbQueue.write { database in
            try database.execute(sql: "UPDATE ocr_character_geometry SET blockID = ? WHERE cacheKey = ?",
                                 arguments: ["other-block", key.cacheKey])
        }
        XCTAssertNil(try store.load(key: key), "Mismatched row columns must be a recoverable cache miss")
        try store.save(payload)
        XCTAssertEqual(try store.load(key: key), payload)
    }

    func testLRUEvictionRespectsPayloadByteBudget() throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let sha = uniqueSHA()
        try insertDocument(sha, db: db)
        defer { cleanupDocument(sha, db: db) }

        let fixtures = try (0..<3).map { pageIndex in
            try makeFixture(documentSHA256: sha, pageIndex: pageIndex, blockID: "block-00")
        }
        let keys = try fixtures.map { fixture in
            try OCRCharacterGeometryCacheKey.make(page: fixture.page,
                                                  line: fixture.line,
                                                  engineVersion: "vision-fast-ios-test")
        }
        let payloads = zip(keys, fixtures).map { key, fixture in
            makePayload(key: key, page: fixture.page, line: fixture.line,
                        fallback: .noSpatialCandidate)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadBytes = try encoder.encode(payloads[0]).count
        XCTAssertEqual(try encoder.encode(payloads[1]).count, payloadBytes)
        XCTAssertEqual(try encoder.encode(payloads[2]).count, payloadBytes)

        let store = OCRCharacterGeometryStore(db: db,
                                             maximumTotalBytes: payloadBytes * 2,
                                             maximumPayloadBytes: payloadBytes + 1)
        try store.save(payloads[0])
        try store.save(payloads[1])
        XCTAssertNotNil(try store.load(key: keys[0]), "Access should refresh the first entry's LRU position")
        try store.save(payloads[2])

        XCTAssertNotNil(try store.load(key: keys[0]))
        XCTAssertNil(try store.load(key: keys[1]), "The least recently used entry should be evicted")
        XCTAssertNotNil(try store.load(key: keys[2]))
    }

    func testPayloadLimitProducesExplicitStoreError() throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let fixture = try makeFixture(documentSHA256: uniqueSHA(), pageIndex: 0)
        try insertDocument(fixture.page.documentSHA256, db: db)
        defer { cleanupDocument(fixture.page.documentSHA256, db: db) }

        let key = try OCRCharacterGeometryCacheKey.make(page: fixture.page,
                                                        line: fixture.line,
                                                        engineVersion: "vision-fast-ios-test")
        let payload = makePayload(key: key, page: fixture.page, line: fixture.line,
                                  fallback: .noTrustedCharacterBoxes)
        let store = OCRCharacterGeometryStore(db: db,
                                              maximumTotalBytes: 4096,
                                              maximumPayloadBytes: 1)
        let permissiveStore = OCRCharacterGeometryStore(db: db,
                                                        maximumTotalBytes: 4096,
                                                        maximumPayloadBytes: 4096)
        try permissiveStore.save(payload)
        XCTAssertNil(try store.load(key: key), "A row above the per-entry load cap must be a miss")
        XCTAssertThrowsError(try store.save(payload)) { error in
            guard let storeError = error as? OCRCharacterGeometryStoreError,
                  case .payloadTooLarge = storeError else {
                return XCTFail("Expected an explicit per-entry size error, received \(error)")
            }
        }
    }

    func testDerivedCacheDoesNotMutateBaseOrLegacyOCRAndCascadesWithDocument() throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let fixture = try makeFixture(documentSHA256: uniqueSHA(), pageIndex: 0)
        try insertDocument(fixture.page.documentSHA256, db: db)
        defer { cleanupDocument(fixture.page.documentSHA256, db: db) }

        let baseStore = ContextOCRStore(db: db)
        try baseStore.save(fixture.page)
        let originalWords = [OCRWord(text: "word", x: 0.1, y: 0.2, w: 0.3, h: 0.05, line: 0)]
        let legacyStore = OCRStore(db: db)
        legacyStore.save(docSha: fixture.page.documentSHA256, page: 0, words: originalWords)
        let oldBase = try XCTUnwrap(baseStore.load(documentSHA256: fixture.page.documentSHA256,
                                                  pageIndex: 0,
                                                  revision: ContextOCRPage.currentRevision))
        let oldCounts = try legacyRowCounts(fixture.page.documentSHA256, db: db)

        let key = try OCRCharacterGeometryCacheKey.make(page: fixture.page,
                                                        line: fixture.line,
                                                        engineVersion: "vision-fast-ios-test")
        let payload = makePayload(key: key, page: fixture.page, line: fixture.line,
                                  fallback: .noTrustedCharacterBoxes)
        try OCRCharacterGeometryStore(db: db).save(payload)

        XCTAssertEqual(try baseStore.load(documentSHA256: fixture.page.documentSHA256,
                                          pageIndex: 0,
                                          revision: ContextOCRPage.currentRevision), oldBase)
        XCTAssertEqual(legacyStore.words(docSha: fixture.page.documentSHA256, page: 0).map(\.text), ["word"])
        let newCounts = try legacyRowCounts(fixture.page.documentSHA256, db: db)
        XCTAssertEqual(newCounts.0, oldCounts.0)
        XCTAssertEqual(newCounts.1, oldCounts.1)

        try db.dbQueue.write { database in
            try database.execute(sql: "DELETE FROM document WHERE sha256 = ?",
                                 arguments: [fixture.page.documentSHA256])
        }
        let remaining = try Int.fetchOne(db.dbQueue,
                                         sql: "SELECT COUNT(*) FROM ocr_character_geometry WHERE docSha = ?",
                                         arguments: [fixture.page.documentSHA256]) ?? 0
        XCTAssertEqual(remaining, 0, "Deleting the owning document must cascade derived cache rows")
        XCTAssertEqual(legacyStore.words(docSha: fixture.page.documentSHA256, page: 0).map(\.text), ["word"],
                       "The derived cache must not delete or rewrite legacy OCR rows")
    }

    private func makeFixture(documentSHA256: String,
                             pageIndex: Int,
                             blockID: String = "block-00",
                             text: String = "word",
                             regionX: Double = 10) throws -> (page: ContextOCRPage, line: OCRLine) {
        let media = try XCTUnwrap(SourceRect(x: 0, y: 0, width: 612, height: 792))
        let pageRect = try XCTUnwrap(SourceRect(x: 40, y: 600, width: 100, height: 20))
        let region = try XCTUnwrap(SourceRect(x: regionX, y: 590, width: 200, height: 50))
        let tokenSpan = UTF16Span(location: 0, length: (text as NSString).length)
        let token = SourceToken(documentSHA256: documentSHA256,
                                pageIndex: pageIndex,
                                span: tokenSpan,
                                sourceSurface: text,
                                kind: .word,
                                blockID: blockID,
                                geometryQuality: .word)
        let tokenGeometry = SourceTokenGeometry(tokenID: token.id,
                                                span: tokenSpan,
                                                rect: pageRect,
                                                quality: .word)
        let line = OCRLine(blockID: blockID,
                           candidates: [OCRCandidate(text: text, confidence: 0.9)],
                           regionRect: region,
                           pageRect: pageRect,
                           tokens: [token],
                           tokenGeometry: [tokenGeometry])
        let page = ContextOCRPage(documentSHA256: documentSHA256,
                                  pageIndex: pageIndex,
                                  revision: ContextOCRPage.currentRevision,
                                  mediaBox: media,
                                  lines: [line])
        return (page, line)
    }

    private func makePayload(key: OCRCharacterGeometryCacheKey,
                             page: ContextOCRPage,
                             line: OCRLine,
                             fallback: OCRCharacterRefinementFallback) -> OCRCharacterGeometryCachePayload {
        let refinement = OCRCharacterRefinementResult(sourceText: line.sourceText,
                                                       mediaBox: page.mediaBox,
                                                       roi: line.regionRect,
                                                       observations: [],
                                                       selectedObservationOrdinal: nil,
                                                       boxes: [],
                                                       fallback: fallback)
        return OCRCharacterGeometryCachePayload(key: key, refinement: refinement)
    }

    private func insertDocument(_ sha: String, db: AppDatabase) throws {
        try db.dbQueue.write { database in
            try database.execute(sql: """
                INSERT INTO document (sha256, title, fileName, pageCount, hasTextLayer, importedAt,
                                      lastPage, pageX, pageY, zoom, zoomAuto)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [sha, "OCR geometry cache fixture", "fixture.pdf", 3, false,
                                Date(), 0, 0, 0, 1, true])
        }
    }

    private func cleanupDocument(_ sha: String, db: AppDatabase) {
        try? db.dbQueue.write { database in
            try database.execute(sql: "DELETE FROM ocr_word WHERE docSha = ?", arguments: [sha])
            try database.execute(sql: "DELETE FROM ocr_status WHERE docSha = ?", arguments: [sha])
            try database.execute(sql: "DELETE FROM document WHERE sha256 = ?", arguments: [sha])
        }
    }

    private func legacyRowCounts(_ sha: String, db: AppDatabase) throws -> (Int, Int) {
        try db.dbQueue.read { database in
            (try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM ocr_word WHERE docSha = ?", arguments: [sha]) ?? 0,
             try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM ocr_status WHERE docSha = ?", arguments: [sha]) ?? 0)
        }
    }

    private func uniqueSHA() -> String { "ocr-geometry-test-\(UUID().uuidString)" }
}
