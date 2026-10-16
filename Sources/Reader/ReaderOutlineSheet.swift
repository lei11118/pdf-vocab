import SwiftUI
import PDFKit

/// 目录 + 书签(v0.12.0,M7):PDF 内置目录(PDFOutline)全量展开 + 本机书签增删跳转。
struct ReaderOutlineSheet: View {
    let url: URL
    let docSha: String
    let docTitle: String
    let currentPage: Int
    let bookmarkStore: BookmarkStore
    var onJump: (Int) -> Void = { _ in }

    struct OutlineItem: Identifiable {
        let id = UUID()
        let title: String
        let page: Int?
        let depth: Int
    }

    @Environment(\.dismiss) private var dismiss
    @State private var outline: [OutlineItem] = []
    @State private var bookmarks: [BookmarkRow] = []
    @State private var loadingOutline = true

    private var currentHasBookmark: Bool {
        bookmarks.contains { $0.page == currentPage }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        if currentHasBookmark {
                            bookmarkStore.remove(docSha: docSha, page: currentPage)
                        } else {
                            bookmarkStore.add(docSha: docSha, page: currentPage)
                        }
                        bookmarks = bookmarkStore.list(docSha: docSha)
                    } label: {
                        Label(
                            currentHasBookmark ? "移除本页书签(第 \(currentPage + 1) 页)" : "为第 \(currentPage + 1) 页添加书签",
                            systemImage: currentHasBookmark ? "bookmark.slash" : "bookmark"
                        )
                    }
                    ForEach(bookmarks) { bm in
                        Button {
                            onJump(bm.page)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "bookmark.fill")
                                    .font(.footnote)
                                    .foregroundStyle(Color.accentColor)
                                Text(bm.label.isEmpty ? "第 \(bm.page + 1) 页" : bm.label)
                                Spacer()
                                Text("第 \(bm.page + 1) 页")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                bookmarkStore.remove(docSha: docSha, page: bm.page)
                                bookmarks = bookmarkStore.list(docSha: docSha)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("书签")
                }
                Section {
                    if loadingOutline {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("读取目录…")
                                .foregroundStyle(.secondary)
                        }
                    } else if outline.isEmpty {
                        Text("该 PDF 没有内置目录(PDF 书签)")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(outline) { item in
                        Button {
                            if let page = item.page {
                                onJump(page)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Text(item.title)
                                    .lineLimit(1)
                                    .padding(.leading, CGFloat(item.depth) * 14)
                                Spacer()
                                if let page = item.page {
                                    Text("\(page + 1)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("目录")
                }
            }
            .navigationTitle(docTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                bookmarks = bookmarkStore.list(docSha: docSha)
                outline = await Self.loadOutline(url: url)
                loadingOutline = false
            }
        }
    }

    /// 后台线程读取 PDF 目录(压平成缩进列表;上限 2000 条防异常大纲)。
    private static func loadOutline(url: URL) async -> [OutlineItem] {
        await Task.detached(priority: .userInitiated) { () -> [OutlineItem] in
            guard let doc = PDFDocument(url: url), let root = doc.outlineRoot else { return [] }
            var items: [OutlineItem] = []
            func walk(_ node: PDFOutline, depth: Int) {
                for i in 0..<node.numberOfChildren {
                    guard let child = node.child(at: i), items.count < 2_000 else { continue }
                    let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    var page: Int?
                    if let destPage = child.destination?.page {
                        page = doc.index(for: destPage)
                    } else if let goTo = child.action as? PDFActionGoTo {
                        page = doc.index(for: goTo.destination.page)
                    }
                    if !title.isEmpty {
                        items.append(OutlineItem(title: title, page: page, depth: depth))
                    }
                    if child.numberOfChildren > 0 {
                        walk(child, depth: depth + 1)
                    }
                }
            }
            walk(root, depth: 0)
            return items
        }.value
    }
}
