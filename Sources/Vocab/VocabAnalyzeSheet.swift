import SwiftUI
import PDFKit

/// 词频分析 · 批量收录(v0.12.0,M7;P1 扩展):
/// 统计本文档词频 → ECDICT 富化(考试标签 / 柯林斯星级 / 牛津核心词)→ 多条件筛选 →
/// 勾选后一键批量加入生词本(已收录词自动排除;**基础词**可选排除)。
struct VocabAnalyzeSheet: View {
    let url: URL
    let docSha: String
    let store: VocabStore
    var onDone: () -> Void = {}

    struct AnalyzeEntry: Identifiable {
        let lemma: String
        let surface: String
        let count: Int
        let tags: Set<String>
        let collins: Int
        let oxford: Bool
        var id: String { lemma }
    }

    private static let tagOrder = ["zk", "gk", "cet4", "cet6", "ky", "toefl", "ielts", "gre"]
    private static let tagNames: [String: String] = [
        "zk": "中考", "gk": "高考", "cet4": "四级", "cet6": "六级",
        "ky": "考研", "toefl": "托福", "ielts": "雅思", "gre": "GRE",
    ]

    @Environment(\.dismiss) private var dismiss
    @State private var analyzing = true
    @State private var allEntries: [AnalyzeEntry] = []
    @State private var selected: Set<String> = []
    @State private var minCount = 2
    @State private var tagFilter: Set<String> = []
    @State private var minCollins = 0
    @State private var excludeOxford = false
    @State private var collecting = false

