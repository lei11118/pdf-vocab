import SwiftUI
import Translation

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
private struct SentenceTranslationTask: View {
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
