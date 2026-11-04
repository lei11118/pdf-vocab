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
            .translationTask(source:Locale.Language(identifier:"en"),target:Locale.Language(identifier:"zh-Hans")) { session in
                do { onResult(try await session.translate(text).targetText) }
                catch { onError("翻译失败：\(error.localizedDescription)") }
            }
    }
}
