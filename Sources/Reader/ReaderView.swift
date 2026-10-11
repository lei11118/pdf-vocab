import SwiftUI

/// 阅读页:PDF 渲染 + 取词 + 临时高亮 + 阅读进度记忆。
struct ReaderView: View {
    let doc: DocumentRecord
    let store: DocumentStore

    @State private var selectionInfo: SelectionInfo?
    @State private var currentPage: Int

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
    }

    private func reader(for url: URL) -> some View {
        PDFKitView(
            url: url,
            initialPage: doc.lastPage,
            onPageChanged: { page in
                currentPage = page
                try? store.setLastPage(page, for: doc.sha256)
            },
            onSelectionInfo: { info in
                selectionInfo = info
            }
        )
        .overlay(alignment: .bottom) {
            if let info = selectionInfo {
                selectionBar(info)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            pageIndicator
        }
    }

    /// 底部信息条:选中内容的临时占位显示(M2 起由侧边词卡接管)。
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

    private var pageIndicator: some View {
        Text("\(min(currentPage + 1, doc.pageCount)) / \(doc.pageCount)")
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .padding(12)
            .allowsHitTesting(false)
    }
}
