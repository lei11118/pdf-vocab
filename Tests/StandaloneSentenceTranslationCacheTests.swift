import XCTest
@testable import PdfVocab

final class StandaloneSentenceTranslationCacheTests: XCTestCase {
    func testCacheUsesExactUTF8KeysAndLeastRecentlyUsedEviction() async throws {
        let cache = StandaloneSentenceTranslationCache(maximumCachedEntries: 2)
        let composed = "Caf\u{00E9} works."
        let decomposed = "Cafe\u{0301} works."
        XCTAssertEqual(composed, decomposed, "Swift String equality treats canonical spellings as equal")

        try await cache.store("第一条译文", for: composed)
        try await cache.store("第二条译文", for: "Second sentence.")

        let composedResult = await cache.translation(for: composed)
        let decomposedResult = await cache.translation(for: decomposed)
        XCTAssertEqual(composedResult, "第一条译文")
        XCTAssertNil(decomposedResult, "Cache identity must preserve the exact original UTF-8 bytes")

        try await cache.store("第三条译文", for: "Third sentence.")
        let secondAfterEviction = await cache.translation(for: "Second sentence.")
        let composedAfterEviction = await cache.translation(for: composed)
        let thirdAfterEviction = await cache.translation(for: "Third sentence.")
        let entryCount = await cache.cachedEntryCount
        XCTAssertNil(secondAfterEviction, "The least recently used entry should be evicted")
        XCTAssertEqual(composedAfterEviction, "第一条译文")
        XCTAssertEqual(thirdAfterEviction, "第三条译文")
        XCTAssertEqual(entryCount, 2)
    }

    func testDefaultCacheCapacityIsThirtyTwoEntries() async throws {
        let cache = StandaloneSentenceTranslationCache()

        for index in 0...StandaloneSentenceTranslationCache.maximumCachedEntries {
            try await cache.store("译文 \(index)", for: "Sentence \(index).")
        }

        let oldest = await cache.translation(for: "Sentence 0.")
        let newest = await cache.translation(for: "Sentence 32.")
        let entryCount = await cache.cachedEntryCount
        XCTAssertNil(oldest)
        XCTAssertEqual(newest, "译文 32")
        XCTAssertEqual(entryCount, 32)
    }

    func testCacheRejectsEmptyAndOverlongTranslations() async throws {
        let cache = StandaloneSentenceTranslationCache()

        do {
            try await cache.store(" \n", for: "Empty result.")
            XCTFail("An empty result must not be cached")
        } catch let error as StandaloneSentenceTranslationCacheError {
            XCTAssertEqual(error, .emptyTranslation)
        }

        do {
            let oversized = String(repeating: "译", count: StandaloneSentenceTranslationCache.maximumOutputUTF16Units + 1)
            try await cache.store(oversized, for: "Overlong result.")
            XCTFail("An overlong result must not be cached")
        } catch let error as StandaloneSentenceTranslationCacheError {
            XCTAssertEqual(error, .outputTooLong(maximumUTF16Units: StandaloneSentenceTranslationCache.maximumOutputUTF16Units))
        }

        let entryCount = await cache.cachedEntryCount
        XCTAssertEqual(entryCount, 0)
    }
}
