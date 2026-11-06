import SwiftUI

/// 侧边卡片内容
enum ReaderCardContent: Equatable {
    case word(String)
    case sentence(String, Int)
    case contextual(ContextualSelection)
}

/// 词卡与生词本之间的查询、收录及义项选择接口。
struct CardVocabBridge {
    /// 查询收录状态(键 = 归一化词元)
    var query: (String) -> (collected: Bool, occurrenceCount: Int)
    /// v0.13.0:义项勾选 —— 返回被排除的义项序号集合(译文按行分义项)
    var excludedSenses: ((String) -> Set<Int>)? = nil
    /// v0.13.0:切换义项勾选(key + 行号 + 是否保留);「卡片只保留需要的义项」
    var setSense: ((String, Int, Bool) -> Void)? = nil
    var collect: ((String, String) -> Bool)? = nil
}

/// 侧边词卡容器(单词卡 / 整句卡)
struct WordCardPanel: View {
    let content: ReaderCardContent
    let onClose: () -> Void
    let onSelectWord: (String) -> Void
    var vocab: CardVocabBridge? = nil
    @State private var selectedSentenceWord: String?

    var body: some View {
        Group {
            switch content {
            case .word(let term):
                WordCardView(term: term, onClose: onClose, vocab: vocab)
            case .sentence(let text, let count):
                ZStack(alignment:.topLeading) {
                    SentenceCardView(text:text,wordCount:count,onClose:onClose) { word in
                        selectedSentenceWord = word
                        onSelectWord(word)
                    }
                    .opacity(selectedSentenceWord == nil ? 1 : 0)
                    .allowsHitTesting(selectedSentenceWord == nil)
                    .accessibilityHidden(selectedSentenceWord != nil)
                    if let word = selectedSentenceWord {
                        VStack(spacing:0) {
                            HStack {
                                Button { selectedSentenceWord = nil } label: {
                                    Label("返回句子",systemImage:"chevron.left")
                                }.buttonStyle(.plain)
                                Spacer()
                            }.padding(.horizontal,16).padding(.top,16).padding(.trailing,44)
                            WordCardView(term:word,onClose:onClose,vocab:vocab).id(word)
                        }
                    }
                }
            case .contextual(let selection):
                ContextualCardView(selection: selection, onClose: onClose, vocab: vocab)
            }
        }
        .onChange(of:content) { _, _ in selectedSentenceWord = nil }
    }
}

/// A local token surface with an honest context status and an optional path
/// to the existing dictionary card. No source sentence or translation is shown.
struct ContextualCardView: View {
    @Environment(\.readerPanelClose) private var panelClose
    @AppStorage(FeatureFlags.contextReadingEnabledKey) private var contextReadingEnabled = false
    let selection: ContextualSelection
    let onClose: () -> Void
    var vocab: CardVocabBridge? = nil
    @State private var showingDictionary = false
    @StateObject private var translationDriver = ContextualTranslationDriver()

    var body: some View {
        Group {
            if showingDictionary {
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            showingDictionary = false
                        } label: {
                            Label("返回语境", systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if panelClose == nil { closeButton(onClose) }
                    }
                    .padding(.horizontal, DS.Space.l)
                    .padding(.top, DS.Space.l)
                    .padding(.trailing, panelClose == nil ? 0 : 44)
                    WordCardView(term: selection.displaySurface, onClose: onClose, vocab: vocab)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        HStack(alignment: .top) {
                            Text(selection.displaySurface)
                                .font(DS.Fonts.wordTitle)
                                .foregroundStyle(DS.foreground1)
                                .textSelection(.enabled)
                                .accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 0)
                            if panelClose == nil { closeButton(onClose) }
                        }
                        .padding(.trailing, panelClose == nil ? 0 : 44)

                        ContextualTranslationTaskView(selection: selection,
                                                      isEnabled: contextReadingEnabled,
                                                      driver: translationDriver)

                        Button("查看词典释义") {
                            showingDictionary = true
                        }
                        .buttonStyle(DSPillButtonStyle())
                        .accessibilityHint("打开现有词典释义、发音和生词本信息")
                    }
                    .padding(DS.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("contextual-card")
            }
        }
        .onChange(of: selection) { _, _ in showingDictionary = false }
    }
}

// MARK: - 单词卡

