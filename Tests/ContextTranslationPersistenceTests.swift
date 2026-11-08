import Foundation
import GRDB
import XCTest
@testable import PdfVocab

@MainActor
final class ContextTranslationPersistenceTests: XCTestCase {
    func testValidatedPayloadSurvivesServiceInstancesAndIsRecheckedForEachSelection() async throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let documentSHA256 = uniqueDocumentSHA()
        try insertDocument(documentSHA256, db: db)
        defer { cleanupDocument(documentSHA256, db: db) }

        let store = ContextTranslationStore(db: db)
        let request = try persistedRequest(documentSHA256: documentSHA256, selected: "read")
        let calls = PersistenceTranslationCounter()
        let translator: ContextualTranslationService.Translator = { request, _, _, _ in
            await calls.record()
            return try makePersistedPayload(request)
        }
        let firstService = ContextualTranslationService(isEnabled: { true }, payloadStore: store)
        let first = try await firstService.translate(request,
                                                    sourceLanguageIdentifier: "en",
                                                    targetLanguageIdentifier: "zh-Hans",
                                                    backendVersion: "fixture-v1",
                                                    using: translator)
        let secondService = ContextualTranslationService(isEnabled: { true }, payloadStore: store)
        let second = try await secondService.translate(request,
                                                      sourceLanguageIdentifier: "en",
                                                      targetLanguageIdentifier: "zh-Hans",
                                                      backendVersion: "fixture-v1",
                                                      using: translator)

        XCTAssertEqual(first.sourcePhrase, "read")
        XCTAssertEqual(second.sourcePhrase, "read")
        XCTAssertEqual(second.translatedPhrase, "thing")
        let translationCalls = await calls.count
        XCTAssertEqual(translationCalls, 1, "A validated snapshot should be reusable by another service instance")

