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
    @AppStorage("pencilAutoReturnEraser") private var pencilAutoReturnEraser = true
    /// v0.11.0(M4-B):悬停预览(迷你释义气泡)
    @State private var hoverTerm: String?
    @State private var hoverPoint: CGPoint = .zero
    @State private var hoverDetail: String?
    @State private var hoverTask: Task<Void, Never>?
    /// v0.11.0(M6):扫描版 OCR 进度
    @State private var ocrRunning = false
    @State private var ocrDone = 0
    @State private var ocrTotal = 0
    /// v0.12.0(M7):夜间模式 / 目录书签 / 全文搜索 / 词频分析 / 批注版导出
    @AppStorage("readerNightMode") private var nightMode = false
    @State private var showOutline = false
    @State private var showSearch = false
    @State private var showAnalyze = false
    @State private var exportProgress: String?
    @State private var exportFailed = false
    @State private var shareFile: ShareFileItem?
    @Environment(\.scenePhase) private var scenePhase
    /// 生词本"一键抵达"目标(v0.8.0;来自主页生词本=预览模式,会话内不记忆阅读位置)
    let jumpTarget: VocabJumpTarget?

    /// v0.14.0:手写工具会话(浮动工具带)
    @StateObject private var pencilTools = PencilToolSession()
    /// v0.15.0:挤压弧形工具盘锚点(nil = 收起)
    @State private var arcAnchor: CGPoint?
    /// v0.23.0:页面缩略图 / 双页显示 / 清空本页手写
    @State private var showThumbnails = false
    @State private var confirmClearInk = false
    /// v0.23.2:页面排布(纵向连续 / 横向连续 / 双页并排)
    @AppStorage("readerLayoutMode") private var layoutMode = "vertical"
    /// v0.16.0:Notability 式专注模式 —— 只留纸面与退出按钮,隐藏顶栏与阅读动作条。
    @State private var focusMode = false
    @Environment(\.dismiss) private var dismiss

    init(doc: DocumentRecord, store: DocumentStore, jumpTarget: VocabJumpTarget? = nil) {
        self.doc = doc
        self.store = store
        self.jumpTarget = jumpTarget
        _currentPage = State(initialValue: jumpTarget?.page ?? doc.lastPage)
        _suppressSave = State(initialValue: jumpTarget != nil)
    }

    var body: some View {
        lifecycleContent
    }

    // v0.16.0:把原来 20+ 个修饰符的一条长链拆成几段(CI 实测 body 单表达式
    // 会让 Swift 类型检查超时 —— "unable to type-check this expression in reasonable time")。
    private var lifecycleContent: some View {
        pencilSyncContent
            .onChange(of: pencilAutoReturnEraser) { _, value in
                pencilTools.autoReturnFromEraser = value
            }
            .onAppear {
                pencilTools.attachDocument(doc.sha256)
                pencilTools.autoReturnFromEraser = pencilAutoReturnEraser
            }
    }

    private var pencilSyncContent: some View {
        sceneContent
            .onChange(of: pencilTools.kind) { _, _ in applyPencilTool() }
            .onChange(of: pencilTools.colorIndex) { _, _ in applyPencilTool() }
            .onChange(of: pencilTools.markerColorIndex) { _, _ in applyPencilTool() }
            .onChange(of: pencilTools.widthIndex) { _, _ in applyPencilTool() }
            .onChange(of: pencilTools.eraserWhole) { _, _ in applyPencilTool() }
            .onChange(of: pencilTools.eraserSizeIndex) { _, _ in applyPencilTool() }
            .onChange(of: pencilTools.useCustomEraser) { _, _ in applyPencilTool() }
            .onChange(of: pencilTools.rulerActive) { _, _ in applyPencilTool() }
    }

    private var sceneContent: some View {
        sheetContent
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    saveProgressNow()
                }
            }
            .onDisappear {
                // v0.23.0:回主页即退出书写 —— 再进任何书都从「选词阅读」开始
                markMode = false
                arcAnchor = nil
                // v0.23.2:退出「选中的工具」(只退回工具类,墨迹笔按书保留)
                if [PencilToolKind.eraser, .lasso, .shape, .laser].contains(pencilTools.kind) {
                    pencilTools.kind = .pen
                }
                readerHandle.coordinator?.setMarkMode(false)
                DiagLog.log("reader: disappear -> markMode=false tool=\(pencilTools.kind.rawValue)")
                saveProgressNow()
            }
    }

    private var sheetContent: some View {
        primarySheetContent
            .sheet(isPresented: $showAnalyze) {
                if let resolvedURL {
                    VocabAnalyzeSheet(
                        url: resolvedURL,
                        docSha: doc.sha256,
                        store: VocabStore(db: store.db)
                    )
                }
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
            .alert("导出失败", isPresented: $exportFailed) {
                Button("好", role: .cancel) {}
            } message: {
                Text("生成批注版 PDF 时出错,请重试。")
            }
            .sheet(item: $shareFile) { item in
                ActivityShareView(items: [item.url])
            }
            .sheet(isPresented: $showThumbnails) {
                if let doc = readerHandle.coordinator?.document {
                    PageThumbnailSheet(document: doc, currentPage: currentPage) { target in
                        readerHandle.coordinator?.go(toPage: target)
                        currentPage = target
                    }
                }
            }
            .alert("清空本页手写?", isPresented: $confirmClearInk) {
                Button("清空", role: .destructive) { readerHandle.coordinator?.clearCurrentPageInk() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只清除当前页的笔迹,不影响其他页;清空后可用撤销恢复。")
            }
            .onChange(of: layoutMode) { _, mode in
                readerHandle.coordinator?.setLayoutMode(mode)
            }
    }

    private var primarySheetContent: some View {
        chromeContent
            .sheet(isPresented: $showSettings) {
                SettingsView(db: store.db)
            }
            .sheet(isPresented: $showVocab) {
                VocabListView(store: VocabStore(db: store.db), scopeDocSha: doc.sha256, onJump: { target in
                    showVocab = false
                    readerHandle.coordinator?.jumpToVocab(target: target)
                }, docStore: store)
            }
            .sheet(isPresented: $showOutline) {
                if let resolvedURL {
                    ReaderOutlineSheet(
                        url: resolvedURL,
                        docSha: doc.sha256,
                        docTitle: doc.title,
                        currentPage: currentPage,
                        bookmarkStore: BookmarkStore(db: store.db),
                        onJump: { page in
                            readerHandle.coordinator?.go(toPage: page)
                            currentPage = page
                        }
                    )
                }
            }
            .sheet(isPresented: $showSearch) {
                if let resolvedURL {
                    ReaderSearchSheet(
                        url: resolvedURL,
                        docSha: doc.sha256,
                        docTitle: doc.title,
                        ocrStore: OCRStore(db: store.db),
                        onJump: { target in
                            readerHandle.coordinator?.jumpToVocab(target: target)
                        }
                    )
                }
            }
    }

    private var chromeContent: some View {
        rootContent
            .overlay(alignment: .top) {
                readerTopOverlay
            }
            .overlay(alignment: .bottom) {
                readerBottomDock
            }
            .animation(.easeInOut(duration: DS.Motion.base), value: focusMode)
            .animation(DS.Motion.spring, value: markMode)
    }

    private var rootContent: some View {
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
        .background(DS.paperWhite.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - v0.16.0 Reader Chrome

    @ViewBuilder
    private var readerTopOverlay: some View {
        if focusMode {
            HStack {
                Spacer()
                Button {
                    focusMode = false
                } label: {
                    Label("退出专注", systemImage: "rectangle.expand.vertical")
                        .font(DS.Fonts.caption2)
                        .foregroundStyle(DS.foreground2)
                        .padding(.horizontal, DS.Space.s)
                        .frame(height: 34)
                        .dsFloatingPanel(radius: DS.Radius.pill)
                }
                .buttonStyle(DSPressableButtonStyle())
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.top, DS.Space.xs)
        } else {
            HStack(spacing: DS.Space.x2s) {
                DSIconButton(
                    systemImage: "chevron.left",
                    iconSize: 16,
                    accessibility: "返回文档库"
                ) {
                    dismiss()
                }

                Button {
                    showPageJump = true
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(doc.title)
                            .font(DS.Fonts.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(DS.foreground1)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text("第 \(min(currentPage + 1, doc.pageCount)) / \(doc.pageCount) 页")
                                .font(DS.Fonts.micro.monospacedDigit())
                            Text("· 点按跳转")
                                .font(DS.Fonts.micro)
                        }
                        .foregroundStyle(DS.foreground3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DSPressableButtonStyle())
                .accessibilityLabel("第 \(min(currentPage + 1, doc.pageCount)) 页,点按跳转")

                DSIconButton(
                    systemImage: "rectangle.compress.vertical",
                    iconSize: 15,
                    accessibility: "进入专注模式"
                ) {
                    focusMode = true
                }

                Menu {
                    Toggle(isOn: $nightMode) {
                        Label("夜间模式", systemImage: "moon.fill")
                    }
                    Menu {
                        Button("适应宽度") { readerHandle.coordinator?.zoomToFitWidth() }
                        Button("100%") { readerHandle.coordinator?.zoomToPercent(100) }
                        Button("200%") { readerHandle.coordinator?.zoomToPercent(200) }
                        Button("400%") { readerHandle.coordinator?.zoomToPercent(400) }
                        Button("800%") { readerHandle.coordinator?.zoomToPercent(800) }
                        Button("1500%") { readerHandle.coordinator?.zoomToPercent(1500) }
                        Button("2000%") { readerHandle.coordinator?.zoomToPercent(2000) }
                        Button("4000%") { readerHandle.coordinator?.zoomToPercent(4000) }
                    } label: {
                        Label("缩放", systemImage: "magnifyingglass.circle")
                    }
                    Menu {
                        Button {
                            layoutMode = "vertical"
                        } label: {
                            Label("纵向连续", systemImage: layoutMode == "vertical" ? "checkmark" : "rectangle.portrait")
                        }
                        Button {
                            layoutMode = "horizontal"
                        } label: {
                            Label("横向连续", systemImage: layoutMode == "horizontal" ? "checkmark" : "rectangle")
                        }
                        Button {
                            layoutMode = "twoUp"
                        } label: {
                            Label("双页并排", systemImage: layoutMode == "twoUp" ? "checkmark" : "book.pages")
                        }
                    } label: {
                        Label("页面排布", systemImage: "rectangle.split.2x1")
                    }
                    Button {
                        showThumbnails = true
                    } label: {
                        Label("页面缩略图", systemImage: "square.grid.3x2")
                    }
                    Button(role: .destructive) {
                        confirmClearInk = true
                    } label: {
                        Label("清空本页手写", systemImage: "eraser.line.dashed")
                    }
                    Button {
                        showVocab = true
                    } label: {
                        Label("生词本", systemImage: "text.book.closed")
                    }
                    Button {
                        showSearch = true
                    } label: {
                        Label("全文搜索", systemImage: "magnifyingglass")
                    }
                    Button {
                        showOutline = true
                    } label: {
                        Label("目录与书签", systemImage: "list.bullet.indent")
                    }
                    Button {
                        showAnalyze = true
                    } label: {
                        Label("词频分析 · 批量收录", systemImage: "chart.bar.doc.horizontal")
                    }
                    Divider()
                    Button {
                        showSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                    Button {
                        exportAnnotatedPDF()
                    } label: {
                        Label("导出批注版 PDF", systemImage: "square.and.arrow.up.on.square")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DS.foreground2)
                        .frame(width: 38, height: 38)
                        .background(DS.background1, in: Circle())
                        .overlay(Circle().strokeBorder(DS.foreground1.opacity(0.07), lineWidth: 0.8))
                }
                .accessibilityLabel("更多")
            }
            .frame(maxWidth: 900)
            .padding(5)
            .dsFloatingPanel(radius: DS.Radius.pill)
            .padding(.horizontal, DS.Space.m)
            .padding(.top, DS.Space.xs)
        }
    }

    @ViewBuilder
    private var readerBottomDock: some View {
        if markMode {
            PencilPaletteView(
                session: pencilTools,
                onUndo: { readerHandle.coordinator?.undoInk() },
                onRedo: { readerHandle.coordinator?.redoInk() },
                onExitWriting: { markMode = false }
            )
            .padding(.horizontal, DS.Space.m)
            .padding(.bottom, DS.Space.s)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if !focusMode {
            HStack(spacing: 3) {
                readingModeSegment(
                    title: "选词",
                    systemImage: "text.cursor",
                    active: true
                ) {}
                readingModeSegment(
                    title: "手写",
                    systemImage: "pencil.tip",
                    active: false
                ) {
                    markMode = true
                }
            }
            .padding(4)
            .dsFloatingPanel(radius: DS.Radius.pill)
            .padding(.bottom, DS.Space.m)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func readingModeSegment(
        title: String,
        systemImage: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(DS.Fonts.caption2)
            }
            .foregroundStyle(active ? DS.accent : DS.foreground3)
            .padding(.horizontal, DS.Space.s)
            .frame(height: 36)
            .background(active ? DS.accentContainer : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(DSPressableButtonStyle())
        .accessibilityAddTraits(active ? .isSelected : AccessibilityTraits())
    }

    /// v0.14.0:把当前笔具同步给预览画布的协调器
    private func applyPencilTool() {
        readerHandle.coordinator?.applyToolSession()
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
            },
            excludedSenses: { key in vs.excludedSenseIndices(forLemma: key) },
            setSense: { key, idx, keep in vs.setSenseSelection(forLemma: key, idx: idx, keep: keep) }
        )
    }

    private func reader(for url: URL) -> some View {
        pdfArea
            .overlay {
                // v0.12.0(M7):夜间模式(降低纸张亮度;不改动页面内容)
                if nightMode {
                    Color.black.opacity(0.52)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: nightMode)
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
                            vocab: cardVocab,
                            onTranslate: { text in
                                translateText = text
                                showTranslate = true
                            }
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
            .overlay {
                // v0.15.0:挤压 → 围绕笔尖的弧形工具盘(撤销 / 钢笔 / 铅笔 / 荧光笔 / 橡皮)
                GeometryReader { geo in
                    if let arcAnchor {
                        PencilArcMenu(
                            session: pencilTools,
                            anchor: arcAnchor,
                            bounds: geo.size,
                            onDismiss: { self.arcAnchor = nil }
                        )
                    }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.88), value: markMode)
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

    /// v0.12.0(M7):导出批注版 PDF(高亮 + 手写烧录;后台生成 → 分享面板)
    private func exportAnnotatedPDF() {
        guard let url = resolvedURL else { return }
        let sha = doc.sha256
        let db = store.db
        exportProgress = "生成批注版 PDF…"
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> URL? in
                try? AnnotatedPDFExporter.export(
                    url: url,
                    docSha: sha,
                    vocab: VocabStore(db: db),
                    ink: PencilInkStore(db: db)
                )
            }.value
            exportProgress = nil
            if let result {
                shareFile = ShareFileItem(url: result)
            } else {
                exportFailed = true
            }
        }
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
                    toolSession: pencilTools,
                    onPencilSqueeze: { point in
                        // v0.19.0:挤压 = 开关工具栏 —— 第一次打开弧形工具盘,再挤一次收起
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            if arcAnchor == nil {
                                arcAnchor = point
                            } else {
                                arcAnchor = nil
                            }
                        }
                    },
                    onFocusToggle: {
                        withAnimation(.easeInOut(duration: DS.Motion.base)) { focusMode.toggle() }
                    },
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
            VStack(spacing: 6) {
                // v0.11.0(M6):扫描版 OCR 进度
                if ocrRunning {
                    Text("扫描版文字识别中… \(ocrDone)/\(ocrTotal)")
                        .font(.caption2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .allowsHitTesting(false)
                }
                // v0.12.0(M7):批注版导出进度
                if let exportProgress {
                    Text(exportProgress)
                        .font(.caption2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .allowsHitTesting(false)
                }
            }
            .padding(.top, 8)
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
