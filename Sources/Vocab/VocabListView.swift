import SwiftUI

/// 生词本列表(v0.10.0,Task 2.2/2.3 重构):
/// - **文件夹拖动条**:全部 / 未分组 / 各分组(点=筛选;**把单词拖到分组文件夹上=移动分组**;长按分组=重命名/删除);
/// - 行:[单词][发音][跳转至原文] + 翻译预览;点行=词卡详情;长按=快捷菜单(备注/移动分组/发音/跳转/删除);左滑删除;
/// - 行内「文档名 · 第 N 页 · N 处语境」→ 语境列表(逐条可跳转);
/// - 多选批量删除保留(编辑模式下拖拽自动禁用)。
struct VocabListView: View {
    let store: VocabStore
    var scopeDocSha: String? = nil
    var onJump: ((VocabJumpTarget) -> Void)? = nil

    enum Filter: Equatable {
        case all
        case ungrouped
        case group(Int64)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var words: [VocabStore.WordSummary] = []
    @State private var groups: [VocabStore.GroupSummary] = []
    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var contextWord: VocabStore.WordSummary?
    @State private var detailWord: VocabStore.WordSummary?
    @State private var isSelecting = false
    @State private var selectedIds: Set<Int64> = []
    @State private var showBatchDeleteConfirm = false
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var showRename = false
    @State private var renameGroupId: Int64?
    @State private var renameText = ""
    @State private var noteWord: VocabStore.WordSummary?
    @State private var noteText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                folderStrip
                if words.isEmpty {
                    emptyHint
                } else {
                    wordList
                }
            }
            .navigationTitle(scopeDocSha == nil ? "生词本" : "生词本(本文档)")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索生词")
            .toolbar {
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
                        filter = .group(id)
                        reload()
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("重命名分组", isPresented: $showRename) {
                TextField("新名称", text: $renameText)
                Button("保存") {
                    if let gid = renameGroupId {
                        store.renameGroup(id: gid, name: renameText)
                        reload()
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("备注", isPresented: Binding(
                get: { noteWord != nil },
                set: { if !$0 { noteWord = nil } }
            )) {
                TextField("备注(词根/记忆法/出处…)", text: $noteText, axis: .vertical)
                    .lineLimit(2...5)
                Button("保存") {
                    if let w = noteWord { store.setNote(forLemma: w.lemma, note: noteText) }
                    noteWord = nil
                }
                Button("取消", role: .cancel) { noteWord = nil }
            }
            .sheet(item: $contextWord) { word in
                contextSheet(word)
            }
            .sheet(item: $detailWord) { word in
                VocabularyDetailView(store: store, word: word, onJump: onJump)
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    batchBar
                }
            }
            .confirmationDialog("删除选中的 \(selectedIds.count) 个生词?", isPresented: $showBatchDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) { batchDelete() }
            }
            .task { reload() }
            .onChange(of: searchText) { _, _ in reload() }
        }
    }

    // MARK: - 文件夹拖动条(v0.10.0,Task 2.3)