        let otherSelection = try persistedRequest(documentSHA256: documentSHA256, selected: "books")
        let thirdService = ContextualTranslationService(isEnabled: { true }, payloadStore: store)
        let third = try await thirdService.translate(otherSelection,
                                                    sourceLanguageIdentifier: "en",
                                                    targetLanguageIdentifier: "zh-Hans",
                                                    backendVersion: "fixture-v1",
                                                    using: translator)
        XCTAssertEqual(third.sourcePhrase, "books")
        let callsAfterOtherSelection = await calls.count
        XCTAssertEqual(callsAfterOtherSelection, 2,
                       "A cached payload missing the newly selected token must be translated again")
    }

    func testPersistentIdentitySeparatesDocumentLanguageBackendAndAlgorithm() throws {
        let request = try persistedRequest(documentSHA256: "identity-document-a", selected: "read")
        let otherDocument = try persistedRequest(documentSHA256: "identity-document-b", selected: "read")
        let ordinaryPhraseSelection = try persistedRequest(documentSHA256: "identity-document-a",
                                                           selected: "read books")
        let verifiedPhraseSelection = try persistedRequest(documentSHA256: "identity-document-a",
                                                            selected: "read books",
                                                            verifiedPhraseGroup: true)
        func key(_ request: ContextualTranslationRequest,
                 source: String = "en",
                 target: String = "zh-Hans",
                 backend: String = "fixture-v1",
                 algorithm: String = ContextualTranslationService.contextAlgorithmVersion) -> String? {
            ContextTranslationPayloadCacheIdentity.cacheKey(request: request,
                                                             sourceLanguageIdentifier: source,
                                                             targetLanguageIdentifier: target,
                                                             backendVersion: backend,
                                                             contextAlgorithmVersion: algorithm)
        }

        let original = try XCTUnwrap(key(request))
        XCTAssertNotEqual(original, key(otherDocument))
        XCTAssertNotEqual(original, key(request, source: "fr"))
        XCTAssertNotEqual(original, key(request, target: "ja"))
        XCTAssertNotEqual(original, key(request, backend: "fixture-v2"))
        XCTAssertNotEqual(original, key(request, algorithm: "layout-block-v2"))
        XCTAssertNotEqual(try XCTUnwrap(key(ordinaryPhraseSelection)),
                           try XCTUnwrap(key(verifiedPhraseSelection)))
        XCTAssertEqual(original.count, 64)
    }

    func testInMemoryCandidateCacheSeparatesDocumentsWithIdenticalTextAndSelection() async throws {
        let service = ContextualTranslationService(isEnabled: { true })
        let calls = PersistenceTranslationCounter()
        let firstRequest = try persistedRequest(documentSHA256: "candidate-document-a", selected: "read")
        let secondRequest = try persistedRequest(documentSHA256: "candidate-document-b", selected: "read")
        let translator: ContextualTranslationService.Translator = { request, _, _, _ in
            await calls.record()
            return try makePersistedPayload(request)
        }

        _ = try await service.translate(firstRequest,
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "fixture-v1",
                                        using: translator)
        _ = try await service.translate(secondRequest,
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "fixture-v1",
                                        using: translator)

        let translationCalls = await calls.count
        XCTAssertEqual(translationCalls, 2)
    }

    func testCorruptAndMissingAlignmentAttributesAreCacheMisses() async throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let store = ContextTranslationStore(db: db)
        let calls = PersistenceTranslationCounter()
        let translator: ContextualTranslationService.Translator = { request, _, _, _ in
            await calls.record()
            return try makePersistedPayload(request)
        }

        let corruptDocument = uniqueDocumentSHA()
        try insertDocument(corruptDocument, db: db)
        defer { cleanupDocument(corruptDocument, db: db) }
        let corruptRequest = try persistedRequest(documentSHA256: corruptDocument, selected: "read")
        let corruptKey = try XCTUnwrap(persistenceKey(corruptRequest))
        _ = try store.save(cacheKey: corruptKey,
                           documentSHA256: corruptDocument,
                           payload: Data("{".utf8))
        let corruptService = ContextualTranslationService(isEnabled: { true }, payloadStore: store)
        let corruptResult = try await corruptService.translate(corruptRequest,
                                                              sourceLanguageIdentifier: "en",
                                                              targetLanguageIdentifier: "zh-Hans",
                                                              backendVersion: "fixture-v1",
                                                              using: translator)
        XCTAssertEqual(corruptResult.sourcePhrase, "read")

        let missingAttributeDocument = uniqueDocumentSHA()
        try insertDocument(missingAttributeDocument, db: db)
        defer { cleanupDocument(missingAttributeDocument, db: db) }
        let missingAttributeRequest = try persistedRequest(documentSHA256: missingAttributeDocument,
                                                           selected: "read")
        let missingAttributeKey = try XCTUnwrap(persistenceKey(missingAttributeRequest))
        let missingMarker = try makePersistedPayload(missingAttributeRequest, markTarget: false)
        let snapshot = try XCTUnwrap(ContextualTranslationPayloadSnapshot.encode(missingMarker))
        _ = try store.save(cacheKey: missingAttributeKey,
                           documentSHA256: missingAttributeDocument,
                           payload: snapshot)
        let missingAttributeService = ContextualTranslationService(isEnabled: { true }, payloadStore: store)
        let repairedResult = try await missingAttributeService.translate(missingAttributeRequest,
                                                                          sourceLanguageIdentifier: "en",
                                                                          targetLanguageIdentifier: "zh-Hans",
                                                                          backendVersion: "fixture-v1",
                                                                          using: translator)
        XCTAssertEqual(repairedResult.sourcePhrase, "read")
        let translationCalls = await calls.count
        XCTAssertEqual(translationCalls, 2)
    }

    func testSnapshotDecoderRejectsExcessiveJSONDepth() throws {
        let request = try persistedRequest(documentSHA256: "snapshot-depth-fixture", selected: "read")
        let payload = try makePersistedPayload(request)
        let encoded = try XCTUnwrap(ContextualTranslationPayloadSnapshot.encode(payload))
        var json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertEqual(json.last, "}")
        json.removeLast()
        json += ",\"unexpected\":[[[[[0]]]]] }"

        XCTAssertNil(ContextualTranslationPayloadSnapshot.decode(Data(json.utf8)))
    }

    func testDocumentNotYetInLibraryDoesNotFailTranslationOrCreateCacheRow() async throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let documentSHA256 = uniqueDocumentSHA()
        let request = try persistedRequest(documentSHA256: documentSHA256, selected: "read")
        let calls = PersistenceTranslationCounter()
        let service = ContextualTranslationService(isEnabled: { true },
                                                   payloadStore: ContextTranslationStore(db: db))
        let result = try await service.translate(request,
                                                sourceLanguageIdentifier: "en",
                                                targetLanguageIdentifier: "zh-Hans",
                                                backendVersion: "fixture-v1",
                                                using: { request, _, _, _ in
                                                    await calls.record()
                                                    return try makePersistedPayload(request)
                                                })

        XCTAssertEqual(result.sourcePhrase, "read")
        let translationCalls = await calls.count
        XCTAssertEqual(translationCalls, 1)
        let rowCount = try payloadCount(documentSHA256, db: db)
        XCTAssertEqual(rowCount, 0)
    }

    func testStoreHonorsEntryAndTotalByteBudgetsWithLRUEviction() throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let documentSHA256 = uniqueDocumentSHA()
        try insertDocument(documentSHA256, db: db)
        defer { cleanupDocument(documentSHA256, db: db) }
        let store = ContextTranslationStore(db: db, maximumTotalBytes: 10, maximumPayloadBytes: 8)
        let firstKey = String(repeating: "a", count: 64)
        let secondKey = String(repeating: "b", count: 64)
        let firstData = Data(repeating: 1, count: 8)
        let secondData = Data(repeating: 2, count: 8)

        XCTAssertTrue(try store.save(cacheKey: firstKey, documentSHA256: documentSHA256, payload: firstData))
        XCTAssertTrue(try store.save(cacheKey: secondKey, documentSHA256: documentSHA256, payload: secondData))
        XCTAssertNil(try store.load(cacheKey: firstKey, documentSHA256: documentSHA256))
        XCTAssertEqual(try store.load(cacheKey: secondKey, documentSHA256: documentSHA256), secondData)
        XCTAssertFalse(try store.save(cacheKey: String(repeating: "c", count: 64),
                                      documentSHA256: documentSHA256,
                                      payload: Data(repeating: 3, count: 9)))
    }

    func testOversizedDatabasePayloadIsRemovedBeforeBlobRead() throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let documentSHA256 = uniqueDocumentSHA()
        try insertDocument(documentSHA256, db: db)
        defer { cleanupDocument(documentSHA256, db: db) }
        let key = String(repeating: "f", count: 64)
        try db.dbQueue.write { database in
            try database.execute(sql: """
                INSERT INTO context_translation_payload (cacheKey, docSha, payload, lastAccess)
                VALUES (?, ?, ?, 1)
                """, arguments: [key, documentSHA256, Data(repeating: 7, count: 9)])
        }
        let store = ContextTranslationStore(db: db, maximumTotalBytes: 10, maximumPayloadBytes: 8)

        XCTAssertNil(try store.load(cacheKey: key, documentSHA256: documentSHA256))
        XCTAssertEqual(try payloadCount(documentSHA256, db: db), 0)
    }

    func testPayloadCacheLeavesExistingOCRRowsAloneAndCascadesOnDocumentDeletion() throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let documentSHA256 = uniqueDocumentSHA()
        try insertDocument(documentSHA256, db: db)
        defer { cleanupDocument(documentSHA256, db: db) }
        try db.dbQueue.write { database in
            try database.execute(sql: "INSERT INTO context_ocr_page (docSha, page, revision, payload) VALUES (?, 0, 1, ?)",
                                 arguments: [documentSHA256, Data("existing-ocr".utf8)])
            try database.execute(sql: """
                INSERT INTO ocr_character_geometry
                    (cacheKey, docSha, page, blockID, sourceRevision, geometryRevision,
                     engineVersion, payload, lastAccess)
                VALUES (?, ?, 0, 'legacy-block', 1, 1, 'fixture-engine', ?, 1)
                """, arguments: [String(repeating: "d", count: 64), documentSHA256, Data("existing-geometry".utf8)])
        }
        let store = ContextTranslationStore(db: db)
        let translationKey = String(repeating: "e", count: 64)
        XCTAssertTrue(try store.save(cacheKey: translationKey,
                                     documentSHA256: documentSHA256,
                                     payload: Data("translation".utf8)))
        let existingRows = try db.dbQueue.read { database in
            (try Int.fetchOne(database,
                              sql: "SELECT COUNT(*) FROM context_ocr_page WHERE docSha = ?",
                              arguments: [documentSHA256]) ?? 0,
             try Int.fetchOne(database,
                              sql: "SELECT COUNT(*) FROM ocr_character_geometry WHERE docSha = ?",
                              arguments: [documentSHA256]) ?? 0)
        }
        XCTAssertEqual(existingRows.0, 1)
        XCTAssertEqual(existingRows.1, 1)

        try db.dbQueue.write { database in
            try database.execute(sql: "DELETE FROM document WHERE sha256 = ?", arguments: [documentSHA256])
        }
        XCTAssertNil(try store.load(cacheKey: translationKey, documentSHA256: documentSHA256))
        XCTAssertEqual(try payloadCount(documentSHA256, db: db), 0)
    }

    func testClearAllAndCancellationDoNotRepersistAnInFlightPayload() async throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let documentSHA256 = uniqueDocumentSHA()
        try insertDocument(documentSHA256, db: db)
        defer { cleanupDocument(documentSHA256, db: db) }
        let store = ContextTranslationStore(db: db)
        let seedRequest = try persistedRequest(documentSHA256: documentSHA256, selected: "read")
        let seedService = ContextualTranslationService(isEnabled: { true }, payloadStore: store)
        _ = try await seedService.translate(seedRequest,
                                            sourceLanguageIdentifier: "en",
                                            targetLanguageIdentifier: "zh-Hans",
                                            backendVersion: "seed-v1",
                                            using: { request, _, _, _ in try makePersistedPayload(request) })
        XCTAssertEqual(try payloadCount(documentSHA256, db: db), 1)

        let pendingRequest = try persistedRequest(documentSHA256: documentSHA256, selected: "books")
        let service = ContextualTranslationService(isEnabled: { true }, payloadStore: store)
        let clearGate = PersistenceTranslationGate()
        let pending = Task {
            try await service.translate(pendingRequest,
                                       sourceLanguageIdentifier: "en",
                                       targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "pending-v2",
                                       using: { request, _, _, _ in
                                           await clearGate.suspend()
                                           try Task.checkCancellation()
                                           return try makePersistedPayload(request)
                                       })
        }
        await clearGate.waitUntilStarted()
        try await service.clearAllCaches()
        await clearGate.release()
        _ = try await pending.value
        XCTAssertEqual(try payloadCount(documentSHA256, db: db), 0,
                       "A translation that finishes after clearAllCaches must not repopulate persistent storage")

        let cancellationGate = PersistenceTranslationGate()
        let cancellationRequest = try persistedRequest(documentSHA256: documentSHA256, selected: "read")
        let cancelled = Task {
            try await service.translate(cancellationRequest,
                                       sourceLanguageIdentifier: "en",
                                       targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "cancel-v1",
                                       using: { request, _, _, _ in
                                           await cancellationGate.suspend()
                                           try Task.checkCancellation()
                                           return try makePersistedPayload(request)
                                       })
        }
        await cancellationGate.waitUntilStarted()
        cancelled.cancel()
        await cancellationGate.release()
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Canceled results are not persisted.
        }
        XCTAssertEqual(try payloadCount(documentSHA256, db: db), 0)
    }

    private func insertDocument(_ sha: String, db: AppDatabase) throws {
        try db.dbQueue.write { database in
            try database.execute(sql: """
                INSERT INTO document (sha256, title, fileName, pageCount, hasTextLayer, importedAt,
                                      lastPage, pageX, pageY, zoom, zoomAuto)
                VALUES (?, 'translation cache fixture', 'fixture.pdf', 1, 0, ?, 0, 0, 0, 1, 1)
                """, arguments: [sha, Date()])
        }
    }

    private func cleanupDocument(_ sha: String, db: AppDatabase) {
        try? db.dbQueue.write { database in
            try database.execute(sql: "DELETE FROM document WHERE sha256 = ?", arguments: [sha])
        }
    }

    private func payloadCount(_ sha: String, db: AppDatabase) throws -> Int {
        try db.dbQueue.read { database in
            try Int.fetchOne(database,
                             sql: "SELECT COUNT(*) FROM context_translation_payload WHERE docSha = ?",
                             arguments: [sha]) ?? 0
        }
    }
}

