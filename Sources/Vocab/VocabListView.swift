import SwiftUI

/// 生词本列表(v0.10.0,Task 2.2/2.3 重构):
/// - **文件夹拖动条**:全部 / 未分组 / 各分组(点=筛选;**把单词拖到分组文件夹上=移动分组**;长按分组=重命名/删除);
/// - 行:[单词][发音][跳转至原文] + 释义预览 + 备注 + 出处/语境;点行=词卡详情;长按=快捷菜单;左滑删除;
/// - 多选批量删除(自绘勾选,不走 List selection,避免和拖动排序抢编辑态)。
///
/// v0.24.0(用户反馈「生词本 UI 和整体不匹配」「生词无法拖动换位置」)重做:
/// - 视觉全面对齐 DS 与文档库:中性底 + 白卡 + 细边 + 一个强调蓝,英文词条走衬线声部;
/// - 顶部加「总览卡」:词数 / 分组数 / 当前排序,排序可切(手动 / 最近 / 字母);
/// - **手动排序**:⋯ → 调整顺序 → 拖动右侧手柄改顺序,落库 `vocab_word.sortOrder`(v11 迁移),
///   在任何筛选(全部/分组/未分组)下拖动都会正确合并回全表顺序;
/// - 空态、语境面板、批量条统一 DS 样式。
struct VocabListView: View {
    let store: VocabStore
    var scopeDocSha: String? = nil
    var onJump: ((VocabJumpTarget) -> Void)? = nil
    /// v0.13.0:导出时若提供,可生成「页面截图」媒体
    var docStore: DocumentStore? = nil

    enum Filter: Equatable {
        case all
        case ungrouped
        case group(Int64)
    }

    private enum ListMode: Equatable {
        case browse, select, reorder
    }

    @Environment(\.dismiss) private var dismiss
    @State private var words: [VocabStore.WordSummary] = []
    @State private var groups: [VocabStore.GroupSummary] = []
    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var contextWord: VocabStore.WordSummary?
    @State private var detailWord: VocabStore.WordSummary?
    @State private var listMode: ListMode = .browse
    @State private var selectedIds: Set<Int64> = []
    @State private var showBatchDeleteConfirm = false
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var showRename = false
    @State private var renameGroupId: Int64?
    @State private var renameText = ""
    @State private var noteWord: VocabStore.WordSummary?
    @State private var noteText = ""
    @State private var showExport = false
    /// v0.24.0:排序方式(持久化);手动排序才允许拖动
    @AppStorage("vocabSortMode") private var sortRaw = "manual"

