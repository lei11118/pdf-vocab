import SwiftUI
import Translation

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
                }
                .accessibilityLabel("跳转页码")
            }
        }
        .sheet(isPresented: $showPageJump) {
            PageJumpSheet(pageCount: doc.pageCount, current: currentPage) { target in
                readerHandle.coordinator?.go(toPage: target)
                currentPage = min(max(target, 0), doc.pageCount - 1)
            }
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
                    },
                    onReadingTick: {
                        scheduleSave()
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

/// 页码跳转面板:数字输入 + 滑杆 + 越界处理。
private struct PageJumpSheet: View {
    let pageCount: Int
    let onJump: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var sliderValue: Double
    @State private var hint: String?

    init(pageCount: Int, current: Int, onJump: @escaping (Int) -> Void) {
        self.pageCount = pageCount
        self.onJump = onJump
        let current1 = min(max(current + 1, 1), max(pageCount, 1))
        _sliderValue = State(initialValue: Double(current1))
    }

    var body: some View {
        NavigationStack {
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
            .navigationTitle("选页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
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
