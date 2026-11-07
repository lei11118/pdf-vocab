import Foundation
import Translation

/// A short-lived Translation adapter with an independent, bounded cache for
/// token-alignment candidates. The TranslationSession itself is never stored.
actor ContextualTranslationService {
    typealias Translator = @Sendable (_ request: ContextualTranslationRequest,
                                      _ source: AttributedString,
                                      _ sourceLanguageIdentifier: String,
                                      _ targetLanguageIdentifier: String) async throws -> ContextualTranslationPayload

    static let shared = ContextualTranslationService()
    static let defaultMaximumCachedEntries = 32
    static let maximumOutputUTF16Units = 8_192
    static let contextAlgorithmVersion = "layout-block-v1"

    private struct CacheKey: Hashable {
        let sentenceUTF8: [UInt8]
        let selectedSourceUTF8: [UInt8]
        let selectedTokenSpans: [UTF16Span]
        let phraseGroupSpan: UTF16Span?
        let isPhraseGroupSelection: Bool
        let sourceLanguageIdentifier: String
        let targetLanguageIdentifier: String
        let backendVersion: String
        let contextAlgorithmVersion: String
    }

    private struct TokenIdentity: Hashable {
        let id: String
        let sourceSpan: UTF16Span
    }

    /// Reuses a validated whole-block Translation payload across selections
    /// from the same source. Selection-specific extraction still runs per call.
    private struct PayloadCacheKey: Hashable {
        let sourceUTF8: [UInt8]
        let tokens: [TokenIdentity]
        let phraseGroupID: String?
        let phraseGroupSpan: UTF16Span?
        let sourceLanguageIdentifier: String
        let targetLanguageIdentifier: String
        let backendVersion: String
        let contextAlgorithmVersion: String
    }

    private let maximumCachedEntries: Int
    private let maximumCachedPayloadEntries: Int
    private let isEnabled: @Sendable () -> Bool
    private var cache: [CacheKey: ContextualTranslationCandidate] = [:]
    private var cacheOrder: [CacheKey] = []
    private var payloadCache: [PayloadCacheKey: ContextualTranslationPayload] = [:]
    private var payloadCacheOrder: [PayloadCacheKey] = []
    private var cacheGeneration = 0
    private var requestGeneration = 0

    init(maximumCachedEntries: Int = ContextualTranslationService.defaultMaximumCachedEntries,
         isEnabled: @escaping @Sendable () -> Bool = { FeatureFlags.contextReadingEnabled() }) {
        self.maximumCachedEntries = max(0, maximumCachedEntries)
        self.maximumCachedPayloadEntries = min(8, max(0, maximumCachedEntries))
        self.isEnabled = isEnabled
    }

    func translate(_ request: ContextualTranslationRequest,
                   sourceLanguageIdentifier: String,
                   targetLanguageIdentifier: String,
                   backendVersion: String,
                   using translator: @escaping Translator) async throws -> ContextualTranslationCandidate {
        let requestGeneration = self.requestGeneration
        try Task.checkCancellation()
        guard isEnabled() else { throw ContextualTranslationError.disabled }
        guard isValidIdentityComponent(sourceLanguageIdentifier),
              isValidIdentityComponent(targetLanguageIdentifier),
              isValidIdentityComponent(backendVersion) else {
            throw ContextualTranslationError.invalidConfiguration
        }

        let key = CacheKey(sentenceUTF8: Array(request.sentenceText.utf8),
                           selectedSourceUTF8: Array(request.selectedSourcePhrase.utf8),
                           selectedTokenSpans: request.selectedSourceSpans,
                           phraseGroupSpan: request.selectedPhraseGroup?.sourceSpan,
                           isPhraseGroupSelection: request.selectedPhraseGroup != nil,
                           sourceLanguageIdentifier: sourceLanguageIdentifier,
                           targetLanguageIdentifier: targetLanguageIdentifier,
                           backendVersion: backendVersion,
                           contextAlgorithmVersion: Self.contextAlgorithmVersion)
        if let cached = cache[key] {
            touch(key)
            return cached
        }

        let generation = cacheGeneration
        let payloadKey = PayloadCacheKey(sourceUTF8: Array(request.sentenceText.utf8),
                                         tokens: request.tokens.map {
                                             TokenIdentity(id: $0.id, sourceSpan: $0.sourceSpan)
                                         },
                                         phraseGroupID: request.selectedPhraseGroup?.id,
                                         phraseGroupSpan: request.selectedPhraseGroup?.sourceSpan,
                                         sourceLanguageIdentifier: sourceLanguageIdentifier,
                                         targetLanguageIdentifier: targetLanguageIdentifier,
                                         backendVersion: backendVersion,
                                         contextAlgorithmVersion: Self.contextAlgorithmVersion)
        let candidate: ContextualTranslationCandidate
        var payloadToCache: ContextualTranslationPayload?
        if let cachedPayload = payloadCache[payloadKey] {
            touchPayload(payloadKey)
            do {
                candidate = try ContextualTranslationAlignment.decode(request: request,
                                                                        payload: cachedPayload)
            } catch {
                // A payload can be valid for one selected token and omit another.
                // Never reuse its candidate blindly; retry the translator once.
                removePayload(payloadKey)
                let payload = try await translatedPayload(request: request,
                                                          sourceLanguageIdentifier: sourceLanguageIdentifier,
                                                          targetLanguageIdentifier: targetLanguageIdentifier,
                                                          requestGeneration: requestGeneration,
                                                          using: translator)
                candidate = try ContextualTranslationAlignment.decode(request: request, payload: payload)
                payloadToCache = payload
            }
        } else {
            let payload = try await translatedPayload(request: request,
                                                      sourceLanguageIdentifier: sourceLanguageIdentifier,
                                                      targetLanguageIdentifier: targetLanguageIdentifier,
                                                      requestGeneration: requestGeneration,
                                                      using: translator)
            candidate = try ContextualTranslationAlignment.decode(request: request, payload: payload)
            payloadToCache = payload
        }
        if generation == cacheGeneration, maximumCachedEntries > 0 {
            cache[key] = candidate
            touch(key)
            evictIfNeeded()
        }
        if generation == cacheGeneration, maximumCachedPayloadEntries > 0,
           let payloadToCache {
            storePayload(payloadToCache, for: payloadKey)
        }
        return candidate
    }

    func clearCache() {
        cache.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
        payloadCache.removeAll(keepingCapacity: false)
        payloadCacheOrder.removeAll(keepingCapacity: false)
        cacheGeneration &+= 1
    }

    func invalidatePendingRequests() {
        requestGeneration &+= 1
    }

    var cachedEntryCount: Int { cache.count }
    var cachedPayloadEntryCount: Int { payloadCache.count }

    private func translatedPayload(request: ContextualTranslationRequest,
                                    sourceLanguageIdentifier: String,
                                    targetLanguageIdentifier: String,
                                    requestGeneration: Int,
                                    using translator: @escaping Translator) async throws -> ContextualTranslationPayload {
        let source = try request.attributedSourceText()
        let payload: ContextualTranslationPayload
        do {
            payload = try await translator(request,
                                           source,
                                           sourceLanguageIdentifier,
                                           targetLanguageIdentifier)
        } catch {
            guard requestGeneration == self.requestGeneration else {
                throw ContextualTranslationError.staleRequest
            }
            if Task.isCancelled { throw CancellationError() }
            guard isEnabled() else { throw ContextualTranslationError.disabled }
            throw error
        }
        guard requestGeneration == self.requestGeneration else {
            throw ContextualTranslationError.staleRequest
        }
        try Task.checkCancellation()
        guard isEnabled() else { throw ContextualTranslationError.disabled }
        guard (payload.targetText as NSString).length <= Self.maximumOutputUTF16Units else {
            throw ContextualTranslationError.outputTooLong(maximumUTF16Units: Self.maximumOutputUTF16Units)
        }
        return payload
    }

    private func isValidIdentityComponent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (value as NSString).length <= 128
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

    private func touchPayload(_ key: PayloadCacheKey) {
        payloadCacheOrder.removeAll { $0 == key }
        payloadCacheOrder.append(key)
    }

    private func storePayload(_ payload: ContextualTranslationPayload, for key: PayloadCacheKey) {
        payloadCache[key] = payload
        touchPayload(key)
        while payloadCacheOrder.count > maximumCachedPayloadEntries {
            let evicted = payloadCacheOrder.removeFirst()
            payloadCache.removeValue(forKey: evicted)
        }
    }

    private func removePayload(_ key: PayloadCacheKey) {
        payloadCache.removeValue(forKey: key)
        payloadCacheOrder.removeAll { $0 == key }
    }
}

