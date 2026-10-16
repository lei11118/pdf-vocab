import SwiftUI

/// 侧边卡片内容
enum ReaderCardContent: Equatable {
    case word(String)
    case sentence(String, Int)
}

/// 词卡 ↔ 生词本桥(v0.7.0;v0.10.0 精简——「加入生词本 / 高亮 / 已掌握」交互全部移出词卡,
/// 统一到编辑栏(Task 2.1)与生词本页;此处只读查询收录状态)。
struct CardVocabBridge {
    /// 查询收录状态(键 = 归一化词元)
    var query: (String) -> (collected: Bool, occurrenceCount: Int)
}

/// 侧边词卡容器(单词卡 / 整句卡)
struct WordCardPanel: View {
    let content: ReaderCardContent
    let onClose: () -> Void
    let onSelectWord: (String) -> Void
    var vocab: CardVocabBridge? = nil

    var body: some View {
        Group {
            switch content {
            case .word(let term):
                WordCardView(term: term, onClose: onClose, vocab: vocab)
            case .sentence(let text, let count):
                SentenceCardView(text: text, wordCount: count, onClose: onClose, onSelectWord: onSelectWord)
            }
        }
    }
}

// MARK: - 单词卡

struct WordCardView: View {
    let term: String
    let onClose: () -> Void
    var vocab: CardVocabBridge? = nil

    private enum LoadState: Equatable {
        case loading
        case found(DictEntry)
        case notFound
        case missing
    }

    @State private var state: LoadState = .loading
    @State private var vocabKey = ""
    @State private var vocabCollected = false
    @State private var vocabCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(term)
                    .font(.title2.bold())
                    .textSelection(.enabled)
                Spacer()
                closeButton(onClose)
            }

            switch state {
            case .loading:
                ProgressView()
                    .padding(.top, 24)
            case .found(let entry):
                foundBody(entry)
            case .notFound:
                Text("词库中未找到「\(term)」")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            case .missing:
                Text("内置词库缺失(此构建未包含词库)")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 12)
            }

            if let vocab, state != .loading, state != .missing {
                vocabBar(vocab)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .task(id: term) { await load() }
    }

    private func load() async {
        state = .loading
        let term = self.term
        let outcome = await Task.detached(priority: .userInitiated) {
            DictionaryService.lookup(term)
        }.value
        var key = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch outcome {
        case .found(let entry):
            state = .found(entry)
            if !entry.word.isEmpty { key = entry.word.lowercased() }
        case .notFound: state = .notFound
        case .dictionaryMissing: state = .missing
        }
        vocabKey = key
        if let vocab {
            let q = vocab.query(key)
            vocabCollected = q.collected
            vocabCount = q.occurrenceCount
        }
    }

    // MARK: - 生词本(v0.7.0)

    /// v0.10.0(Task 2.1):词卡只读展示收录状态;「加入生词本 / 高亮 / 分组」在文本编辑栏与生词本页操作。
    @ViewBuilder
    private func vocabBar(_ vocab: CardVocabBridge) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                if vocabCollected {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("已收录 · \(vocabCount) 处语境")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("未收录 · 选中后点编辑栏「加入生词本」")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func foundBody(_ entry: DictEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if entry.word != term {
                        Text(entry.word)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    if let phonetic = entry.phonetic, !phonetic.isEmpty {
                        Text("/\(phonetic)/")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        SpeechService.shared.speak(entry.word, language: SpeechService.usVoice)
                    } label: {
                        Label("美", systemImage: "speaker.wave.2.fill")
                    }
                    Button {
                        SpeechService.shared.speak(entry.word, language: SpeechService.gbVoice)
                    } label: {
                        Label("英", systemImage: "speaker.wave.2.fill")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            let chips = badgeChips(entry)
            if !chips.isEmpty {
                WrapLayout(spacing: 6) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip)
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let translation = entry.translation, !translation.isEmpty {
                        definitionSection(title: "释义", content: translation)
                    }
                    if let definition = entry.definition, !definition.isEmpty {
                        definitionSection(title: "英文释义", content: definition, secondary: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func definitionSection(title: String, content: String, secondary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(content)
                .font(secondary ? .footnote : .callout)
                .foregroundStyle(secondary ? .secondary : .primary)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
    }

    private func badgeChips(_ entry: DictEntry) -> [String] {
        var chips: [String] = []
        let names: [(String, String)] = [
            ("zk", "中考"), ("gk", "高考"), ("cet4", "四级"), ("cet6", "六级"),
            ("ky", "考研"), ("toefl", "托福"), ("ielts", "雅思"), ("gre", "GRE"),
        ]
        for (tag, name) in names where entry.tags.contains(tag) {
            chips.append(name)
        }
        if entry.collins > 0 {
            chips.append("柯林斯 " + String(repeating: "★", count: min(entry.collins, 5)))
        }
        if entry.oxford {
            chips.append("牛津核心")
        }
        return chips
    }
}

// MARK: - 整句卡

struct SentenceCardView: View {
    let text: String
    let wordCount: Int
    let onClose: () -> Void
    let onSelectWord: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("整句 · \(wordCount) 个词")
                    .font(.headline)
                Spacer()
                closeButton(onClose)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(text)
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)

                    let words = WordPicker.lexicalWords(in: text)
                    if !words.isEmpty {
                        Divider()
                        Text("句中的词(点击查看)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        WrapLayout(spacing: 6) {
                            ForEach(words, id: \.self) { word in
                                Button {
                                    onSelectWord(word)
                                } label: {
                                    Text(word)
                                        .font(.callout)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
    }
}

// MARK: - 公共

private func closeButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "xmark.circle.fill")
            .font(.title3)
            .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
}

/// 简单流式布局(词块自动换行)
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 胶囊迷你卡(单词 + 声音 + 翻译,横着排;v0.6.4)

/// 窗口缩到最小时显示的横向基本信息:单词、发音按钮、翻译(首行)。
struct CompactCardView: View {
    let content: ReaderCardContent
    let onClose: () -> Void

    @State private var translation: String?

    private var displayText: String {
        switch content {
        case .word(let term):
            return term
        case .sentence(let text, _):
            return text.count > 60 ? String(text.prefix(60)) + "…" : text
        }
    }

    private var speakText: String {
        switch content {
        case .word(let term):
            return term
        case .sentence(let text, _):
            return text
        }
    }

    private var lookupTerm: String? {
        if case .word(let term) = content {
            return term
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(displayText)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Button {
                SpeechService.shared.speak(speakText, language: SpeechService.usVoice)
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("发音")
            if let translation, !translation.isEmpty {
                Text(translation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.leading, 16)
        // v0.10.0:右侧给缩放手柄 44pt 热区腾位置(× 不与热区重叠)
        .padding(.trailing, 52)
        .task(id: displayText) { await loadTranslation() }
    }

    private func loadTranslation() async {
        guard let term = lookupTerm else {
            translation = nil
            return
        }
        let outcome = await Task.detached(priority: .utility) {
            DictionaryService.lookup(term)
        }.value
        if case .found(let entry) = outcome, let raw = entry.translation, !raw.isEmpty {
            translation = raw.split(separator: "\n").first.map(String.init)
        } else {
            translation = nil
        }
    }
}
