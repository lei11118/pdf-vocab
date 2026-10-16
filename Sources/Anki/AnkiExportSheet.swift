import SwiftUI
import UIKit

/// M5(v0.11.0)/ v0.13.0 增强:「导出到 Anki」面板 —— 基础卡 + 反向卡 + 挖空卡 + 页面截图 + 字段勾选;CSV 兜底。
struct AnkiExportSheet: View {
    let store: VocabStore
    let words: [VocabStore.WordSummary]
    var docStore: DocumentStore? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var deckName = "跃文"
    @State private var includeAudio = true
    @State private var includeReverse = false
    @State private var includeCloze = false
    @State private var includeScreenshot = false
    @State private var showPhonetic = true
    @State private var showDefinition = true
    @State private var showContext = true
    @State private var showSource = true
    @State private var showNote = true
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
                    Text("把当前列表的 \(words.count) 个单词导出为 .apkg 词卡组。重复导出同一单词,Anki 导入时更新而非重复。音频为系统 TTS 离线合成,每词约 1 秒。")
                }
                Section {
                    Toggle("附加反向卡(释义 → 单词)", isOn: $includeReverse)
                    Toggle("生成挖空卡(例句填空)", isOn: $includeCloze)
                    Toggle("附带页面截图(原文高亮处)", isOn: $includeScreenshot)
                } header: {
                    Text("增强")
                } footer: {
                    Text("反向卡:看中文释义/例句回想单词;挖空卡:把例句中的目标词挖空成填空题(需该词已有例句;重复导出会保留已生成的挖空卡);页面截图:把该词在 PDF 中出现的原文截图片放入卡片背面(需收录时带出处)。")
                }
                Section {
                    Toggle("音标", isOn: $showPhonetic)
                    Toggle("英文释义", isOn: $showDefinition)
                    Toggle("例句", isOn: $showContext)
                    Toggle("出处", isOn: $showSource)
                    Toggle("备注", isOn: $showNote)
                } header: {
                    Text("字段")
                } footer: {
                    Text("取消勾选的字段导出时留空;「单词」与「中文释义」总会导出(中文释义按词卡的义项勾选过滤)。")
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
        let includeReverseV = includeReverse
        let includeClozeV = includeCloze
        let includeScreenshotV = includeScreenshot
        let showPhoneticV = showPhonetic
        let showDefinitionV = showDefinition
        let showContextV = showContext
        let showSourceV = showSource
        let showNoteV = showNote
        let list = words
        let db = store.db
        let docStoreV = docStore
        progressText = "准备词条…"
        do {
            let url = try await Task.detached(priority: .userInitiated) { () async throws -> URL in
                let vs = VocabStore(db: db)
                var notes: [AnkiNoteData] = []
                var pdfURLs: [String: URL?] = [:]
                for (i, w) in list.enumerated() {
                    var phonetic = "", translation = "", definition = ""
                    if case .found(let entry) = DictionaryService.lookup(w.lemma) {
                        phonetic = showPhoneticV ? (entry.phonetic ?? "") : ""
                        translation = Self.filteredTranslation(
                            entry.translation ?? "",
                            excluded: vs.excludedSenseIndices(forLemma: w.lemma)
                        )
                        definition = showDefinitionV ? Self.htmlize(entry.definition ?? "") : ""
                    }
                    let occ = vs.occurrences(forLemma: w.lemma).first
                    let context = showContextV ? Self.htmlize(occ?.context ?? "") : ""
                    let source = showSourceV ? (occ.map { "\($0.docTitle) · 第 \($0.page + 1) 页" } ?? "") : ""
                    let note = showNoteV ? Self.htmlize(vs.note(forLemma: w.lemma)) : ""
                    let memberIds = vs.groupIds(forLemma: w.lemma)
                    let tagNames = vs.groups().filter { memberIds.contains($0.id) }.map { $0.name }

                    var media: [NoteMedia] = []
                    var audioName: String?
                    if includeAudioV, let audioURL = await AnkiAudio.audioFile(forKey: w.lemma, term: w.surface) {
                        audioName = audioURL.lastPathComponent
                        media.append(NoteMedia(url: audioURL, name: audioURL.lastPathComponent))
                    }
                    var shotName: String?
                    if includeScreenshotV, let docStoreV, let sha = w.sourceDocSha, let page = w.sourcePage {
                        let pdfURL: URL? = {
                            if let cached = pdfURLs[sha] { return cached }
                            let resolved: URL? = {
                                guard let rec = try? docStoreV.document(sha256: sha),
                                      let u = try? docStoreV.pdfURL(for: rec) else { return nil }
                                return u
                            }()
                            pdfURLs[sha] = resolved
                            return resolved
                        }()
                        let rects = w.sourceRectsJSON.map { VocabStore.rectsFromJSON($0) } ?? []
                        if let pdfURL, let png = AnkiExporter.pageScreenshot(pdfURL: pdfURL, pageIndex: page, rects: rects) {
                            let name = "pv_shot_\(w.lemma).png"
                            let tmp = FileManager.default.temporaryDirectory
                                .appendingPathComponent("anki-shot-\(UUID().uuidString).png")
                            if (try? png.write(to: tmp)) != nil {
                                shotName = name
                                media.append(NoteMedia(url: tmp, name: name))
                            }
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
                        audioName: audioName,
                        shotName: shotName,
                        media: media
                    ))
                    let done = i + 1
                    await MainActor.run { progressText = "准备词条 \(done)/\(list.count)…" }
                }
                await MainActor.run { progressText = "打包 .apkg…" }
                return try AnkiExporter.makeApkg(
                    notes: notes,
                    options: AnkiExportOptions(
                        deckName: deck,
                        includeAudio: includeAudioV,
                        includeReverse: includeReverseV,
                        includeCloze: includeClozeV,
                        includeScreenshot: includeScreenshotV
                    )
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

    /// 按义项勾选过滤译文行(v0.13.0),再转 HTML。
    private static func filteredTranslation(_ raw: String, excluded: Set<Int>) -> String {
        guard !excluded.isEmpty else { return htmlize(raw) }
        let lines = raw.components(separatedBy: "\n")
        let kept = lines.enumerated().filter { !excluded.contains($0.offset) }.map { $0.element }
        return htmlize(kept.joined(separator: "\n"))
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
