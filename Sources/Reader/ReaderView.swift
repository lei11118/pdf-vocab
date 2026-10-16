import SwiftUI
import Translation
import UIKit
import PDFKit

/// 阅读页:PDF 渲染 + 取词 + 选页 + 阅读位置记忆。
struct ReaderView: View {
    let doc: DocumentRecord
    let store: DocumentStore

    @State private var currentPage: Int
    @State private var resolvedURL: URL?
    @State private var optimizing = false
    @State private var translateText = ""
    @State private var showTranslate = false
    @State private var showPageJump = false
    @State private var cardContent: ReaderCardContent?
    @State private var readerHandle = ReaderHandle()
    @State private var saveTask: Task<Void, Never>?
    @State private var showSettings = false
    @State private var showVocab = false
    @State private var suppressSave = false
    @AppStorage("autoSpeakOnSelect") private var autoSpeakOnSelect = false
    /// v0.9.0(M4):标记 / 选词模式(工具栏铅笔按钮或 Pencil Pro 挤压切换;持久记忆)
    @AppStorage("readerMarkMode") private var markMode = false
    /// v0.11.0(M4-B):Pencil 悬停预览 / 触觉开关
    @AppStorage("pencilHoverPreview") private var pencilHoverPreview = true
    @AppStorage("pencilHaptics") private var pencilHaptics = true
    /// v0.11.0(M4-B):悬停预览(迷你释义气泡)
    @State private var hoverTerm: String?
    @State private var hoverPoint: CGPoint = .zero
    @State private var hoverDetail: String?
    @State private var hoverTask: Task<Void, Never>?
    /// v0.11.0(M6):扫描版 OCR 进度
    @State private var ocrRunning = false
    @State private var ocrDone = 0
    @State private var ocrTotal = 0
    @Environment(\.scenePhase) private var scenePhase
    /// 生词本"一键抵达"目标(v0.8.0;来自主页生词本=预览模式,会话内不记忆阅读位置)
    let jumpTarget: VocabJumpTarget?

    init(doc: DocumentRecord, store: DocumentStore, jumpTarget: VocabJumpTarget? = nil) {
        self.doc = doc
        self.store = store
        self.jumpTarget = jumpTarget
        _currentPage = State(initialValue: jumpTarget?.page ?? doc.lastPage)
        _suppressSave = State(initialValue: jumpTarget != nil)
    }

    var body: some View {
        Group {
            if let url = try? store.pdfURL(for: doc), FileManager.default.fileExists(atPath: url.path) {
                reader(for: url)
            } else {
                ContentUnavailableView(
                    "文件缺失",
                    systemImage: "doc.questionmark",
                    description: Text("本地副本不存在,请在文档库中重新导入。")
                )
            }
        }
        .navigationTitle(doc.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showPageJump = true
                } label: {
                    Text("\(min(currentPage + 1, doc.pageCount)) / \(doc.pageCount)")
                        .font(.footnote.monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .accessibilityLabel("跳转页码")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showVocab = true
                } label: {
                    Image(systemName: "text.book.closed")
                }
                .accessibilityLabel("生词本")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    markMode.toggle()
                } label: {
                    Image(systemName: markMode ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                        .foregroundStyle(markMode ? Color.accentColor : Color.primary)
                }
                .accessibilityLabel(markMode ? "切换到选词模式" : "切换到标记模式")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showVocab) {
            VocabListView(store: VocabStore(db: store.db), scopeDocSha: doc.sha256, onJump: { target in
                showVocab = false
                readerHandle.coordinator?.jumpToVocab(target: target)
            })
        }
        .sheet(isPresented: $showPageJump) {
            PageJumpSheet(
                pageCount: doc.pageCount,
                current: currentPage,
                url: resolvedURL
            ) { target in
                readerHandle.coordinator?.go(toPage: target)
                currentPage = min(max(target, 0), doc.pageCount - 1)
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                saveProgressNow()
            }
        }
        .onDisappear {
            saveProgressNow()
        }
    }

    /// v0.6.9:选词后自动发音(设置项,默认关;美音)
    private func autoSpeak(_ term: String) {
        guard autoSpeakOnSelect else { return }
        SpeechService.shared.speak(term, language: SpeechService.usVoice)
    }

    /// v0.7.0:词卡 ↔ 生词本桥(v0.10.0 精简:只读;收录/高亮统一走编辑栏)
    private var cardVocab: CardVocabBridge {
        let vs = VocabStore(db: store.db)
        return CardVocabBridge(
            query: { key in
                (collected: vs.entryId(forLemma: key) != nil,
                 occurrenceCount: vs.occurrenceCount(forLemma: key))
            }
        )
    }

