import Foundation
import XCTest
@testable import PdfVocab

final class SentenceTranslationServiceTests: XCTestCase {
    func testDefaultContextSwitchBlocksTranslationAndInvalidSentencesAreRejected() async throws {
        let suite = "SentenceTranslationServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(FeatureFlags.contextReadingEnabled(in: defaults))
        let calls = TranslationCallRecorder()
        let service = SentenceTranslationService(isEnabled: {
            FeatureFlags.contextReadingEnabled(in: defaults)
        })
        let translator: SentenceTranslationService.Translator = { text, source, target in
            await calls.record(text, source: source, target: target)
            return "translation"
        }

        do {
            _ = try await service.translate(sentence("A complete sentence."),
                                            sourceLanguageIdentifier: "en",
                                            targetLanguageIdentifier: "zh-Hans",
                                            backendVersion: "test-v1",
                                            using: translator)
            XCTFail("The default-off context switch must block translation")
        } catch let error as SentenceTranslationServiceError {
            XCTAssertEqual(error, .disabled)
        }
        let disabledCallCount = await calls.count
        XCTAssertEqual(disabledCallCount, 0)

        defaults.set(true, forKey: FeatureFlags.contextReadingEnabledKey)
        let invalidSentences: [(SentenceContext, SentenceTranslationServiceError)] = [
            (sentence("A sentence-shaped fragment.", kind: .fragment), .incompleteSentence),
            (sentence(""), .emptyInput),
            (sentence("A line.\nAnother line."), .incompleteSentence),
            (sentence(String(repeating: "a", count: SentenceTranslationService.maximumInputUTF16Units + 1)),
             .inputTooLong(maximumUTF16Units: SentenceTranslationService.maximumInputUTF16Units))
        ]

        for (candidate, expectedError) in invalidSentences {
            do {
                _ = try await service.translate(candidate,
                                                sourceLanguageIdentifier: "en",
                                                targetLanguageIdentifier: "zh-Hans",
                                                backendVersion: "test-v1",
                                                using: translator)
                XCTFail("Expected \(expectedError)")
            } catch let error as SentenceTranslationServiceError {
                XCTAssertEqual(error, expectedError)
            }
        }
        let rejectedCallCount = await calls.count
        XCTAssertEqual(rejectedCallCount, 0)
    }

    func testCacheSeparatesExactOriginalLanguagePairAndBackendVersion() async throws {
        let service = SentenceTranslationService(maximumCachedEntries: 8, isEnabled: { true })
        let calls = TranslationCallRecorder()
        let translator: SentenceTranslationService.Translator = { text, source, target in
            await calls.record(text, source: source, target: target)
            return "\(source)->\(target):\(text)"
        }

        let composed = sentence("Caf\u{00E9} works.")
        let decomposed = sentence("Cafe\u{0301} works.")
        XCTAssertEqual(composed.text, decomposed.text, "Swift String equality is canonically equivalent")

        let first = try await service.translate(composed,
                                               sourceLanguageIdentifier: "en",
                                               targetLanguageIdentifier: "zh-Hans",
                                               backendVersion: "backend-v1",
                                               using: translator)
        let cached = try await service.translate(composed,
                                                sourceLanguageIdentifier: "en",
                                                targetLanguageIdentifier: "zh-Hans",
                                                backendVersion: "backend-v1",
                                                using: translator)
        XCTAssertEqual(cached, first)

        _ = try await service.translate(decomposed,
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "backend-v1",
                                        using: translator)
        _ = try await service.translate(composed,
                                        sourceLanguageIdentifier: "fr",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "backend-v1",
                                        using: translator)
        _ = try await service.translate(composed,
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hant",
                                        backendVersion: "backend-v1",
                                        using: translator)
        _ = try await service.translate(composed,
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "backend-v2",
                                        using: translator)
        _ = try await service.translate(sentence("Another full sentence."),
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "backend-v1",
                                        using: translator)

        let callCount = await calls.count
        XCTAssertEqual(callCount, 6)
        let cacheCount = await service.cachedEntryCount
        XCTAssertEqual(cacheCount, 6)
    }