    private var sortMode: VocabStore.SortMode {
        switch sortRaw {
        case "recent": return .recent
        case "alpha": return .alpha
        default: return .manual
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            libraryContent
                .navigationTitle(scopeDocSha == nil ? "生词本" : "生词本(本文档)")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, prompt: "搜索生词")
                .toolbar { toolbarContent }
                .safeAreaInset(edge: .bottom) { bottomBar }
                .task { reload() }
                .onChange(of: searchText) { _, _ in reload() }
        }
    }

    // MARK: - 骨架

    private var libraryContent: some View {
        VStack(spacing: 0) {
            summaryCard
            folderStrip
            if words.isEmpty {
                emptyHint
            } else {
                wordList
            }
        }
        .background(DS.background1.ignoresSafeArea())
        .sheet(item: $contextWord) { word in contextSheet(word) }
        .sheet(item: $detailWord) { word in
            VocabularyDetailView(store: store, word: word, onJump: onJump)
        }
        .sheet(isPresented: $showExport) {
            AnkiExportSheet(store: store, words: words, docStore: docStore)
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
        .confirmationDialog(
            "删除选中的 \(selectedIds.count) 个生词?",
            isPresented: $showBatchDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { batchDelete() }
        }
    }

    // MARK: - 工具条

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showExport = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("导出到 Anki")
            .disabled(words.isEmpty || listMode == .reorder)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if listMode == .browse {
                    Button {
                        listMode = .select
                    } label: {
                        Label("选择单词", systemImage: "checkmark.circle")
                    }
                    Button {
                        if sortRaw != "manual" {
                            sortRaw = "manual"
                            reload()
                        }
                        withAnimation(DS.Motion.spring) { listMode = .reorder }
                    } label: {
                        Label("调整顺序", systemImage: "arrow.up.arrow.down")
                    }
                } else {
                    Button {
                        withAnimation(DS.Motion.spring) { exitSpecialMode() }
                    } label: {
                        Label("结束\(listMode == .select ? "选择" : "排序")", systemImage: "checkmark")
                    }
                }
                Divider()
                Button {
                    sortRaw = "manual"
                    reload()
                } label: {
                    Label("手动顺序", systemImage: sortRaw == "manual" ? "checkmark" : "hand.draw")
                }
                Button {
                    sortRaw = "recent"
                    listMode = .browse
                    reload()
                } label: {
                    Label("最近添加", systemImage: sortRaw == "recent" ? "checkmark" : "clock")
                }
                Button {
                    sortRaw = "alpha"
                    listMode = .browse
                    reload()
                } label: {
                    Label("字母顺序", systemImage: sortRaw == "alpha" ? "checkmark" : "textformat.abc")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("更多")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("完成") { dismiss() }
        }
    }

    private func exitSpecialMode() {
        listMode = .browse
        selectedIds.removeAll()
    }

    // MARK: - 总览卡

    private var summaryCard: some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isSearching ? "找到 \(words.count) 个" : "共 \(words.count) 词")
                    .font(DS.Fonts.monoCaption)
                    .foregroundStyle(DS.foreground1)
                Text(summarySubtitle)
                    .font(DS.Fonts.micro)
                    .foregroundStyle(DS.foreground3)
            }
            Spacer(minLength: DS.Space.xs)
            Menu {
                Button("手动顺序") { sortRaw = "manual"; reload() }
                Button("最近添加") { sortRaw = "recent"; listMode = .browse; reload() }
                Button("字母顺序") { sortRaw = "alpha"; listMode = .browse; reload() }
            } label: {
                HStack(spacing: DS.Space.x3s) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10, weight: .bold))
                    Text(sortTitle)
                        .font(DS.Fonts.caption2)
                }
                .foregroundStyle(DS.foreground2)
                .padding(.horizontal, DS.Space.s)
                .frame(height: 30)
                .background(DS.background1, in: Capsule())
                .overlay(Capsule().strokeBorder(DS.foreground1.opacity(0.07), lineWidth: 0.8))
            }
            .accessibilityLabel("排序方式:\(sortTitle)")
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.comfy, style: .continuous)
                .fill(DS.background2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.comfy, style: .continuous)
                .strokeBorder(DS.foreground1.opacity(0.065), lineWidth: 0.8)
        )
        .padding(.horizontal, DS.Layout.pageMargin)
        .padding(.top, DS.Space.xs)
        .padding(.bottom, DS.Space.x2s)
    }

    private var sortTitle: String {
        switch sortMode {
        case .manual: return "手动"
        case .recent: return "最近"
        case .alpha: return "字母"
        }
    }

    private var summarySubtitle: String {
        let groupPart = groups.isEmpty ? "暂无分组" : "\(groups.count) 个分组"
        switch filter {
        case .all: return "\(groupPart) · \(sortTitle)排序"
        case .ungrouped: return "未分组 · \(groupPart)"
        case .group(let id):
            let name = groups.first(where: { $0.id == id })?.name ?? "分组"
            return "\(name) · \(groupPart)"
        }
    }

    // MARK: - 文件夹拖动条(v0.10.0,Task 2.3)

    private var folderStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.x2s) {
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
            .padding(.horizontal, DS.Layout.pageMargin)
            .padding(.vertical, DS.Space.xs)
        }
        .background(DS.background1)
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
        List {
            ForEach(words) { word in
                row(for: word)
                    .listRowInsets(EdgeInsets(top: 4, leading: DS.Layout.pageMargin, bottom: 4, trailing: DS.Layout.pageMargin))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
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
            .onMove(perform: moveRows)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(listMode == .reorder ? .active : .inactive))
    }

    @ViewBuilder
    private func row(for word: VocabStore.WordSummary) -> some View {
        let index = (words.firstIndex(where: { $0.id == word.id }) ?? 0) + 1
        let selected = selectedIds.contains(word.id)
        Button {
            switch listMode {
            case .browse:
                detailWord = word
            case .select:
                toggleSelection(word.id)
            case .reorder:
                break
            }
        } label: {
            VocabRowView(
                word: word,
                ordinal: index,
                showOrdinal: sortMode == .manual && !isSearching,
                selecting: listMode == .select,
                selected: selected,
                store: store,
                onAudio: {
                    SpeechService.shared.speak(word.surface, language: SpeechService.usVoice)
                },
                onJump: word.sourceDocSha != nil ? { jumpToSource(word) } : nil,
                onContexts: word.occurrenceCount > 0 ? { contextWord = word } : nil
            )
        }
        .buttonStyle(.plain)
        .modifier(RowDragModifier(enabled: listMode != .reorder, payload: String(word.id)))
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
    }

    private func toggleSelection(_ id: Int64) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    /// v0.24.0:拖动排序落地 —— 可见子集的新顺序合并回"同文档范围"的全表顺序。
    private func moveRows(from source: IndexSet, to destination: Int) {
        guard sortMode == .manual, !isSearching else { return }
        var moved = words.map(\.id)
        moved.move(fromOffsets: source, toOffset: destination)
        let full = store.listWords(docSha: scopeDocSha).map(\.id)
        store.applyManualOrder(fullOrder: full, visible: words.map(\.id), moved: moved)
        DiagLog.log("vocab: move \(source) -> \(destination)")
        reload()
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
        Divider()
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

    // MARK: - 空态

    private var emptyHint: some View {
        VStack(spacing: DS.Space.s) {
            Spacer(minLength: 0)
            VStack(spacing: DS.Space.s) {
                Image(systemName: emptyIcon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(DS.accent)
                    .frame(width: 64, height: 64)
                    .background(DS.accentContainer, in: Circle())
                Text(emptyTitle)
                    .font(DS.Fonts.headline)
                    .foregroundStyle(DS.foreground1)
                Text(emptyHintText)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.foreground3)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.l)
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.comfy, style: .continuous)
                    .fill(DS.background2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.comfy, style: .continuous)
                    .strokeBorder(DS.foreground1.opacity(0.065), lineWidth: 0.8)
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Layout.pageMargin)
    }

    private var emptyIcon: String {
        if isSearching { return "magnifyingglass" }
        switch filter {
        case .all: return "text.book.closed"
        case .ungrouped: return "tray"
        case .group: return "folder"
        }
    }

    private var emptyTitle: String {
        if isSearching { return "没有匹配的生词" }
        switch filter {
        case .all: return "生词本还是空的"
        case .ungrouped: return "没有未分组的词"
        case .group: return "这个分组还没有词"
        }
    }

    private var emptyHintText: String {
        if isSearching { return "换个拼写试试;搜索只匹配单词本身。" }
        switch filter {
        case .all:
            return scopeDocSha == nil
                ? "阅读时选中单词 → 编辑栏「加入生词本」"
                : "本文档还没有生词\n阅读时选中单词 → 编辑栏「加入生词本」"
        case .ungrouped:
            return "在「全部」里长按单词 → 移出所有分组"
        case .group:
            return "长按单词拖到上方的分组文件夹即可加入"
        }
    }

    // MARK: - 语境列表(点「N 处语境」)

    private func contextSheet(_ word: VocabStore.WordSummary) -> some View {
        let rows = store.occurrences(forLemma: word.lemma)
        return NavigationStack {
            ScrollView {
                LazyVStack(spacing: DS.Space.xs) {
                    if rows.isEmpty {
                        Text("暂无语境记录")
                            .font(DS.Fonts.caption)
                            .foregroundStyle(DS.foreground3)
                            .padding(DS.Space.l)
                    }
                    ForEach(rows) { occ in
                        VStack(alignment: .leading, spacing: DS.Space.x2s) {
                            Text(occ.context.isEmpty ? "(无原句)" : occ.context)
                                .font(DS.Fonts.wordBody)
                                .foregroundStyle(DS.foreground1)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
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
                                HStack(spacing: DS.Space.x3s) {
                                    Text("\(occ.docTitle) · 第 \(occ.page + 1) 页")
                                        .font(DS.Fonts.monoCaption)
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .foregroundStyle(DS.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(DS.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                                .fill(DS.background2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                                .strokeBorder(DS.foreground1.opacity(0.06), lineWidth: 0.8)
                        )
                    }
                }
                .padding(DS.Layout.pageMargin)
            }
            .background(DS.background1.ignoresSafeArea())
            .navigationTitle("「\(word.surface)」的语境(\(rows.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { contextWord = nil }
                }
            }
        }
    }

    // MARK: - 底部条(批量 / 排序提示)

    @ViewBuilder
    private var bottomBar: some View {
        if listMode == .select {
            batchBar
        } else if listMode == .reorder {
            reorderHint
        }
    }

    private var batchBar: some View {
        HStack(spacing: DS.Space.m) {
            Text("已选 \(selectedIds.count) 项")
                .font(DS.Fonts.caption)
                .foregroundStyle(DS.foreground2)
            Spacer()
            Button(role: .destructive) {
                showBatchDeleteConfirm = true
            } label: {
                Label("删除", systemImage: "trash")
                    .font(DS.Fonts.caption2)
            }
            .disabled(selectedIds.isEmpty)
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: 52)
        .dsFloatingPanel(radius: DS.Radius.pill)
        .padding(.horizontal, DS.Space.m)
        .padding(.bottom, DS.Space.xs)
    }

    private var reorderHint: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "hand.draw")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.accent)
            Text("拖动右侧手柄调整顺序")
                .font(DS.Fonts.caption2)
                .foregroundStyle(DS.foreground2)
            Spacer(minLength: 0)
            Button("完成") { withAnimation(DS.Motion.spring) { exitSpecialMode() } }
                .font(DS.Fonts.caption2)
                .foregroundStyle(DS.accent)
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: 44)
        .dsFloatingPanel(radius: DS.Radius.pill)
        .padding(.horizontal, DS.Space.m)
        .padding(.bottom, DS.Space.xs)
    }

    private func batchDelete() {
        for id in selectedIds {
            store.deleteWord(id: id)
        }
        selectedIds.removeAll()
        listMode = .browse
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
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        words = store.listWords(
            docSha: scopeDocSha,
            groupId: grouped,
            ungrouped: ungrouped,
            search: trimmed.isEmpty ? nil : trimmed,
            sort: sortMode
        )
        groups = store.groups()
    }
}

