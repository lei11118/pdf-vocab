import SwiftUI
import PDFKit

/// 全文搜索(v0.12.0,M7):文字层走 PDFKit findString(逐条附带高亮矩形);
/// 扫描版(或文字层无匹配)回退 OCR 词库按行搜索。点结果跳页 + 橙色临时高亮。
struct ReaderSearchSheet: View {
    let url: URL
    let docSha: String
    let docTitle: String
    let ocrStore: OCRStore
    var onJump: (VocabJumpTarget) -> Void = { _ in }

    struct SearchHit: Identifiable {
        let id = UUID()
        let page: Int
        let snippet: String
        let rectsJSON: String
    }

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @State private var note: String?

    var body: some View {
        NavigationStack {
            List {
                if searching {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("搜索中…")
                            .foregroundStyle(.secondary)
                    }
                }
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(hits) { hit in
                    Button {
                        onJump(VocabJumpTarget(
                            docSha: docSha,
                            docTitle: docTitle,
                            page: hit.page,
                            term: query,
                            rectsJSON: hit.rectsJSON
                        ))
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.snippet)
                                .font(.callout)
                                .lineLimit(2)
                            Text("第 \(hit.page + 1) 页")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("全文搜索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "在文档中搜索")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
                hits = []
                note = nil
                guard q.count >= 2 else { return }
                // 450ms 防抖
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                searching = true
                await performSearch(q)
            }
        }
    }

    private func performSearch(_ q: String) async {
        let url = self.url
        let docSha = self.docSha
        let ocrStore = self.ocrStore
        let (found, noteText) = await Task.detached(priority: .userInitiated) { () -> ([SearchHit], String?) in
            var out: [SearchHit] = []
            var noteText: String?
            var seen = Set<String>()
            guard let doc = PDFDocument(url: url) else { return ([], "无法打开文档") }

            // v0.23.2:文字层不再截断前 200 条 —— 整本全部命中都列出来
            let matches = doc.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
            for selection in matches {
                guard let page = selection.pages.first else { continue }
                let idx = doc.index(for: page)
                let snippet = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let rects = selection.selectionsByLine().prefix(8).map { $0.bounds(for: page) }
                let json = VocabStore.rectsToJSON(rects)
                let key = "\(idx)|\(json)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                out.append(SearchHit(
                    page: idx,
                    snippet: snippet.isEmpty ? q : String(snippet.prefix(96)),
                    rectsJSON: json
                ))
            }

            // v0.23.2:OCR 结果**始终合并**(扫描版,或文字层只覆盖部分页的书)
            let lines = ocrStore.searchLines(docSha: docSha, query: q, limit: 500)
            for hit in lines {
                let snippet = hit.words.map { $0.text }.joined(separator: " ")
                guard let pageBounds = doc.page(at: hit.page)?.bounds(for: .mediaBox) else { continue }
                let rects = hit.words.map { OCRService.pageRect(from: $0, pageBounds: pageBounds) }
                let json = VocabStore.rectsToJSON(rects)
                let key = "\(hit.page)|\(json)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                out.append(SearchHit(
                    page: hit.page,
                    snippet: String(snippet.prefix(96)),
                    rectsJSON: json
                ))
            }

            out.sort { $0.page < $1.page }
            if !out.isEmpty, !ocrStore.isDone(docSha: docSha) {
                noteText = "OCR 还在识别中,扫描页的结果可能不完整"
            }
            if out.isEmpty {
                noteText = "没有找到「\(q)」"
            }
            return (out, noteText)
        }.value
        guard !Task.isCancelled else { return }
        hits = found
        note = noteText
        searching = false
    }
}