private actor PersistenceTranslationCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private actor PersistenceTranslationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private func persistedRequest(documentSHA256: String,
                             selected: String,
                             text: String = "They read books daily.",
                             verifiedPhraseGroup: Bool = false) throws -> ContextualTranslationRequest {
    let source = text as NSString
    let range = source.range(of: selected)
    guard range.location != NSNotFound,
          let selectedSpan = UTF16Span(range: range, in: text) else {
        throw ContextualTranslationError.invalidSelection
    }
    let length = source.length
    let context = SentenceContext(documentSHA256: documentSHA256,
                                  pageIndex: 0,
                                  blockID: "translation-cache-fixture",
                                  text: text,
                                  displayLineText: text,
                                  displaySentenceText: text,
                                  sourceSpan: UTF16Span(location: 0, length: length),
                                  displaySpan: UTF16Span(location: 0, length: length),
                                  selectedSourceSpans: [selectedSpan],
                                  selectedDisplaySpans: [selectedSpan],
                                  kind: .completeSentence)
    return try ContextualTranslationRequest.make(from: context,
                                                 verifiedPhraseGroupSpan: verifiedPhraseGroup ? selectedSpan : nil)
}

private func persistenceKey(_ request: ContextualTranslationRequest) -> String? {
    ContextTranslationPayloadCacheIdentity.cacheKey(request: request,
                                                     sourceLanguageIdentifier: "en",
                                                     targetLanguageIdentifier: "zh-Hans",
                                                     backendVersion: "fixture-v1",
                                                     contextAlgorithmVersion: ContextualTranslationService.contextAlgorithmVersion)
}

private func makePersistedPayload(_ request: ContextualTranslationRequest,
                                  markTarget: Bool = true) throws -> ContextualTranslationPayload {
    let target = "A thing."
    var attributedTarget = AttributedString(target)
    if markTarget {
        guard let selectedID = request.selectedTokenIDs.first else {
            throw ContextualTranslationError.invalidSelection
        }
        let span = UTF16Span(location: 2, length: 5)
        let lowerStringIndex = String.Index(utf16Offset: span.location, in: target)
        let upperStringIndex = String.Index(utf16Offset: span.endExclusive ?? 0, in: target)
        guard let lower = AttributedString.Index(lowerStringIndex, within: attributedTarget),
              let upper = AttributedString.Index(upperStringIndex, within: attributedTarget),
              span.composedCharacterRange(in: target) != nil else {
            throw ContextualTranslationError.invalidTargetRange
        }
        attributedTarget[lower..<upper][ContextualTranslationTokenIDAttribute.self] = selectedID
    }
    return ContextualTranslationPayload(sourceText: request.sentenceText,
                                        attributedSourceText: try request.attributedSourceText(),
                                        targetText: target,
                                        attributedTargetText: attributedTarget)
}
