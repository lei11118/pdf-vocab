import SwiftUI
import UniformTypeIdentifiers

/// 文档库:导入 PDF、查看列表、进入阅读。
struct LibraryView: View {
    let store: DocumentStore

    @State private var documents: [DocumentRecord] = []
    @State private var showImporter = false
    @State private var importingLabel: String?
    @State private var errorMessage: String?
    @State private var pendingDelete: DocumentRecord?

    var body: some View {
        NavigationStack {
            Group {
                if documents.isEmpty {
                    emptyState
                } else {
                    documentList
                }
            }
            .navigationTitle("读词")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入 PDF", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: DocumentRecord.self) { doc in
                ReaderView(doc: doc, store: store)
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true,
                onCompletion: handleImportResult
            )
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
            .onOpenURL { url in
                guard url.isFileURL else { return }
                startImport([url])
            }
            .task { reload() }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有文档", systemImage: "text.book.closed")
        } description: {
            Text("导入英文 PDF,长按单词开始学习。")
        } actions: {
            Button("导入 PDF") { showImporter = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var documentList: some View {
        List {
            ForEach(documents) { doc in
                NavigationLink(value: doc) {
                    DocumentRow(doc: doc)
                }
                .contextMenu {
                    Button("删除", role: .destructive) { pendingDelete = doc }
                }
            }
        }
        .listStyle(.insetGrouped)
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
    }

    private func delete(_ doc: DocumentRecord) {
        try? store.delete(doc)
        reload()
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            startImport(urls)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func startImport(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importingLabel = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 个文件"

        Task { @MainActor in
            var failures: [String] = []
            for url in urls {
                do {
                    _ = try await Task.detached(priority: .userInitiated) {
                        try store.importFile(from: url)
                    }.value
                    // 清理"用读词打开"产生的 Inbox 临时拷贝
                    if url.path.contains("/Inbox/") {
                        try? FileManager.default.removeItem(at: url)
                    }
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
            VStack(spacing: 12) {
                ProgressView()
                Text("正在导入 \(label)…")
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct DocumentRow: View {
    let doc: DocumentRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = ["\(doc.pageCount) 页"]
        parts.append(doc.hasTextLayer ? "文字版" : "扫描版 · OCR 后续支持")
        if doc.lastPage > 0 {
            parts.append("读到第 \(min(doc.lastPage + 1, doc.pageCount)) 页")
        }
        return parts.joined(separator: " · ")
    }
}