    private var folderStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                FolderChip(title: "全部", icon: "square.grid.2x2", active: filter == .all) {
                    filter = .all
                    reload()
                }
                FolderChip(title: "未分组", icon: "tray", active: filter == .ungrouped) {
                    filter = .ungrouped
                    reload()
                }
                .dropDestination(for: String.self) { items, _ in
                    moveWords(items, toGroup: nil)
                }
                ForEach(groups) { g in
                    FolderChip(title: g.name, icon: "folder", active: filter == .group(g.id), count: g.count) {
                        filter = .group(g.id)
                        reload()
                    }
                    .dropDestination(for: String.self) { items, _ in
                        moveWords(items, toGroup: g.id)
                    }
                    .contextMenu {
                        Button {
                            renameGroupId = g.id
                            renameText = g.name
                            showRename = true
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            store.deleteGroup(id: g.id)
                            if filter == .group(g.id) { filter = .all }
                            reload()
                        } label: {
                            Label("删除分组", systemImage: "trash")
                        }
                    }
                }
                FolderChip(title: "新建分组", icon: "plus", active: false) {
                    newGroupName = ""
                    showNewGroup = true
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    /// 拖放落地:groupId = nil → 移出所有分组(「未分组」)。
    private func moveWords(_ items: [String], toGroup groupId: Int64?) -> Bool {
        var moved = 0
        for item in items {
            guard let id = Int64(item) else { continue }
            if let gid = groupId {
                store.setMembership(wordId: id, groupId: gid, member: true)
            } else {
                store.removeFromAllGroups(wordId: id)
            }
            moved += 1
        }
        if moved > 0 {
            DiagLog.log("vocab drag-drop: \(moved) 词 → \(groupId.map { "分组#\($0)" } ?? "未分组")")
            reload()
        }
        return moved > 0
    }

    // MARK: - 列表

    private var wordList: some View {
        List(selection: $selectedIds) {
            ForEach(words) { word in
                Button {
                    detailWord = word
                } label: {
                    VocabRowView(
                        word: word,
                        translationLoader: { await Self.translationPreview(for: word.lemma) },
                        onAudio: {
                            SpeechService.shared.speak(word.surface, language: SpeechService.usVoice)
                        },
                        onJump: word.sourceDocSha != nil ? { jumpToSource(word) } : nil,
                        onContexts: word.occurrenceCount > 0 ? { contextWord = word } : nil
                    )
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!isSelecting)
                .tag(word.id)
                .draggable(String(word.id))
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.deleteWord(id: word.id)
                        reload()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .contextMenu { rowMenu(word) }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
    }

    @ViewBuilder
    private func rowMenu(_ word: VocabStore.WordSummary) -> some View {
        Button {
            SpeechService.shared.speak(word.surface, language: SpeechService.usVoice)
        } label: {
            Label("发音", systemImage: "speaker.wave.2")
        }
        Button {
            noteText = store.note(forLemma: word.lemma)
            noteWord = word
        } label: {
            Label("备注…", systemImage: "note.text")
        }
        Menu {
            if groups.isEmpty {
                Text("暂无分组(上方「新建分组」)")
            } else {
                ForEach(groups) { g in
                    Button {
                        store.setMembership(wordId: word.id, groupId: g.id, member: true)
                        reload()
                    } label: {
                        Label(g.name, systemImage: "folder")
                    }
                }
            }
            Divider()
            Button {
                store.removeFromAllGroups(wordId: word.id)
                reload()
            } label: {
                Label("移出所有分组", systemImage: "tray")
            }
        } label: {
            Label("移动到分组", systemImage: "folder.badge.plus")
        }
        if word.sourceDocSha != nil {
            Button {
                jumpToSource(word)
            } label: {
                Label("跳转至原文", systemImage: "arrow.up.right")
            }
        }
        Button(role: .destructive) {
            store.deleteWord(id: word.id)
            reload()
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func jumpToSource(_ word: VocabStore.WordSummary) {
        guard let title = word.sourceDocTitle, let page = word.sourcePage, let sha = word.sourceDocSha else { return }
        onJump?(VocabJumpTarget(
            docSha: sha,
            docTitle: title,
            page: page,
            term: word.surface,
            rectsJSON: word.sourceRectsJSON
        ))
    }

    /// 翻译预览(整句首行;词库未收录返回 nil)。
    private static func translationPreview(for lemma: String) async -> String? {
        let outcome = await Task.detached(priority: .utility) {
            DictionaryService.lookup(lemma)
        }.value
        if case .found(let entry) = outcome, let raw = entry.translation, !raw.isEmpty {
            return raw.split(separator: "\n").first.map(String.init)
        }
        return nil
    }

    // MARK: - 空态

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "text.book.closed")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(emptyHintText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyHintText: String {
        switch filter {
        case .all:
            return scopeDocSha == nil
                ? "生词本还是空的\n阅读时选中单词 → 编辑栏「加入生词本」"
                : "本文档还没有生词\n阅读时选中单词 → 编辑栏「加入生词本」"
        case .ungrouped:
            return "没有未分组的生词"
        case .group:
            return "这个分组还没有生词\n长按单词拖到上方文件夹即可移动"
        }
    }

    // MARK: - 语境列表(点「N 处语境」)

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

    // MARK: - 批量(删除)

    private var batchBar: some View {
        HStack(spacing: 14) {
            Text("已选 \(selectedIds.count) 项")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
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

    private func batchDelete() {
        for id in selectedIds {
            store.deleteWord(id: id)
        }
        selectedIds.removeAll()
        isSelecting = false
        reload()
    }

    // MARK: - 数据

    private func reload() {
        var grouped: Int64?
        var ungrouped = false
        switch filter {
        case .all:
            break
        case .ungrouped:
            ungrouped = true
        case .group(let id):
            grouped = id
        }
        words = store.listWords(
            docSha: scopeDocSha,
            groupId: grouped,
            ungrouped: ungrouped,
            search: searchText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : searchText
        )
        groups = store.groups()
    }
}

// MARK: - 文件夹标签(v0.10.0)

private struct FolderChip: View {
    let title: String
    let icon: String
    let active: Bool
    var count: Int? = nil
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.footnote.weight(.medium))
                if let count {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(active ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(active ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
            .foregroundStyle(active ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 行(v0.10.0:单词 + 发音 + 跳转 + 翻译预览 + 出处/语境)

private struct VocabRowView: View {
    let word: VocabStore.WordSummary
    let translationLoader: () async -> String?
    var onAudio: () -> Void
    var onJump: (() -> Void)?
    var onContexts: (() -> Void)?

    @State private var translation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(word.surface)
                    .font(.body.weight(.semibold))
                Spacer(minLength: 0)
                Button(action: onAudio) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("发音")
                if let onJump {
                    Button(action: onJump) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("跳转至原文")
                }
            }
            if let translation, !translation.isEmpty {
                Text(translation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let onContexts, let title = word.sourceDocTitle, let page = word.sourcePage {
                Button(action: onContexts) {
                    HStack(spacing: 3) {
                        Text("\(title) · 第 \(page + 1) 页 · \(word.occurrenceCount) 处语境")
                            .font(.caption)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .task(id: word.id) {
            translation = await translationLoader()
        }
    }
}