/// v0.24.0:排序模式下关掉 `.draggable` —— 否则长按拖拽会和列表的"拖动排序手柄"抢手势。
private struct RowDragModifier: ViewModifier {
    let enabled: Bool
    let payload: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.draggable(payload)
        } else {
            content
        }
    }
}

// MARK: - 文件夹标签(v0.10.0;v0.24.0 对齐 DSChip 视觉)

private struct FolderChip: View {
    let title: String
    let icon: String
    let active: Bool
    var count: Int? = nil
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: DS.Space.x2s) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(DS.Fonts.caption2)
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(DS.Fonts.micro.monospacedDigit())
                        .foregroundStyle(active ? DS.accent.opacity(0.72) : DS.foreground3)
                }
            }
            .padding(.horizontal, DS.Space.s)
            .frame(height: 30)
            .foregroundStyle(active ? DS.accent : DS.foreground2)
            .background(
                Capsule().fill(active ? DS.accentContainer : DS.background2)
            )
            .overlay(
                Capsule().strokeBorder(
                    active ? DS.accent.opacity(0.22) : DS.foreground1.opacity(0.07),
                    lineWidth: 0.8
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(DSPressableButtonStyle())
        .accessibilityAddTraits(active ? .isSelected : AccessibilityTraits())
    }
}

