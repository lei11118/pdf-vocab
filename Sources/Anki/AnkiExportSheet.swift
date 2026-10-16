import SwiftUI
import UIKit

/// M5(v0.11.0):「导出到 Anki」面板——.apkg(genanki 同款)主路径 + CSV/TSV 兜底;系统分享面板导出。
struct AnkiExportSheet: View {
    let store: VocabStore
    let words: [VocabStore.WordSummary]

    @Environment(\.dismiss) private var dismiss
    @State private var deckName = "跃文"
    @State private var includeAudio = true
    @State private var running = false
    @State private var progressText = ""
    @State private var shareItem: ShareItem?
    @State private var errorText: String?
    @AppStorage("ankiLastDeckName") private var savedDeckName = "跃文"

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("牌组名(可用 :: 建子牌组)", text: $deckName)
                    Toggle("生成发音音频(TTS,离线)", isOn: $includeAudio)
                } header: {
                    Text("Anki 导出")
                } footer: {
                    Text("把当前列表的 \(words.count) 个单词导出为 .apkg 词卡组。字段:单词 / 音标 / 中文释义 / 英文释义 / 例句 / 出处 / 备注 / 发音。重复导出同一单词,Anki 导入时更新而非重复。音频为系统 TTS 离线合成,每词约 1 秒。")
                }
                Section {
                    Button {
                        Task { await exportApkg() }
                    } label: {
                        if running {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(progressText.isEmpty ? "正在生成…" : progressText)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Label("导出 .apkg(可直接导入 Anki)", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(running || words.isEmpty)
                    Button {
                        exportCSV()
                    } label: {
                        Label("导出 CSV(兜底,任何表格软件可开)", systemImage: "tablecells")
                    }
                    .disabled(running || words.isEmpty)
                }
                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(item: $shareItem) { item in
                ActivityShareView(items: [item.url])
            }
        }
        .onAppear {
            deckName = savedDeckName.isEmpty ? "跃文" : savedDeckName
        }
    }

    // MARK: - .apkg 导出

    private func exportApkg() async {
        running = true
        errorText = nil
        savedDeckName = deckName
        let deck = deckName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "跃文" : deckName
        let includeAudioV = includeAudio
        let list = words
        let db = store.db
        progressText = "准备词条…"
        do {
            let url = try await Task.detached(priority: .userInitiated) { () async throws -> URL in
                let vs = VocabStore(db: db)
                var notes: [AnkiNoteData] = []
                for (i, w) in list.enumerated() {
                    var phonetic = "", translation = "", definition = ""
                    if case .found(let entry) = DictionaryService.lookup(w.lemma) {
                        phonetic = entry.phonetic ?? ""
                        translation = Self.htmlize(entry.translation ?? "")
                        definition = Self.htmlize(entry.definition ?? "")
                    }
                    let occ = vs.occurrences(forLemma: w.lemma).first
                    let context = Self.htmlize(occ?.context ?? "")
                    let source = occ.map { "\($0.docTitle) · 第 \($0.page + 1) 页" } ?? ""
                    let note = Self.htmlize(vs.note(forLemma: w.lemma))
                    let memberIds = vs.groupIds(forLemma: w.lemma)
                    let tagNames = vs.groups().filter { memberIds.contains($0.id) }.map { $0.name }
                    var audioURL: URL?
                    var audioName: String?
                    if includeAudioV {
                        if let au = await AnkiAudio.audioFile(forKey: w.lemma, term: w.surface) {
                            audioURL = au
                            audioName = au.lastPathComponent
                        }
                        let done = i + 1
                        await MainActor.run {
                            progressText = "生成音频 \(done)/\(list.count)…"
                        }
                    }
                    notes.append(AnkiNoteData(
                        term: w.surface,
                        key: w.lemma,
                        phonetic: phonetic,
                        translation: translation,
                        definition: definition,
                        context: context,
                        source: source,
                        note: note,
                        tags: tagNames,
                        audioFileName: audioName,
                        audioURL: audioURL
                    ))
                }
                await MainActor.run { progressText = "打包 .apkg…" }
                return try AnkiExporter.makeApkg(
                    notes: notes,
                    options: AnkiExportOptions(deckName: deck, includeAudio: includeAudioV)
                )
            }.value
            shareItem = ShareItem(url: url)
        } catch {
            errorText = "导出失败:\(error.localizedDescription)"
            DiagLog.log("anki: export failed \(error)")
        }
        running = false
    }

    // MARK: - CSV 兜底

    private func exportCSV() {
        let list = words
        let db = store.db
        let deck = deckName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "跃文" : deckName
        running = true
        progressText = "生成 CSV…"
        Task.detached(priority: .userInitiated) {
            let vs = VocabStore(db: db)
            func clean(_ s: String) -> String {
                s.replacingOccurrences(of: "\t", with: " ")
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
            }
            var lines = ["word\tphonetic\tchinese\tenglish\texample\tsource\tnote\tdeck"]
            for w in list {
                var phonetic = "", translation = "", definition = ""
                if case .found(let entry) = DictionaryService.lookup(w.lemma) {
                    phonetic = entry.phonetic ?? ""
                    translation = entry.translation ?? ""
                    definition = entry.definition ?? ""
                }
                let occ = vs.occurrences(forLemma: w.lemma).first
                let source = occ.map { "\($0.docTitle) · 第 \($0.page + 1) 页" } ?? ""
                lines.append([
                    clean(w.surface),
                    clean(phonetic),
                    clean(translation),
                    clean(definition),
                    clean(occ?.context ?? ""),
                    clean(source),
                    clean(vs.note(forLemma: w.lemma)),
                    clean(deck),
                ].joined(separator: "\t"))
            }
            let text = lines.joined(separator: "\n")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("跃文生词-\(Int(Date().timeIntervalSince1970)).tsv")
            try? text.data(using: .utf8)?.write(to: url)
            await MainActor.run {
                running = false
                shareItem = ShareItem(url: url)
            }
        }
    }

    /// 释义转展示 HTML(转义 + 换行 → <br>)。
    private static func htmlize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}

/// 通用分享条目(v0.12.0:阅读页导出批注版 / 设置页备份导出复用)。
struct ShareFileItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIActivityViewController 包装(iPad 分享面板)。
struct ActivityShareView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
