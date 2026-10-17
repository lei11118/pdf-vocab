import SwiftUI
import Combine

/// 文档库:导入 PDF、查看列表、进入阅读。
/// 导入方式:文件选择器(UIKit 文档选择器,asCopy 模式,绕开 iOS 26 fileImporter 问题)。
struct LibraryView: View {
    let store: DocumentStore

    @State private var documents: [DocumentRecord] = []
    @State private var showImporter = false
    @State private var importingLabel: String?
    @State private var errorMessage: String?
    @State private var pendingDelete: DocumentRecord?
    @State private var showDiagnostics = false
    @State private var showSettings = false
    @State private var showVocab = false
    @State private var readerJump: VocabJumpTarget?
    @State private var query = ""
    @State private var vocabCount = 0

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                DS.background1.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        libraryHeader

                        if !documents.isEmpty {
                            searchField
                        }

                        if documents.isEmpty {
                            emptyState
                                .padding(.top, DS.Space.xxl)
                        } else if filteredDocuments.isEmpty {
                            noSearchResults
                                .padding(.top, DS.Space.xxl)
                        } else {
                            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               let recent = resumeDocument {
                                resumeCard(recent)
                            }
                            libraryGrid
                        }
                    }
                    .padding(.horizontal, DS.Layout.pageMargin)
                    .padding(.top, DS.Space.xs)
                    .padding(.bottom, 124)
                }
                .scrollIndicators(.hidden)

                bottomDock
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: DocumentRecord.self) { doc in
                ReaderView(doc: doc, store: store)
            }
            .navigationDestination(item: $readerJump) { target in
                if let rec = try? store.document(sha256: target.docSha) {
                    ReaderView(doc: rec, store: store, jumpTarget: target)
                } else {
                    ContentUnavailableView(
                        "文档缺失",
                        systemImage: "doc.questionmark",
                        description: Text("该生词出处的 PDF 已被删除。")
                    )
                }
            }
            .sheet(isPresented: $showImporter) {
                PDFDocumentPicker(
                    onPick: { urls in
                        showImporter = false
                        importURLs(urls)
                    },
                    onCancel: {
                        showImporter = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(db: store.db)
            }
            .sheet(isPresented: $showVocab) {
                VocabListView(store: VocabStore(db: store.db), onJump: { target in
                    showVocab = false
                    // 等生词本面板收起后再推入阅读页(避免转场打架)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        readerJump = target
                    }
                }, docStore: store)
            }
            .overlay {
                if let importingLabel {
                    importingOverlay(importingLabel)
                }
            }
            .alert("导入失败", isPresented: errorAlertBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog(
                "要删除「\(pendingDelete?.title ?? "")」吗?",
                isPresented: deleteDialogBinding,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let doc = pendingDelete { delete(doc) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("同时删除本地副本与阅读进度,且不可撤销。")
            }
            .task { reload() }
            .onReceive(NotificationCenter.default.publisher(for: .yuewenDataDidRestore)) { _ in
                // v0.12.0(M7):备份恢复完成后刷新文档列表
                reload()
            }
            .onAppear { reload() }
        }
    }

    // MARK: - v0.16.0 Library Home

    private var libraryHeader: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                    Text("跃文")
                        .font(DS.Fonts.display3)
                        .foregroundStyle(DS.foreground1)
                    Text("READ · NOTE")
                        .font(DS.Fonts.micro)
                        .tracking(1.4)
                        .foregroundStyle(DS.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(DS.accentContainer, in: Capsule())
                }
                Text("把英文读成自己的")
                    .font(DS.Fonts.subhead)
                    .foregroundStyle(DS.foreground3)
            }

            Spacer(minLength: DS.Space.s)

            HStack(spacing: DS.Space.x2s) {
                Text(Date.now, format: .dateTime.month(.abbreviated).day())
                    .font(DS.Fonts.caption2)
                    .foregroundStyle(DS.foreground3)
                    .lineLimit(1)

                Menu {
                    Button {
                        showSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                    Button {
                        showDiagnostics = true
                    } label: {
                        Label("诊断日志", systemImage: "stethoscope")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(DS.foreground2)
                        .frame(width: 40, height: 40)
                        .background(DS.background2, in: Circle())
                        .overlay(Circle().strokeBorder(DS.foreground1.opacity(0.07), lineWidth: 0.8))
                }
                .accessibilityLabel("更多设置")
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.foreground3)
            TextField("搜索书名", text: $query)
                .font(DS.Fonts.subhead)
                .foregroundStyle(DS.foreground1)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.foreground4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: 46)
        .background(DS.background2, in: Capsule())
        .overlay(Capsule().strokeBorder(DS.foreground1.opacity(0.07), lineWidth: 0.8))
    }

    private var libraryGrid: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            DSSectionHeader(
                title: query.isEmpty ? "书架" : "搜索结果",
                subtitle: query.isEmpty
                    ? "\(filteredDocuments.count) 本 · 最近导入优先"
                    : "\(filteredDocuments.count) 本匹配"
            )

            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: DS.Layout.libraryGridMin, maximum: 220),
                        spacing: DS.Layout.cardGap,
                        alignment: .top
                    )
                ],
                alignment: .leading,
                spacing: DS.Space.l
            ) {
                ForEach(filteredDocuments) { doc in
                    NavigationLink(value: doc) {
                        LibraryCoverCell(
                            doc: doc,
                            url: try? store.pdfURL(for: doc)
                        )
                    }
                    .buttonStyle(DSPressableButtonStyle())
                    .contextMenu {
                        Button("删除", role: .destructive) { pendingDelete = doc }
                    }
                }
            }
        }
    }

    private func resumeCard(_ doc: DocumentRecord) -> some View {
        NavigationLink(value: doc) {
            HStack(spacing: DS.Space.l) {
                DocumentCoverThumbnail(doc: doc, url: try? store.pdfURL(for: doc))
                    .frame(width: 104)

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(doc.lastPage > 0 ? "继续阅读" : "从这本开始")
                        .font(DS.Fonts.caption2)
                        .tracking(0.8)
                        .foregroundStyle(DS.accent)

                    Text(doc.title)
                        .font(DS.Fonts.title2)
                        .foregroundStyle(DS.foreground1)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    DocumentMetaLine(doc: doc)

                    Spacer(minLength: DS.Space.xs)

                    HStack(spacing: DS.Space.xs) {
                        if doc.lastPage > 0 {
                            ProgressView(
                                value: Double(min(doc.lastPage + 1, doc.pageCount)),
                                total: Double(max(doc.pageCount, 1))
                            )
                            .tint(DS.accent)
                            .frame(maxWidth: 120)
                        }
                        Text(doc.lastPage > 0 ? "第 \(min(doc.lastPage + 1, doc.pageCount)) 页" : "打开文档")
                            .font(DS.Fonts.caption2)
                            .foregroundStyle(DS.foreground3)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DS.accent)
                    .frame(width: 40, height: 40)
                    .background(DS.accentContainer, in: Circle())
            }
            .padding(DS.Space.m)
            .background(DS.background2, in: RoundedRectangle(cornerRadius: DS.Radius.comfy, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.comfy, style: .continuous)
                    .strokeBorder(DS.foreground1.opacity(0.07), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSPressableButtonStyle())
    }

    private var bottomDock: some View {
        HStack(spacing: DS.Space.x3s) {
            Button {
                showVocab = true
            } label: {
                HStack(spacing: DS.Space.x2s) {
                    Image(systemName: "text.book.closed.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("生词本")
                        .font(DS.Fonts.caption2)
                    if vocabCount > 0 {
                        Text("\(vocabCount)")
                            .font(DS.Fonts.micro.monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DS.accentContainer, in: Capsule())
                            .foregroundStyle(DS.accent)
                    }
                }
                .foregroundStyle(DS.foreground2)
                .padding(.horizontal, DS.Space.s)
                .frame(height: 42)
                .contentShape(Capsule())
            }
            .buttonStyle(DSPressableButtonStyle())

            Rectangle()
                .fill(DS.foreground1.opacity(0.09))
                .frame(width: 1, height: 22)

            Button {
                showImporter = true
            } label: {
                HStack(spacing: DS.Space.x2s) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                    Text("导入 PDF")
                        .font(DS.Fonts.caption2)
                }
                .foregroundStyle(DS.onAccent)
                .padding(.horizontal, DS.Space.m)
                .frame(height: 42)
                .background(DS.accent, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(DSPressableButtonStyle())
        }
        .padding(5)
        .dsFloatingPanel(radius: DS.Radius.pill)
        .padding(.bottom, DS.Space.m)
    }

    private var noSearchResults: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(DS.foreground3)
            Text("没有找到「\(query)」")
                .font(DS.Fonts.headline)
                .foregroundStyle(DS.foreground1)
            Text("试试只输入书名里的一个词")
                .font(DS.Fonts.subhead)
                .foregroundStyle(DS.foreground3)
        }
        .frame(maxWidth: .infinity)
    }

    private var filteredDocuments: [DocumentRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return documents }
        return documents.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    private var resumeDocument: DocumentRecord? {
        documents.first(where: { $0.lastPage > 0 }) ?? documents.first
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.l) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                    .fill(DS.coverBlueLight)
                    .frame(width: 132, height: 168)
                    .rotationEffect(.degrees(-7))
                    .offset(x: -12, y: 5)
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 6)

                RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                    .fill(DS.coverCream)
                    .frame(width: 132, height: 168)
                    .rotationEffect(.degrees(4))
                    .offset(x: 10, y: -2)
                    .shadow(color: .black.opacity(0.10), radius: 14, y: 7)

                VStack(spacing: DS.Space.s) {
                    Image(systemName: "text.book.closed.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(DS.accent)
                    Text("PDF")
                        .font(DS.Fonts.micro)
                        .tracking(2)
                        .foregroundStyle(DS.foreground3)
                }
                .frame(width: 132, height: 168)
                .background(DS.background2, in: RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                        .strokeBorder(.white.opacity(0.7), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
            }
            .frame(height: 190)

            VStack(spacing: DS.Space.x3s) {
                Text("把第一份 PDF 放上书架")
                    .font(DS.Fonts.title2)
                    .foregroundStyle(DS.foreground1)
                Text("选中单词查词,按住 Pencil 随手批注。\n所有内容只留在这台 iPad 上。")
                    .font(DS.Fonts.subhead)
                    .foregroundStyle(DS.foreground3)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Button {
                showImporter = true
            } label: {
                Label("导入 PDF", systemImage: "plus")
            }
            .buttonStyle(DSPillButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bindings

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    // MARK: - 动作

    private func reload() {
        documents = (try? store.allDocuments()) ?? []
        vocabCount = VocabStore(db: store.db).listWords().count
    }

    private func delete(_ doc: DocumentRecord) {
        try? store.delete(doc)
        reload()
    }

    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let store = self.store
        importingLabel = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 个文件"

        Task { @MainActor in
            var failures: [String] = []
            for url in urls {
                do {
                    _ = try await Task.detached(priority: .userInitiated) {
                        try store.importFile(from: url)
                    }.value
                    // 清理选择器交付的临时副本(tmp)
                    try? FileManager.default.removeItem(at: url)
                } catch {
                    failures.append("\(url.lastPathComponent):\(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                errorMessage = failures.joined(separator: "\n")
            }
            importingLabel = nil
            reload()
        }
    }

    private func importingOverlay(_ label: String) -> some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            VStack(spacing: DS.Space.s) {
                ProgressView()
                    .tint(DS.accent)
                Text("正在导入 \(label)…")
                    .font(DS.Fonts.subhead)
                    .foregroundStyle(DS.foreground2)
            }
            .padding(DS.Space.l)
            .dsFloatingPanel(radius: DS.Radius.comfy)
        }
    }
}

private struct LibraryCoverCell: View {
    let doc: DocumentRecord
    let url: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            DocumentCoverThumbnail(doc: doc, url: url)
                .overlay(alignment: .topTrailing) {
                    if doc.lastPage > 0 {
                        Text("\(min(doc.lastPage + 1, doc.pageCount)) / \(doc.pageCount)")
                            .font(DS.Fonts.micro.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.34), in: Capsule())
                            .padding(DS.Space.xs)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(doc.title)
                    .font(DS.Fonts.headline)
                    .foregroundStyle(DS.foreground1)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: 42, alignment: .topLeading)

                DocumentMetaLine(doc: doc)
            }
        }
        .contentShape(Rectangle())
    }
}