    private func reader(for url: URL) -> some View {
        pdfArea
            .overlay {
                GeometryReader { geo in
                    if let content = cardContent {
                        FloatingCardWindow(
                            content: content,
                            bounds: geo.size,
                            onClose: { cardContent = nil },
                            onSelectWord: { word in
                                cardContent = .word(word)
                                autoSpeak(word)
                            },
                            vocab: cardVocab
                        )
                    }
                    // v0.11.0(M4-B):Pencil 悬停迷你释义气泡(不拦截触摸)
                    if let hoverTerm, let hoverDetail {
                        HoverTipView(
                            term: hoverTerm,
                            detail: hoverDetail,
                            anchor: hoverPoint,
                            bounds: geo.size
                        )
                    }
                }
            }
            .animation(.easeInOut(duration: 0.18), value: cardContent)
    }

    /// v0.11.0(M6):扫描版自动 OCR(每文档一次;进度显示;完成后通知协调器刷新词框缓存)。
    private func runOCROnce() async {
        let sha = doc.sha256
        let ocrStore = OCRStore(db: store.db)
        if ocrStore.isDone(docSha: sha) { return }
        guard let url = try? store.pdfURL(for: doc) else { return }
        let scanned = await Task.detached(priority: .utility) { () -> Bool in
            guard let pdf = PDFDocument(url: url) else { return false }
            return OCRService.isScanned(document: pdf)
        }.value
        guard scanned else {
            ocrStore.markDone(docSha: sha)
            DiagLog.log("ocr: text-layer doc, skip")
            return
        }
        DiagLog.log("ocr: start (scanned doc)")
        ocrRunning = true
        ocrDone = 0
        ocrTotal = max(doc.pageCount, 1)
        await OCRService.run(url: url, docSha: sha, store: ocrStore) { current, total in
            DispatchQueue.main.async {
                ocrDone = current
                ocrTotal = total
            }
        }
        ocrRunning = false
        readerHandle.coordinator?.ocrDidFinish()
        DiagLog.log("ocr: done")
    }

    private var pdfArea: some View {
        Group {
            if let resolvedURL {
                PDFKitView(
                    url: resolvedURL,
                    restore: doc.readingState,
                    handle: readerHandle,
                    docSha: doc.sha256,
                    vocabStore: VocabStore(db: store.db),
                    inkStore: PencilInkStore(db: store.db),
                    ocrStore: OCRStore(db: store.db),
                    hoverPreviewEnabled: pencilHoverPreview,
                    hapticsEnabled: pencilHaptics,
                    onHoverUpdate: { term, key, point in
                        hoverTerm = term
                        hoverPoint = point
                        hoverDetail = nil
                        hoverTask?.cancel()
                        hoverTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            guard !Task.isCancelled else { return }
                            let detail = await Task.detached(priority: .utility) { () -> String? in
                                guard case .found(let entry) = DictionaryService.lookup(key) else { return nil }
                                var parts: [String] = []
                                if let phonetic = entry.phonetic, !phonetic.isEmpty {
                                    parts.append("/\(phonetic)/")
                                }
                                if let translation = entry.translation, !translation.isEmpty,
                                   let first = translation.split(separator: "\n").first {
                                    parts.append(String(first))
                                }
                                return parts.isEmpty ? nil : parts.joined(separator: "\n")
                            }.value
                            guard !Task.isCancelled, hoverTerm == term else { return }
                            hoverDetail = detail ?? "(词库未收录)"
                        }
                    },
                    onHoverEnd: {
                        hoverTask?.cancel()
                        hoverTask = nil
                        hoverTerm = nil
                        hoverDetail = nil
                    },
                    markMode: markMode,
                    jumpTarget: jumpTarget,
                    onVocabJumpPerformed: { suppressSave = true },
                    onVocabWordTap: { term in
                        cardContent = .word(term)
                    },
                    onPageChanged: { page in
                        currentPage = page
                        scheduleSave()
                    },
                    onSelectionInfo: { info in
                        // v0.6.4:点空白清选区 → 编辑栏与弹窗一起消失(用户要求);选区变化则更新弹窗内容
                        guard let info, !info.text.isEmpty else {
                            cardContent = nil
                            return
                        }
                        if info.wordCount <= 1, !info.primaryTerm.isEmpty {
                            cardContent = .word(info.primaryTerm)
                            autoSpeak(info.primaryTerm)
                        } else {
                            cardContent = .sentence(info.text, info.wordCount)
                        }
                    },
                    onReadingTick: {
                        scheduleSave()
                    },
                    onTeardown: {
                        saveProgressNow()
                    },
                    onTranslate: { text in
                        translateText = text
                        showTranslate = true
                    }
                )
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在准备文档…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) {
            if optimizing {
                Text("首次打开:正在生成优化副本…")
                    .font(.caption2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 44)
            }
        }
        .overlay(alignment: .top) {
            // v0.11.0(M6):扫描版 OCR 进度
            if ocrRunning {
                Text("扫描版文字识别中… \(ocrDone)/\(ocrTotal)")
                    .font(.caption2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
        .task(id: doc.sha256) {
            let store = self.store
            let doc = self.doc
            optimizing = true
            let url = await Task.detached(priority: .userInitiated) {
                store.normalizedForReading(doc)
            }.value
            resolvedURL = url
            optimizing = false
        }
        .task(id: doc.sha256) {
            await runOCROnce()
        }
        .translationPresentation(isPresented: $showTranslate, text: translateText)
    }

    // MARK: - 阅读位置保存(尾随防抖 2s + 切后台/退出强制保存)

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            saveProgressNow()
        }
    }

    private func saveProgressNow() {
        // v0.8.0:生词本"一键抵达"预览会话不记忆阅读位置(返回主页进度不被打乱)
        guard !suppressSave else { return }
        guard let state = readerHandle.coordinator?.captureReadingState() else { return }
        try? store.saveReadingState(state, for: doc.sha256)
    }
}

/// 页码跳转面板:按页码(输入 + 滑杆)/ 按缩略图,两种方式;越界处理。
private struct PageJumpSheet: View {
    let pageCount: Int
    let current: Int
    let onJump: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader: ThumbnailLoader
    @State private var mode = 0
    @State private var input = ""
    @State private var sliderValue: Double
    @State private var hint: String?