    func testLRUEvictionUsesRecentHitsAndClearEmptiesTheCache() async throws {
        let service = SentenceTranslationService(maximumCachedEntries: 2, isEnabled: { true })
        let calls = TranslationCallRecorder()
        let translator: SentenceTranslationService.Translator = { text, source, target in
            await calls.record(text, source: source, target: target)
            return "result:\(text)"
        }
        let first = sentence("First sentence.")
        let second = sentence("Second sentence.")
        let third = sentence("Third sentence.")

        _ = try await service.translate(first,
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "test-v1",
                                        using: translator)
        _ = try await service.translate(second,
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "test-v1",
                                        using: translator)
        _ = try await service.translate(first,
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "test-v1",
                                        using: translator)
        _ = try await service.translate(third,
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "test-v1",
                                        using: translator)
        _ = try await service.translate(second,
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "test-v1",
                                        using: translator)

        let evictionCallCount = await calls.count
        XCTAssertEqual(evictionCallCount, 4, "The hit on first should evict second when third is inserted")
        let boundedCount = await service.cachedEntryCount
        XCTAssertEqual(boundedCount, 2)

        await service.clearCache()
        let clearedCount = await service.cachedEntryCount
        XCTAssertEqual(clearedCount, 0)
        _ = try await service.translate(first,
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "test-v1",
                                        using: translator)
        let postClearCallCount = await calls.count
        XCTAssertEqual(postClearCallCount, 5)
    }