    private var visible: [AnalyzeEntry] {
        allEntries.filter { entry in
            entry.count >= minCount
                && entry.collins >= minCollins
                && (!excludeOxford || !entry.oxford)
                && (tagFilter.isEmpty || !tagFilter.isDisjoint(with: entry.tags))
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if analyzing {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在统计词频并匹配 ECDICT…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    listBody
                }
            }
            .navigationTitle("词频分析 · 批量收录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !analyzing {
                    bottomBar
                }
            }
            .task { await analyze() }
        }
    }

    private var listBody: some View {
        List {
            Section {
                Picker("最少出现次数", selection: $minCount) {
                    Text("≥1").tag(1)
                    Text("≥2").tag(2)
                    Text("≥3").tag(3)
                    Text("≥5").tag(5)
                    Text("≥10").tag(10)
                }
                .pickerStyle(.menu)
                Picker("柯林斯星级", selection: $minCollins) {
                    Text("不限").tag(0)
                    Text("≥1★").tag(1)
                    Text("≥3★").tag(3)
                    Text("≥4★").tag(4)
                    Text("5★").tag(5)
                }
                .pickerStyle(.menu)
                Toggle("排除牛津核心词(基础词)", isOn: $excludeOxford)
                VStack(alignment: .leading, spacing: 6) {
                    Text("考试标签(任一命中即可)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.tagOrder, id: \.self) { tag in
                                let active = tagFilter.contains(tag)
                                Button {
                                    if active {
                                        tagFilter.remove(tag)
                                    } else {
                                        tagFilter.insert(tag)
                                    }
                                } label: {
                                    Text(Self.tagNames[tag] ?? tag)
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(active ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                                        .foregroundStyle(active ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                HStack {
                    Text("共 \(visible.count) 词 · 已选 \(visibleSelectedCount)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("全选可见") { autoSelectVisible() }
                        .font(.footnote)
                    Button("清空") { selected.removeAll() }
                        .font(.footnote)
                }
            } header: {
                Text("筛选")
            }
            Section {
                ForEach(visible.prefix(2_000)) { entry in
                    Button {
                        if selected.contains(entry.lemma) {
                            selected.remove(entry.lemma)
                        } else {
                            selected.insert(entry.lemma)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected.contains(entry.lemma) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(entry.lemma) ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.surface)
                                    .font(.body)
                                HStack(spacing: 6) {
                                    Text("\(entry.count) 次")
                                    if entry.collins > 0 {
                                        Text(String(repeating: "★", count: entry.collins))
                                    }
                                    ForEach(Array(entry.tags).sorted().prefix(3), id: \.self) { t in
                                        Text(Self.tagNames[t] ?? t)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("候选单词(按出现次数排序,最多显示 2000)")
            } footer: {
                Text("已收录的词已自动排除;批量收录只建词卡(不携带位置),单词高亮会随下次在文中选中该词自动出现。")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var visibleSelectedCount: Int {
        visible.reduce(0) { $0 + (selected.contains($1.lemma) ? 1 : 0) }
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Text("已选 \(selected.count) 词")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                collectSelected()
            } label: {
                if collecting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("收录中…")
                    }
                } else {
                    Label("加入生词本", systemImage: "plus.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(collecting || selected.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 分析(后台)

    private func analyze() async {
        analyzing = true
        let url = self.url
        let db = store.db
        let docSha = self.docSha
        let entries = await Task.detached(priority: .userInitiated) { () -> [AnalyzeEntry] in
            guard let doc = PDFDocument(url: url) else { return [] }
            let regex = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z'’-]+")
            var freq: [String: Int] = [:]
            var textPages = 0

            func count(_ text: String) {
                guard let regex, !text.isEmpty else { return }
                let ns = text as NSString
                for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let token = ns.substring(with: match.range).lowercased()
                    if token.count < 3 { continue }
                    freq[token, default: 0] += 1
                }
            }

            // v0.23.2:逐页统计,**不再用 2M 字符上限截断**(旧实现大书只分析前半本)
            for i in 0..<doc.pageCount {
                guard let pageText = doc.page(at: i)?.string, !pageText.isEmpty else { continue }
                textPages += 1
                count(pageText)
            }

            // v0.23.2:扫描版(文字层覆盖不足一半)用整本 OCR 词表补全
            if textPages * 2 < doc.pageCount {
                let ocrWords = OCRStore(db: db).allWordTexts(docSha: docSha)
                for word in ocrWords { count(word) }
                DiagLog.log("analyze: textPages=\(textPages)/\(doc.pageCount) ocrWords=\(ocrWords.count)")
            }

            guard !freq.isEmpty else { return [] }
            let collected = Set(VocabStore(db: db).listWords().map { $0.lemma })
            var merged: [String: (surface: String, count: Int, tags: Set<String>, collins: Int, oxford: Bool)] = [:]
            // v0.23.2:top 4000 → 20000,避免「低频词整批消失」
            for (token, count) in freq.sorted(by: { $0.value > $1.value }).prefix(20_000) {
                var lemma = token
                var surface = token
                var tags: Set<String> = []
                var collins = 0
                var oxford = false
                if case .found(let entry) = DictionaryService.lookup(token) {
                    lemma = entry.word.lowercased()
                    surface = entry.word
                    tags = Set(entry.tags)
                    collins = entry.collins
                    oxford = entry.oxford
                }
                if collected.contains(lemma) { continue }
                let previous = merged[lemma]
                merged[lemma] = (
                    surface: surface,
                    count: (previous?.count ?? 0) + count,
                    tags: (previous?.tags ?? []).union(tags),
                    collins: max(previous?.collins ?? 0, collins),
                    oxford: (previous?.oxford ?? false) || oxford
                )
            }
            return merged
                .map { key, value in
                    AnalyzeEntry(
                        lemma: key,
                        surface: value.surface,
                        count: value.count,
                        tags: value.tags,
                        collins: value.collins,
                        oxford: value.oxford
                    )
                }
                .sorted { $0.count > $1.count }
        }.value
        allEntries = entries
        autoSelectVisible()
        analyzing = false
    }

    private func autoSelectVisible() {
        selected = Set(visible.map { $0.lemma })
    }

    private func collectSelected() {
        let lemmas = selected
        let byLemma = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.lemma, $0) })
        let vs = store
        collecting = true
        Task {
            await Task.detached(priority: .userInitiated) {
                for lemma in lemmas {
                    let surface = byLemma[lemma]?.surface ?? lemma
                    _ = vs.collectHeadword(lemma: lemma, surface: surface)
                }
            }.value
            collecting = false
            onDone()
            dismiss()
        }
    }
}