    init(pageCount: Int, current: Int, url: URL?, onJump: @escaping (Int) -> Void) {
        self.pageCount = pageCount
        self.current = current
        self.onJump = onJump
        _loader = StateObject(wrappedValue: ThumbnailLoader(url: url))
        let current1 = min(max(current + 1, 1), max(pageCount, 1))
        _sliderValue = State(initialValue: Double(current1))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("选页方式", selection: $mode) {
                    Text("按页码").tag(0)
                    Text("缩略图").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)

                if mode == 0 {
                    pageForm
                } else {
                    thumbnailGrid
                }
            }
            .navigationTitle("选页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onDisappear { loader.invalidate() }
        }
    }

    private var pageForm: some View {
        Form {
            Section("输入页码") {
                TextField("1 – \(pageCount)", text: $input)
                    .keyboardType(.numberPad)
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("跳转") { jumpFromInput() }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if pageCount > 1 {
                Section("滑杆") {
                    Slider(value: $sliderValue, in: 1...Double(pageCount), step: 1) { editing in
                        if !editing {
                            onJump(Int(sliderValue.rounded()) - 1)
                            dismiss()
                        }
                    }
                    HStack {
                        Text("第 \(Int(sliderValue.rounded())) 页")
                        Spacer()
                        Text("共 \(pageCount) 页")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                }
            }
        }
    }

    private var thumbnailGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 12) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        thumbCell(index)
                            .id(index)
                    }
                }
                .padding(16)
            }
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(min(max(current, 0), max(pageCount - 1, 0)), anchor: .center)
                }
                // 提速(v0.6.1):当前页起向后再预取一批,滑动时不空窗
                loader.prefetch(from: max(current - 4, 0), ahead: 24)
            }
        }
    }

    private func thumbCell(_ index: Int) -> some View {
        Button {
            onJump(index)
            dismiss()
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.secondarySystemBackground))
                    if let image = loader.images[index] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .frame(height: 124)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(index == current ? Color.accentColor : Color.clear, lineWidth: 2.5)
                )
                Text("\(index + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(index == current ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .task(id: index) {
            loader.request(index)
        }
    }

    private func jumpFromInput() {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard let n = Int(trimmed) else {
            hint = "请输入数字页码"
            return
        }
        guard n >= 1, n <= pageCount else {
            hint = "页码超出范围,请输入 1 – \(pageCount)"
            return
        }
        onJump(n - 1)
        dismiss()
    }
}
