import SwiftUI

/// 生词本列表(v0.8.0):
/// - `scopeDocSha == nil` → **全部文档的生词**(主页入口);非 nil → **只显示该文档内的生词**(阅读页入口);
/// - 每行标注**出处**(文档名 · 页码),点出处**一键抵达** + 橙色临时高亮;
/// - 点生词弹**胶囊式预览**(单词+发音+翻译,与迷你词卡同款);
/// - 左滑删除(生词可增删);分组筛选 / 新建 / 重命名 / 删除;搜索。
struct VocabListView: View {
    let store: VocabStore
    var scopeDocSha: String? = nil
    var onJump: ((VocabJumpTarget) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var words: [VocabStore.WordSummary] = []
    @State private var groups: [VocabStore.GroupSummary] = []
    @State private var filterGroupId: Int64?
    @State private var searchText = ""
    @State private var previewWord: String?
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var showRename = false
    @State private var renameText = ""
    @State private var contextWord: VocabStore.WordSummary?
    @State private var isSelecting = false
    @State private var selectedIds: Set<Int64> = []
    @State private var showBatchDeleteConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if words.isEmpty {
                    ContentUnavailableView {
                        Label(scopeDocSha == nil ? "生词本还是空的" : "本文档还没有生词", systemImage: "text.book.closed")
                    } description: {
                        Text("阅读时选中单词,在词卡上点「加入生词本」。")
                    }
                } else {
                    wordList
                }
            }
            .navigationTitle(scopeDocSha == nil ? "生词本" : "生词本(本文档)")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索生词")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    filterMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "取消" : "选择") {
                        isSelecting.toggle()
                        if !isSelecting { selectedIds.removeAll() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("新建分组", isPresented: $showNewGroup) {
                TextField("分组名(如:雅思 / 论文)", text: $newGroupName)
                Button("创建") {
                    if let id = store.createGroup(name: newGroupName) {
                        filterGroupId = id
                        reload()
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("重命名分组", isPresented: $showRename) {
                TextField("新名称", text: $renameText)
                Button("保存") {
                    if let gid = filterGroupId {
                        store.renameGroup(id: gid, name: renameText)
                        reload()
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .overlay(alignment: .bottom) { previewBar }
            .sheet(item: $contextWord) { word in
                contextSheet(word)
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    batchBar
                }
            }
            .confirmationDialog("删除选中的 \(selectedIds.count) 个生词?", isPresented: $showBatchDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) { batchDelete() }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: previewWord)
            .task { reload() }
            .onChange(of: searchText) { _, _ in reload() }
            .onChange(of: filterGroupId) { _, _ in reload() }
        }
    }

    // MARK: - 子视图

    private var wordList: some View {
        List(selection: $selectedIds) {
            ForEach(words) { word in
                row(word)
                    .tag(word.id)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.deleteWord(id: word.id)
                            reload()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
    }

    private func row(_ word: VocabStore.WordSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button {
                    previewWord = (previewWord == word.surface) ? nil : word.surface
                } label: {
                    Text(word.surface)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!isSelecting)
                if word.status == .mastered {
                    Text("已掌握")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                }
                Spacer()
                Button {
                    contextWord = word
                } label: {
                    HStack(spacing: 3) {
                        Text("\(word.occurrenceCount) 处语境")
                            .font(.caption)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(word.occurrenceCount == 0)
                .allowsHitTesting(!isSelecting)
            }
            if let title = word.sourceDocTitle, let page = word.sourcePage, let sha = word.sourceDocSha {
                Button {
                    onJump?(VocabJumpTarget(
                        docSha: sha,
                        docTitle: title,
                        page: page,
                        term: word.surface,
                        rectsJSON: word.sourceRectsJSON
                    ))
                } label: {
                    Label("\(title) · 第 \(page + 1) 页", systemImage: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!isSelecting)
            }
        }
        .padding(.vertical, 2)
    }

    private var filterMenu: some View {
        Menu {
            Button {
                filterGroupId = nil
            } label: {
                Label("全部", systemImage: filterGroupId == nil ? "checkmark.circle.fill" : "circle")
            }
            if !groups.isEmpty {
                Divider()
                ForEach(groups) { g in
                    Button {
                        filterGroupId = g.id
                    } label: {
                        Label("\(g.name)(\(g.count))", systemImage: filterGroupId == g.id ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
            Divider()
            Button {
                newGroupName = ""
                showNewGroup = true
            } label: {
                Label("新建分组…", systemImage: "plus")
            }
            if let gid = filterGroupId, groups.contains(where: { $0.id == gid }) {
                Button {
                    renameText = groups.first(where: { $0.id == gid })?.name ?? ""
                    showRename = true
                } label: {
                    Label("重命名当前分组…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    store.deleteGroup(id: gid)
                    filterGroupId = nil
                    reload()
                } label: {
                    Label("删除当前分组", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }

    @ViewBuilder
    private var previewBar: some View {
        if let previewWord {
            CompactCardView(content: .word(previewWord), onClose: { self.previewWord = nil })
                .frame(width: 300, height: 48)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .padding(.bottom, 18)
        }
    }

    /// 某词的全部语境(v0.8.2):原句 + 出处(可一键跳转)。
    private func contextSheet(_ word: VocabStore.WordSummary) -> some View {
        let rows = store.occurrences(forLemma: word.lemma)
        return NavigationStack {
            List {
                if rows.isEmpty {
                    Text("暂无语境记录")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { occ in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(occ.context.isEmpty ? "(无原句)" : occ.context)
                            .font(.callout)
                        Button {
                            onJump?(VocabJumpTarget(
                                docSha: occ.docSha,
                                docTitle: occ.docTitle,
                                page: occ.page,
                                term: word.surface,
                                rectsJSON: occ.rectsJSON
                            ))
                            contextWord = nil
                        } label: {
                            Label("\(occ.docTitle) · 第 \(occ.page + 1) 页", systemImage: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("「\(word.surface)」的语境(\(rows.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { contextWord = nil }
                }
            }
        }
    }

    /// 批量操作条(v0.8.2:多选 → 移动分组 / 删除)。
    private var batchBar: some View {
        HStack(spacing: 14) {
            Text("已选 \(selectedIds.count) 项")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                if groups.isEmpty {
                    Text("暂无分组(先点左上角筛选菜单新建)")
                } else {
                    ForEach(groups) { g in
                        Button(g.name) { batchMove(to: g.id) }
                    }
                }
            } label: {
                Label("移动到分组", systemImage: "folder")
                    .font(.subheadline)
            }
            .disabled(selectedIds.isEmpty)
            Button(role: .destructive) {
                showBatchDeleteConfirm = true
            } label: {
                Label("删除", systemImage: "trash")
                    .font(.subheadline)
            }
            .disabled(selectedIds.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func batchMove(to groupId: Int64) {
        for id in selectedIds {
            store.setMembership(wordId: id, groupId: groupId, member: true)
        }
        selectedIds.removeAll()
        isSelecting = false
        reload()
    }

    private func batchDelete() {
        for id in selectedIds {
            store.deleteWord(id: id)
        }
        selectedIds.removeAll()
        isSelecting = false
        reload()
    }

    private func reload() {
        words = store.listWords(
            docSha: scopeDocSha,
            groupId: filterGroupId,
            search: searchText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : searchText
        )
        groups = store.groups()
    }
}
