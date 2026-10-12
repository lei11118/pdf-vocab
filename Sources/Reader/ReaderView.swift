import SwiftUI
import Translation
import UIKit
import PDFKit

/// 阅读页:PDF 渲染 + 取词 + 选页 + 阅读位置记忆。
struct ReaderView: View {
    let doc: DocumentRecord
    let store: DocumentStore

    @State private var selectionInfo: SelectionInfo?
    @State private var currentPage: Int
    @State private var resolvedURL: URL?
    @State private var optimizing = false
    @State private var translateText = ""
    @State private var showTranslate = false
    @State private var showPageJump = false
    @State private var cardContent: ReaderCardContent?
    @State private var cardPosition: CGPoint?
    @State private var cardDragBase: CGPoint?
    @AppStorage("readerCardX") private var storedCardX: Double = -1
    @AppStorage("readerCardY") private var storedCardY: Double = -1
    private let cardSize = CGSize(width: 320, height: 430)
    @State private var readerHandle = ReaderHandle()
    @State private var saveTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    init(doc: DocumentRecord, store: DocumentStore) {
        self.doc = doc
        self.store = store
        _currentPage = State(initialValue: doc.lastPage)
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

    private func reader(for url: URL) -> some View {
        pdfArea
            .overlay {
                GeometryReader { geo in
                    if let content = cardContent {
                        floatingCard(content, bounds: geo.size)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.18), value: cardContent)
    }

    // MARK: - 悬浮词卡(可拖动、位置持久、点 × 才关闭;v0.6.1 用户要求)

    private func floatingCard(_ content: ReaderCardContent, bounds: CGSize) -> some View {
        VStack(spacing: 0) {
            cardDragStrip(bounds: bounds)
            Divider()
            WordCardPanel(
                content: content,
                onClose: { cardContent = nil },
                onSelectWord: { word in cardContent = .word(word) }
            )
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .offset(x: cardCurrentPosition(bounds: bounds).x, y: cardCurrentPosition(bounds: bounds).y)
        .onAppear {
            if cardPosition == nil {
                cardPosition = cardCurrentPosition(bounds: bounds)
            }
        }
        .onChange(of: bounds) { _, newBounds in
            if let p = cardPosition {
                cardPosition = cardClamp(p, in: newBounds)
            }
        }
    }

    private func cardDragStrip(bounds: CGSize) -> some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let base = cardDragBase ?? cardCurrentPosition(bounds: bounds)
                    if cardDragBase == nil { cardDragBase = base }
                    cardPosition = cardClamp(
                        CGPoint(x: base.x + value.translation.width, y: base.y + value.translation.height),
                        in: bounds
                    )
                }
                .onEnded { _ in
                    cardDragBase = nil
                    if let p = cardPosition {
                        storedCardX = Double(p.x)
                        storedCardY = Double(p.y)
                    }
                }
        )
    }

    private func cardCurrentPosition(bounds: CGSize) -> CGPoint {
        if let cardPosition {
            return cardClamp(cardPosition, in: bounds)
        }
        if storedCardX >= 0, storedCardY >= 0 {
            return cardClamp(CGPoint(x: storedCardX, y: storedCardY), in: bounds)
        }
        return cardClamp(CGPoint(x: bounds.width - cardSize.width - 16, y: 16), in: bounds)
    }

    private func cardClamp(_ point: CGPoint, in bounds: CGSize) -> CGPoint {
        let maxX = max(8, bounds.width - cardSize.width - 8)
        let maxY = max(8, bounds.height - cardSize.height - 8)
        return CGPoint(x: min(max(point.x, 8), maxX), y: min(max(point.y, 8), maxY))
    }

    private var pdfArea: some View {
        Group {
            if let resolvedURL {
                PDFKitView(
                    url: resolvedURL,
                    restore: doc.readingState,
                    handle: readerHandle,
                    onPageChanged: { page in
                        currentPage = page
                        scheduleSave()
                    },
                    onSelectionInfo: { info in
                        selectionInfo = info
                        // v0.6.1:选区变化只更新卡片内容;**选区清空不再自动关卡片**(只有点 × 才关)
                        guard let info, !info.text.isEmpty else { return }
                        if info.wordCount <= 1, !info.primaryTerm.isEmpty {
                            cardContent = .word(info.primaryTerm)
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
            if let info = selectionInfo {
                selectionBar(info)
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
        .translationPresentation(isPresented: $showTranslate, text: translateText)
    }

    /// 底部信息条:选中内容的显示(M2 起由侧边词卡接管)。
    private func selectionBar(_ info: SelectionInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(info.wordCount > 1 ? "已选中 \(info.wordCount) 个词" : "已选中单词")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(info.text)
                .font(.callout)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: 560)
        .allowsHitTesting(false)
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
