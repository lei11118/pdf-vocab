import Foundation
import Translation

/// A bounded, in-memory cache for translations of complete sentence contexts.
/// The service is a foundation for the context-reading route; it does not
/// replace the reader's existing standalone sentence translation flow.
actor SentenceTranslationService {
    typealias Translator = @Sendable (_ text: String,
                                      _ sourceLanguageIdentifier: String,
                                      _ targetLanguageIdentifier: String) async throws -> String

    static let maximumInputUTF16Units = 2_048
    static let maximumOutputUTF16Units = 8_192
    static let defaultMaximumCachedEntries = 32

    private struct CacheKey: Hashable {
        // Swift String equality treats canonically equivalent spellings as
        // equal. UTF-8 bytes preserve the exact OCR source for cache identity.
        let originalTextUTF8: [UInt8]
        let sourceLanguageIdentifier: String
        let targetLanguageIdentifier: String
        let backendVersion: String
    }

    private let maximumCachedEntries: Int
    private let isEnabled: @Sendable () -> Bool
    private var cache: [CacheKey: String] = [:]
    private var cacheOrder: [CacheKey] = []
    private var cacheGeneration = 0
    private var requestGeneration = 0

    init(maximumCachedEntries: Int = SentenceTranslationService.defaultMaximumCachedEntries,
         isEnabled: @escaping @Sendable () -> Bool = { FeatureFlags.contextReadingEnabled() }) {
        self.maximumCachedEntries = max(0, maximumCachedEntries)
        self.isEnabled = isEnabled
    }

    func translate(_ sentence: SentenceContext,
                   sourceLanguageIdentifier: String,
                   targetLanguageIdentifier: String,
                   backendVersion: String,
                   using translator: @escaping Translator) async throws -> String {
        let requestGeneration = self.requestGeneration
        try Task.checkCancellation()
        guard isEnabled() else { throw SentenceTranslationServiceError.disabled }
        guard sentence.kind == .completeSentence,
              !containsLineBreak(sentence.text) else {
            throw SentenceTranslationServiceError.incompleteSentence
        }
        guard !sentence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SentenceTranslationServiceError.emptyInput
        }
        guard (sentence.text as NSString).length <= Self.maximumInputUTF16Units else {
            throw SentenceTranslationServiceError.inputTooLong(maximumUTF16Units: Self.maximumInputUTF16Units)
        }
        guard isValidIdentityComponent(sourceLanguageIdentifier),
              isValidIdentityComponent(targetLanguageIdentifier),
              isValidIdentityComponent(backendVersion) else {
            throw SentenceTranslationServiceError.invalidConfiguration
        }

        let key = CacheKey(originalTextUTF8: Array(sentence.text.utf8),
                           sourceLanguageIdentifier: sourceLanguageIdentifier,
                           targetLanguageIdentifier: targetLanguageIdentifier,
                           backendVersion: backendVersion)
        if let cached = cache[key] {
            touch(key)
            return cached
        }

        let generation = cacheGeneration
        let result: String
        do {
            result = try await translator(sentence.text,
                                          sourceLanguageIdentifier,
                                          targetLanguageIdentifier)
        } catch {
            guard requestGeneration == self.requestGeneration else {
                throw SentenceTranslationServiceError.staleRequest
            }
            if Task.isCancelled { throw CancellationError() }
            guard isEnabled() else { throw SentenceTranslationServiceError.disabled }
            throw error
        }
        guard requestGeneration == self.requestGeneration else {
            throw SentenceTranslationServiceError.staleRequest
        }
        try Task.checkCancellation()
        guard isEnabled() else { throw SentenceTranslationServiceError.disabled }

        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SentenceTranslationServiceError.emptyTranslation
        }
        guard (result as NSString).length <= Self.maximumOutputUTF16Units else {
            throw SentenceTranslationServiceError.outputTooLong(maximumUTF16Units: Self.maximumOutputUTF16Units)
        }

        // A clear that occurs while the translator is suspended must remain
        // effective when this request resumes.
        if generation == cacheGeneration, maximumCachedEntries > 0 {
            cache[key] = result
            touch(key)
            evictIfNeeded()
        }
        return result
    }

    func clearCache() {
        cache.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
        cacheGeneration &+= 1
    }

    func invalidatePendingRequests() {
        requestGeneration &+= 1
    }

    var cachedEntryCount: Int { cache.count }

    private func isValidIdentityComponent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (value as NSString).length <= 128
    }

    private func containsLineBreak(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
    }

    private func touch(_ key: CacheKey) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    private func evictIfNeeded() {
        while cacheOrder.count > maximumCachedEntries {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }
}

enum SentenceTranslationServiceError: Error, Equatable, LocalizedError {
    case disabled
    case incompleteSentence
    case emptyInput
    case inputTooLong(maximumUTF16Units: Int)
    case invalidConfiguration
    case emptyTranslation
    case outputTooLong(maximumUTF16Units: Int)
    case languagePairMismatch
    case staleRequest

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Context sentence translation is disabled."
        case .incompleteSentence:
            return "Only complete single-line sentences can be translated."
        case .emptyInput:
            return "The sentence is empty."
        case .inputTooLong(let maximumUTF16Units):
            return "The sentence exceeds the \(maximumUTF16Units)-unit limit."
        case .invalidConfiguration:
            return "The translation language or backend version is invalid."
        case .emptyTranslation:
            return "The translation service returned an empty result."
        case .outputTooLong(let maximumUTF16Units):
            return "The translation exceeds the \(maximumUTF16Units)-unit limit."
        case .languagePairMismatch:
            return "The translation request does not match the TranslationSession language pair."
        case .staleRequest:
            return "The translation request was invalidated before it completed."
        }
    }
}

/// Adapts the `TranslationSession` supplied by SwiftUI's `translationTask`.
/// Create this translator inside the task callback and use it for the service
/// request before that callback returns. Pass the same configured language
/// identifiers to both the task and the service request.
@available(iOS 18.0, *)
enum AppleTranslationSessionAdapter {
    static let backendVersion = "apple-translation-session-v1"

    @MainActor
    static func makeTranslator(using session: TranslationSession,
                               sourceLanguageIdentifier: String,
                               targetLanguageIdentifier: String) -> SentenceTranslationService.Translator {
        let sessionReference = TranslationSessionReference(session: session)
        return { text, sourceIdentifier, targetIdentifier in
            guard sourceIdentifier == sourceLanguageIdentifier,
                  targetIdentifier == targetLanguageIdentifier else {
                throw SentenceTranslationServiceError.languagePairMismatch
            }
            try Task.checkCancellation()
            let translatedText = try await sessionReference.translate(text)
            try Task.checkCancellation()
            return translatedText
        }
    }

    @MainActor
    private final class TranslationSessionReference {
        private let session: TranslationSession

        init(session: TranslationSession) {
            self.session = session
        }

        func translate(_ text: String) async throws -> String {
            let response = try await session.translate(text)
            return response.targetText
        }
    }
}