    func testFailureAndCancellationAreNotCached() async throws {
        let service = SentenceTranslationService(isEnabled: { true })
        let calls = TranslationCallRecorder()
        let failingTranslator: SentenceTranslationService.Translator = { text, source, target in
            await calls.record(text, source: source, target: target)
            throw ExpectedTranslationFailure.failed
        }

        for _ in 0..<2 {
            do {
                _ = try await service.translate(sentence("A retryable sentence."),
                                                sourceLanguageIdentifier: "en",
                                                targetLanguageIdentifier: "zh-Hans",
                                                backendVersion: "test-v1",
                                                using: failingTranslator)
                XCTFail("Expected injected failure")
            } catch ExpectedTranslationFailure.failed {
                // Failure must reach the caller and remain retryable.
            }
        }
        let failedCallCount = await calls.count
        XCTAssertEqual(failedCallCount, 2)

        let started = AsyncLatch()
        let blockingTranslator: SentenceTranslationService.Translator = { _, _, _ in
            await started.open()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "should not be cached"
        }
        let task = Task {
            try await service.translate(sentence("A cancelled sentence."),
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "test-v1",
                                        using: blockingTranslator)
        }
        await started.wait()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Cancellation must propagate and must not cache a partial result.
        }
        let cacheCount = await service.cachedEntryCount
        XCTAssertEqual(cacheCount, 0)
    }

    func testConcurrentRequestsStayBoundedAndClearCache() async throws {
        let service = SentenceTranslationService(maximumCachedEntries: 2, isEnabled: { true })
        let calls = TranslationCallRecorder()
        let translator: SentenceTranslationService.Translator = { text, source, target in
            await calls.record(text, source: source, target: target)
            try await Task.sleep(nanoseconds: 1_000_000)
            return "result:\(text):\(source):\(target)"
        }

        let contexts = [sentence("First concurrent sentence."),
                        sentence("Second concurrent sentence."),
                        sentence("Third concurrent sentence.")]
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for context in contexts {
                group.addTask {
                    try await service.translate(context,
                                               sourceLanguageIdentifier: "en",
                                               targetLanguageIdentifier: "zh-Hans",
                                               backendVersion: "test-v1",
                                               using: translator)
                }
            }
            var values: [String] = []
            for try await result in group { values.append(result) }
            return values
        }

        XCTAssertEqual(Set(results), Set(contexts.map { "result:\($0.text):en:zh-Hans" }))
        let boundedCacheCount = await service.cachedEntryCount
        XCTAssertEqual(boundedCacheCount, 2)
        await service.clearCache()
        let clearedCacheCount = await service.cachedEntryCount
        XCTAssertEqual(clearedCacheCount, 0)

        _ = try await service.translate(contexts[0],
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "test-v1",
                                        using: translator)
        let finalCallCount = await calls.count
        XCTAssertEqual(finalCallCount, 4)
    }

    func testDisablingDuringTranslationDropsTheResultAndCacheWrite() async throws {
        let suite = "SentenceTranslationServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: FeatureFlags.contextReadingEnabledKey)

        let service = SentenceTranslationService(isEnabled: {
            FeatureFlags.contextReadingEnabled(in: defaults)
        })
        let started = AsyncLatch()
        let release = AsyncLatch()
        let calls = TranslationCallRecorder()
        let translator: SentenceTranslationService.Translator = { text, source, target in
            await calls.record(text, source: source, target: target)
            await started.open()
            await release.wait()
            return "result must be discarded"
        }

        let task = Task {
            try await service.translate(sentence("A sentence in flight."),
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "test-v1",
                                        using: translator)
        }
        await started.wait()
        defaults.set(false, forKey: FeatureFlags.contextReadingEnabledKey)
        await release.open()

        do {
            _ = try await task.value
            XCTFail("A result must not escape after the switch is disabled")
        } catch let error as SentenceTranslationServiceError {
            XCTAssertEqual(error, .disabled)
        }
        let cacheCount = await service.cachedEntryCount
        XCTAssertEqual(cacheCount, 0)
        let callCount = await calls.count
        XCTAssertEqual(callCount, 1)
    }

    func testClearingDuringTranslationPreventsTheInFlightResultFromRefillingCache() async throws {
        let service = SentenceTranslationService(isEnabled: { true })
        let started = AsyncLatch()
        let release = AsyncLatch()
        let calls = TranslationCallRecorder()
        let translator: SentenceTranslationService.Translator = { text, source, target in
            await calls.record(text, source: source, target: target)
            await started.open()
            await release.wait()
            return "translation"
        }
        let context = sentence("A sentence while clearing.")

        let task = Task {
            try await service.translate(context,
                                       sourceLanguageIdentifier: "en",
                                       targetLanguageIdentifier: "zh-Hans",
                                       backendVersion: "test-v1",
                                       using: translator)
        }
        await started.wait()
        await service.clearCache()
        await release.open()

        let result = try await task.value
        XCTAssertEqual(result, "translation")
        let cacheCountAfterFlight = await service.cachedEntryCount
        XCTAssertEqual(cacheCountAfterFlight, 0)

        _ = try await service.translate(context,
                                        sourceLanguageIdentifier: "en",
                                        targetLanguageIdentifier: "zh-Hans",
                                        backendVersion: "test-v1",
                                        using: translator)
        let callCount = await calls.count
        XCTAssertEqual(callCount, 2)
    }

    private func sentence(_ text: String,
                          kind: SentenceContextKind = .completeSentence) -> SentenceContext {
        let span = UTF16Span(location: 0, length: (text as NSString).length)
        return SentenceContext(documentSHA256: "test-document",
                               pageIndex: 0,
                               blockID: "line-0",
                               text: text,
                               displayLineText: text,
                               displaySentenceText: text,
                               sourceSpan: span,
                               displaySpan: span,
                               selectedSourceSpans: [],
                               selectedDisplaySpans: [],
                               kind: kind)
    }
}

private actor TranslationCallRecorder {
    private(set) var count = 0

    func record(_ text: String, source: String, target: String) {
        count += 1
        _ = text
        _ = source
        _ = target
    }
}

private actor AsyncLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        currentWaiters.forEach { $0.resume() }
    }
}

private enum ExpectedTranslationFailure: Error {
    case failed
}