// MARK: - 行(v0.24.0:白卡 + 衬线词条 + 序号 + 备注 + 出处)

private struct VocabRowView: View {
    let word: VocabStore.WordSummary
    let ordinal: Int
    let showOrdinal: Bool
    let selecting: Bool
    let selected: Bool
    let store: VocabStore
    var onAudio: () -> Void
    var onJump: (() -> Void)?
    var onContexts: (() -> Void)?

    @State private var translation: String?
    @State private var note: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            if selecting {
                selectionMark
            } else if showOrdinal {
                Text("\(ordinal)")
                    .font(DS.Fonts.micro.monospacedDigit())
                    .foregroundStyle(DS.foreground4)
                    .frame(width: 22, alignment: .trailing)
                    .padding(.top, 5)
            }
            VStack(alignment: .leading, spacing: DS.Space.x2s) {
                titleRow
                if let translation, !translation.isEmpty {
                    Text(translation)
                        .font(DS.Fonts.wordBody)
                        .foregroundStyle(DS.foreground2)
                        .lineLimit(2)
                        .lineSpacing(2)
                }
                if !note.isEmpty {
                    Text(note)
                        .font(DS.Fonts.wordQuote)
                        .foregroundStyle(DS.foreground3)
                        .lineLimit(2)
                }
                metaRow
            }
        }
        .padding(DS.Space.s)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.comfy, style: .continuous)
                .fill(selected ? DS.accentContainer : DS.background2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.comfy, style: .continuous)
                .strokeBorder(
                    selected ? DS.accent.opacity(0.24) : DS.foreground1.opacity(0.065),
                    lineWidth: 0.8
                )
        )
        .task(id: word.id) { await loadPreview() }
    }

    private var selectionMark: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(selected ? DS.accent : DS.foreground4)
            .padding(.top, 3)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            Text(word.surface)
                .font(DS.Fonts.title2)
                .foregroundStyle(DS.foreground1)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if word.occurrenceCount > 1 {
                Text("×\(word.occurrenceCount)")
                    .font(DS.Fonts.micro.monospacedDigit())
                    .foregroundStyle(DS.foreground3)
            }
            Spacer(minLength: 0)
            circleAction("speaker.wave.2.fill", label: "发音", tint: DS.accent, background: DS.accentContainer, action: onAudio)
            if let onJump {
                circleAction("arrow.up.right", label: "跳转至原文", tint: DS.foreground2, background: DS.background1, action: onJump)
            }
        }
    }

    @ViewBuilder
    private var metaRow: some View {
        if let onContexts, let title = word.sourceDocTitle, let page = word.sourcePage {
            Button(action: onContexts) {
                HStack(spacing: DS.Space.x3s) {
                    Text("\(title) · 第 \(page + 1) 页 · \(word.occurrenceCount) 处语境")
                        .font(DS.Fonts.caption2)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(DS.foreground3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func circleAction(
        _ systemImage: String,
        label: String,
        tint: Color,
        background: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(background, in: Circle())
        }
        .buttonStyle(DSPressableButtonStyle())
        .accessibilityLabel(label)
    }

    /// 释义 + 备注一次异步取(别在主线程查 ECDICT,2000 词会卡)
    private func loadPreview() async {
        let lemma = word.lemma
        let translation = await Task.detached(priority: .utility) { () -> String? in
            let outcome = DictionaryService.lookup(lemma)
            guard case .found(let entry) = outcome, let raw = entry.translation, !raw.isEmpty else { return nil }
            return raw.split(separator: "\n").first.map(String.init)
        }.value
        let storeRef = store
        let storedNote = await Task.detached(priority: .utility) { storeRef.note(forLemma: lemma) }.value
        guard !Task.isCancelled else { return }
        self.translation = translation
        self.note = storedNote
    }
}