struct WordCardView: View {
    @Environment(\.readerPanelClose) private var panelClose
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
    @State private var excludedSenses: Set<Int> = []

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Text(term)
                    .font(DS.Fonts.wordTitle)
                    .foregroundStyle(DS.foreground1)
                    .textSelection(.enabled)
                Spacer()
                if panelClose == nil { closeButton(onClose) }
            }
            .padding(.trailing,panelClose == nil ? 0 : 44)

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
                    .foregroundStyle(DS.caution)
                    .padding(.top, 12)
            }

            if let vocab, state != .loading, state != .missing {
                vocabBar(vocab)
            }

            Spacer(minLength: 0)
        }
        .padding(DS.Space.m)
        }
        .background(DS.background2)

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
            excludedSenses = vocab.excludedSenses?(key) ?? []
        }
    }

    // MARK: - 生词本(v0.7.0)

    /// 词卡内可直接收录，已有条目展示语境数量。
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
                    Text("未收录")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !vocabCollected, let collect = vocab.collect {
                    Button {
                        if collect(vocabKey,term) {
                            let updated = vocab.query(vocabKey)
                            vocabCollected = updated.collected
                            vocabCount = updated.occurrenceCount
                            excludedSenses = vocab.excludedSenses?(vocabKey) ?? []
                        }
                    } label: { Label("加入生词本",systemImage:"plus.circle") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
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
                            .font(DS.Fonts.monoCaption)
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
                            .background(DS.accentContainer, in: RoundedRectangle(cornerRadius: DS.Radius.sharp))
                            .foregroundStyle(DS.accent)
                    }
                }
            }

            Divider()

            Group {
                VStack(alignment: .leading, spacing: 14) {
                    if let translation = entry.translation, !translation.isEmpty {
                        // v0.13.0:义项勾选 —— 已收录词可逐条勾选保留(卡片只保留需要的义项;导出同步过滤)
                        let canEditSenses = vocabCollected && (vocab?.setSense != nil)
                        if canEditSenses {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("释义(勾选保留;取消的义项不出现在卡片与导出)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                let senseLines = translation.components(separatedBy: "\n")
                                ForEach(Array(senseLines.enumerated()), id: \.offset) { index, line in
                                    let kept = !excludedSenses.contains(index)
                                    Button {
                                        guard let setSense = vocab?.setSense else { return }
                                        setSense(vocabKey, index, !kept)
                                        if kept {
                                            excludedSenses.insert(index)
                                        } else {
                                            excludedSenses.remove(index)
                                        }
                                    } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Image(systemName: kept ? "checkmark.circle.fill" : "circle")
                                                .font(.footnote)
                                                .foregroundStyle(kept ? Color.accentColor : Color.secondary)
                                            Text(line.isEmpty ? " " : line)
                                                .font(.callout)
                                                .foregroundStyle(kept ? .primary : .tertiary)
                                                .multilineTextAlignment(.leading)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(DSPressableButtonStyle())
                                }
                            }
                        } else {
                            definitionSection(title: "释义", content: translation)
                        }
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
                .font(secondary ? DS.Fonts.caption : DS.Fonts.wordBody)
                .foregroundStyle(secondary ? DS.foreground3 : DS.foreground1)
                .lineSpacing(4)
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
    @Environment(\.readerPanelClose) private var panelClose
    @EnvironmentObject private var translation: SentenceTranslationState
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
                Button {
                    translation.start(SentenceTranslationRequest(text:text))
                } label: {
                    Label("翻译", systemImage: "character.book.closed")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if panelClose == nil { closeButton(onClose) }
            }
            .padding(.trailing,panelClose == nil ? 0 : 44)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(text)
                        .font(DS.Fonts.wordQuote)
                        .foregroundStyle(DS.foreground1)
                        .lineSpacing(5)
                        .textSelection(.enabled)

                    if let translated = translation.displayText {
                        Text(translated)
                            .font(DS.Fonts.wordBody)
                            .foregroundStyle(DS.foreground1)
                            .textSelection(.enabled)
                    }

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
                                        .background(DS.accentContainer, in: RoundedRectangle(cornerRadius: DS.Radius.sharp))
                                        .foregroundStyle(DS.accent)
                                }
                                .buttonStyle(DSPressableButtonStyle())
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
            .foregroundStyle(DS.foreground2)
            .frame(width: 44, height: 44)
    }
    .buttonStyle(DSPressableButtonStyle())
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
            let size = sub.sizeThatFits(ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil))
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
            let size = sub.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
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

// MARK: - 胶囊迷你卡

/// 窗口缩小时仅显示选中文字和简要译文。
struct CompactCardView: View {
    let content: ReaderCardContent
    let onClose: () -> Void
    var sentenceTranslation: String? = nil

    @State private var translation: String?

    private var displayText: String {
        switch content {
        case .word(let term):
            return term
        case .sentence(let text, _):
            return text
        case .contextual(let selection):
            return selection.displaySurface
        }
    }

    private var lookupTerm: String? {
        if case .word(let term) = content {
            return term
        }
        if case .contextual(let selection) = content {
            return selection.displaySurface
        }
        return nil
    }

    var body: some View {
        HStack(alignment:.center,spacing:10) {
            Text(displayText).font(.subheadline.weight(.semibold)).lineLimit(1)
            if let value = sentenceTranslation ?? translation, !value.isEmpty {
                Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength:0)
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
        .padding(.vertical,8).padding(.leading,16).padding(.trailing,92)
        .task(id:displayText) { await loadTranslation() }
    }

    private func loadTranslation() async {
        translation = nil
        guard let term = lookupTerm else {
            return
        }
        let outcome = await Task.detached(priority: .utility) {
            DictionaryService.lookup(term)
        }.value
        guard !Task.isCancelled else { return }
        if case .found(let entry) = outcome {
            translation = WordInteraction.chineseDetail(entry)?.components(separatedBy:"\n").prefix(2).joined(separator:"；")
        } else {
            translation = nil
        }
    }
}