/// Captures a TranslationSession only for the lifetime of one SwiftUI
/// translationTask callback, matching Apple's session ownership model.
@available(iOS 26.4, *)
enum AppleContextualTranslationAdapter {
    static let backendVersion = "apple-attributed-token-alignment-v3"

    @MainActor
    static func makeTranslator(using session: TranslationSession,
                               sourceLanguageIdentifier: String,
                               targetLanguageIdentifier: String) -> ContextualTranslationService.Translator {
        let configuredSourceLanguageIdentifier = sourceLanguageIdentifier
        let configuredTargetLanguageIdentifier = targetLanguageIdentifier
        let reference = TranslationSessionReference(session: session)
        return { _, attributedSource, requestedSourceLanguageIdentifier, requestedTargetLanguageIdentifier in
            try Task.checkCancellation()
            guard requestedSourceLanguageIdentifier == configuredSourceLanguageIdentifier,
                  requestedTargetLanguageIdentifier == configuredTargetLanguageIdentifier else {
                throw ContextualTranslationError.invalidConfiguration
            }
            let payload = try await reference.translate(attributedSource)
            try Task.checkCancellation()
            return payload
        }
    }

    @MainActor
    private final class TranslationSessionReference {
        private let session: TranslationSession

        init(session: TranslationSession) {
            self.session = session
        }

        func translate(_ attributedSource: AttributedString) async throws -> ContextualTranslationPayload {
            let response = try await session.translate(attributedSource)
            return ContextualTranslationPayload(sourceText: response.sourceText,
                                                attributedSourceText: response.attributedSourceText,
                                                targetText: response.targetText,
                                                attributedTargetText: response.attributedTargetText)
        }
    }
}
