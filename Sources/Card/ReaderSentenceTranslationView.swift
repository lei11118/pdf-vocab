import Foundation
import SwiftUI
import Translation

struct SentenceTranslationRequest: Equatable {
    let text: String
    let id = UUID()
}

@MainActor final class SentenceTranslationState: ObservableObject {
    @Published private(set) var currentRequest: SentenceTranslationRequest?
    @Published private(set) var result: String?
    @Published private(set) var failure: String?
    @Published private(set) var isTranslating = false

    var displayText: String? {
        if let result { return result }
        if let failure { return failure }
        return isTranslating ? "正在端侧翻译…" : nil
    }

    func start(_ request: SentenceTranslationRequest) {
        guard currentRequest != request else { return }
        result = nil; failure = nil
        if #available(iOS 18.0, *) {
            isTranslating = true
            currentRequest = request
        } else {
            currentRequest = nil
            isTranslating = false
            failure = "端侧翻译需要 iPadOS 18 或更高版本"
        }
    }
    func finish(_ text: String, request: SentenceTranslationRequest) {
        guard currentRequest == request else { return }
        result = text; isTranslating = false; currentRequest = nil
    }
    func fail(_ message: String, request: SentenceTranslationRequest) {
        guard currentRequest == request else { return }
        failure = message; isTranslating = false; currentRequest = nil
    }
    func reset() { currentRequest = nil; result = nil; failure = nil; isTranslating = false }
}

struct ReaderSentenceTranslationView: View {
    let text: String
    var cached: String? = nil

    var body: some View {
        ReaderSentenceTranslationContent(text: text, cached: cached)
            .id(Data(text.utf8))
    }
}

private struct ReaderSentenceTranslationContent: View {
    let text: String
    let cached: String?
    @State private var translated = ""
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("原文").font(DS.Fonts.caption).foregroundStyle(DS.foreground3)
                Text(text).font(DS.Fonts.wordBody).foregroundStyle(DS.foreground2).textSelection(.enabled)
                Divider()
                Text("译文").font(DS.Fonts.headline).foregroundStyle(DS.foreground1)
                if let cached { Text(cached).textSelection(.enabled) }
                else if let failure { Text(failure) }
                else if translated.isEmpty { ProgressView("正在端侧翻译…") }
                else { Text(translated).textSelection(.enabled) }
                if cached == nil {
                    OfflineTranslationPreparationView().padding(.top, DS.Space.xs)
                }
            }.font(DS.Fonts.body).lineSpacing(4).frame(maxWidth:.infinity,alignment:.leading).padding(DS.Space.m)
        }.background { if cached == nil { if #available(iOS 18.0, *) { SentenceTranslationTask(text:text,onResult:{translated = $0},onError:{failure = $0}) } } }
            .onAppear { if #unavailable(iOS 18.0) { failure = "端侧翻译需要 iPadOS 18 或更高版本" } }
    }
}
@available(iOS 18.0, *)
struct SentenceTranslationTask: View {
    let text: String
    let onResult: (String) -> Void
    let onError: (String) -> Void
    var body: some View {
        Color.clear.frame(width:0,height:0)
            .translationTask(source:Locale.Language(identifier:StandaloneSentenceTranslationCache.sourceLanguageIdentifier),
                             target:Locale.Language(identifier:StandaloneSentenceTranslationCache.targetLanguageIdentifier)) { session in
                do {
                    try Task.checkCancellation()
                    if let cached = await StandaloneSentenceTranslationCache.shared.translation(for: text) {
                        try Task.checkCancellation()
                        onResult(cached)
                        return
                    }

                    // Keep the TranslationSession inside this callback. It is
                    // supplied by SwiftUI and must not be retained by the cache.
                    let result = try await session.translate(text).targetText
                    try Task.checkCancellation()
                    try await StandaloneSentenceTranslationCache.shared.store(result, for: text)
                    try Task.checkCancellation()
                    onResult(result)
                } catch {
                    guard !(error is CancellationError), !Task.isCancelled else { return }
                    onError("翻译失败：\(error.localizedDescription)")
                }
            }
            .id(Data(text.utf8))
    }
}

/// A bounded cache for the standalone sentence-translation route. It is
/// intentionally independent from the context-reading feature switch and
/// complete-sentence validation used by `SentenceTranslationService`.
actor StandaloneSentenceTranslationCache {
    static let shared = StandaloneSentenceTranslationCache()
    static let maximumCachedEntries = 32
    static let maximumOutputUTF16Units = 8_192
    static let sourceLanguageIdentifier = "en"
    static let targetLanguageIdentifier = "zh-Hans"
    static let backendVersion = "apple-translation-session-v1"

    private struct CacheKey: Hashable {
        let textUTF8: [UInt8]
        let sourceLanguageIdentifier: String
        let targetLanguageIdentifier: String
        let backendVersion: String
    }

    private let maximumCachedEntries: Int
    private var values: [CacheKey: String] = [:]
    private var recency: [CacheKey] = []

    init(maximumCachedEntries: Int = StandaloneSentenceTranslationCache.maximumCachedEntries) {
        self.maximumCachedEntries = max(0, maximumCachedEntries)
    }

    func translation(for text: String) -> String? {
        let key = key(for: text)
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    func store(_ translation: String, for text: String) throws {
        try Task.checkCancellation()
        guard !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StandaloneSentenceTranslationCacheError.emptyTranslation
        }
        guard (translation as NSString).length <= Self.maximumOutputUTF16Units else {
            throw StandaloneSentenceTranslationCacheError.outputTooLong(maximumUTF16Units: Self.maximumOutputUTF16Units)
        }
        guard maximumCachedEntries > 0 else { return }

        let key = key(for: text)
        values[key] = translation
        touch(key)
        while recency.count > maximumCachedEntries {
            let evicted = recency.removeFirst()
            values.removeValue(forKey: evicted)
        }
    }

    var cachedEntryCount: Int { values.count }

    private func key(for text: String) -> CacheKey {
        CacheKey(textUTF8: Array(text.utf8),
                 sourceLanguageIdentifier: Self.sourceLanguageIdentifier,
                 targetLanguageIdentifier: Self.targetLanguageIdentifier,
                 backendVersion: Self.backendVersion)
    }

    private func touch(_ key: CacheKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

enum StandaloneSentenceTranslationCacheError: Error, Equatable, LocalizedError {
    case emptyTranslation
    case outputTooLong(maximumUTF16Units: Int)

    var errorDescription: String? {
        switch self {
        case .emptyTranslation:
            return "翻译服务返回了空译文。"
        case .outputTooLong(let maximumUTF16Units):
            return "译文超过了 \(maximumUTF16Units) 个 UTF-16 单元限制。"
        }
    }
}
