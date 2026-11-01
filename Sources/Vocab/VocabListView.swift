import SwiftUI
import Foundation
import UniformTypeIdentifiers

/// 生词本(v0.10.0 起;v0.25.0 按用户要求"和主页一样的样式,大刀阔斧地改"整页重做)。
///
/// 视觉语言**完全复用文档库**:同一套中性底(`DS.background1`)+ 白卡 + 细边 + 一个强调蓝,
/// 同样的页头(标题 + 小徽标 + 副标题 + 右上菜单)、同样的胶囊搜索框、同样的 DSChip 过滤条、
/// 同样的 `DSSectionHeader` + `LazyVGrid` 卡片网格、同样的悬浮底部动作条。
///
/// 交互:
/// - 点卡片 = 生词详情;卡片上的圆形按钮 = 发音 / 跳回原文;底部一行 = 出处 · 语境数。
/// - **拖动换位置**(v0.25.0):「⋯ → 调整顺序」后,把一张卡拖到另一张卡上即插入到它的位置;
///   平时的拖动仍可把词拖到上方的分组胶囊里换分组。菜单里另有 上移 / 下移 / 置顶 兜底。
/// - 手动顺序落库 `vocab_word.sortOrder`,在「全部 / 分组 / 未分组」任一筛选下拖动
///   都通过槽位回填合并,不会打乱其他词。
struct VocabListView: View {
    let store: VocabStore
    var scopeDocSha: String? = nil
    var onJump: ((VocabJumpTarget) -> Void)? = nil
    /// v0.13.0:导出时若提供,可生成「页面截图」媒体
    var docStore: DocumentStore? = nil
    var onClose: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Filter: Equatable {
        case all
        case ungrouped
        case group(Int64)
    }

    private enum ListMode: Equatable {
        case browse, select, reorder
    }

    @Environment(\.dismiss) private var dismiss
    @AppStorage("vocabCompactLayout") private var compactLayout = false
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
    /// v0.25.0:正在被拖动的卡片(用于抬起时轻微放大,给"拿起来了"的手感)
    @State private var showGraph=false
    @State private var dragOriginal:[Int64]=[]
    @State private var dragGeneration=UUID()
    @State private var dragCancel:DispatchWorkItem?
    @State private var scrollProxy:ScrollViewProxy?
    @State private var scrollHeight:CGFloat=0
    @State private var cardFrames:[Int64:CGRect]=[:]
    @State private var edgeWork:DispatchWorkItem?
    @State private var edgeDirection=0
    @State private var targetId:Int64?
    @State private var draggingId: Int64?
    /// 手动排序才允许拖动换位
    @AppStorage("vocabSortMode") private var sortRaw = "manual"

    private var sortMode: VocabStore.SortMode {
        switch sortRaw {
        case "recent": return .recent
        case "alpha": return .alpha
        default: return .manual
        }
    }

    private var sortTitle: String {
        switch sortMode {
        case .manual: return "手动"
        case .recent: return "最近"
        case .alpha: return "字母"
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                DS.background1.ignoresSafeArea()

                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: DS.Space.l) {
                                searchField.frame(minWidth: 240)
                                densityPicker.frame(width: 200)
                            }
                            VStack(spacing: DS.Space.m) { searchField; densityPicker }
                        }
                        groupStrip
                        dockLayer

                        if words.isEmpty {
                            emptyState
                                .padding(.top, DS.Space.xxl)
                        } else {
                            gridSection
                        }
                    }
                    .padding(.horizontal, DS.Layout.pageMargin)
                    .padding(.top, DS.Space.xs)
                    .padding(.bottom, DS.Space.l)
                }
                .scrollIndicators(.hidden)
                .coordinateSpace(name:"vocab-scroll")
                .background(GeometryReader { geometry in Color.clear.onAppear { scrollHeight=geometry.size.height }.onChange(of:geometry.size.height) { _,value in scrollHeight=value } })
                .onPreferenceChange(VocabCardFrames.self) { cardFrames=$0 }
                .onAppear { scrollProxy=proxy }
                .onDrop(of:[UTType.text],delegate:VocabGridDropDelegate(enter:{},leave:{scheduleDragCancel()},finish:{finishCardDrag(commit:true)},update:{point in updateEdgeScroll(y:point.y)}))
                }

            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: DS.Space.m) { header }
                    .padding(.horizontal, DS.Layout.pageMargin)
                    .padding(.top, DS.Space.s)
                    .padding(.bottom, DS.Space.m)
                    .background(DS.background1)
            }

            .toolbar(.hidden, for: .navigationBar)
            .task { reload() }
            .animation(reduceMotion ? nil : DS.Motion.quickSpring, value: compactLayout)
            .animation(reduceMotion ? nil : DS.Motion.quickSpring, value: listMode)
            .animation(reduceMotion ? nil : DS.Motion.quickSpring, value: filter)
            .animation(reduceMotion ? nil : DS.Motion.quickSpring, value: selectedIds)
            .onChange(of: searchText) { _, _ in reload() }
            .sheet(item: $contextWord) { word in contextSheet(word) }
            .sheet(item: $detailWord) { word in
                VocabularyDetailView(store: store, word: word, onJump: onJump)
            }
            .fullScreenCover(isPresented:$showGraph) { VocabGraphView(store:store,words:words,onJump:onJump) }
            .onDisappear { finishCardDrag(commit:false) }
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
                    reload()
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
    }

    // MARK: - 页头(与文档库同一套版式)

    private var header: some View {
        DSPageHeading(title: "生词本", eyebrow: "WORDS · COLLECTION", subtitle: headerSubtitle) {
            HStack(spacing: DS.Space.xs) {
                DSIconButton(systemImage: "point.3.connected.trianglepath.dotted", foreground: DS.accent,
                             background: DS.accentContainer, accessibility: "知识图谱") { showGraph = true }
                moreMenu
                DSIconButton(systemImage: "xmark", iconSize: 14, background: DS.background2,
                             accessibility: "关闭生词本") {
                    if let onClose { onClose() } else { dismiss() }
                }
            }
        }
    }

    private var headerSubtitle: String {
        let scope = scopeDocSha == nil ? "" : "本文档 · "
        if isSearching { return "\(scope)找到 \(words.count) 个词" }
        let groupPart = groups.isEmpty ? "暂无分组" : "\(groups.count) 个分组"
        return "\(scope)\(words.count) 词 · \(groupPart) · \(sortTitle)顺序"
    }

    private var moreMenu: some View {
        Menu {
            if listMode == .browse {
                Button {
                    withAnimation(reduceMotion ? nil : DS.Motion.spring) { listMode = .select }
                } label: {
                    Label("选择单词", systemImage: "checkmark.circle")
                }
                Button {
                    if sortRaw != "manual" {
                        sortRaw = "manual"
                        reload()
                    }
                    withAnimation(reduceMotion ? nil : DS.Motion.spring) { listMode = .reorder }
                } label: {
                    Label("调整顺序", systemImage: "arrow.up.arrow.down")
                }
            } else {
                Button {
                    withAnimation(reduceMotion ? nil : DS.Motion.spring) { exitSpecialMode() }
                } label: {
                    Label(listMode == .select ? "结束选择" : "结束排序", systemImage: "checkmark")
                }
            }

            Divider()

            Button {
                sortRaw = "manual"
                listMode = .browse
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

            Divider()

            Button {
                showExport = true
            } label: {
                Label("导出到 Anki", systemImage: "square.and.arrow.up")
            }
            .disabled(words.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(DS.foreground2)
                .frame(width: 44, height: 44)
                .background(DSReliefSurface(radius: 22))
        }
        .accessibilityLabel("更多")
    }

    // MARK: - 共享搜索与分组过滤

    private var densityPicker: some View {
        Picker("浏览密度", selection: $compactLayout) {
            Label("卡片", systemImage: "square.grid.2x2").tag(false)
            Label("紧凑", systemImage: "rectangle.grid.1x2").tag(true)
        }
        .pickerStyle(.segmented)
        .padding(6)
        .background(DSReliefSurface(radius: 20, inset: true))
    }

    private var searchField: some View {
        DSSearchField(placeholder: "搜索生词", text: $searchText)
    }

    private var groupStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.x2s) {
                chip(title: "全部", icon: "square.grid.2x2", active: filter == .all) {
                    filter = .all
                    reload()
                }
                chip(title: "未分组", icon: "tray", active: filter == .ungrouped) {
                    filter = .ungrouped
                    reload()
                }
                .dropDestination(for: String.self) { items, _ in
                    moveWords(items, toGroup: nil)
                }

                ForEach(groups) { group in
                    chip(
                        title: group.count > 0 ? "\(group.name) \(group.count)" : group.name,
                        icon: "folder",
                        active: filter == .group(group.id)
                    ) {
                        filter = .group(group.id)
                        reload()
                    }
                    .dropDestination(for: String.self) { items, _ in
                        moveWords(items, toGroup: group.id)
                    }
                    .contextMenu {
                        Button {
                            renameGroupId = group.id
                            renameText = group.name
                            showRename = true
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            store.deleteGroup(id: group.id)
                            if filter == .group(group.id) { filter = .all }
                            reload()
                        } label: {
                            Label("删除分组", systemImage: "trash")
                        }
                    }
                }

                chip(title: "新建分组", icon: "plus", active: false) {
                    newGroupName = ""
                    showNewGroup = true
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(
        title: String,
        icon: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            DSChip(title: title, icon: icon, selected: active)
                .animation(reduceMotion ? nil : DS.Motion.quickSpring, value: active)
        }
        .buttonStyle(DSPressableButtonStyle())
        .accessibilityAddTraits(active ? .isSelected : AccessibilityTraits())
    }

    /// 拖放落地:groupId = nil → 移出所有分组(「未分组」)。
    private func moveWords(_ items: [String], toGroup groupId: Int64?) -> Bool {
        finishCardDrag(commit:false)
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

    // MARK: - 网格

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            DSSectionHeader(
                title: sectionTitle,
                subtitle: "\(words.count) 词 · \(sortTitle)顺序" + (listMode == .reorder ? " · 拖到另一张卡上换位" : "")
            )

            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: compactLayout ? 360 : 250, maximum: compactLayout ? 900 : 380),
                        spacing: DS.Layout.cardGap,
                        alignment: .top
                    )
                ],
                alignment: .leading,
                spacing: DS.Layout.cardGap
            ) {
                ForEach(words) { word in
                    card(word)
                        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.97)))
                }
            }
        }
    }

    private var sectionTitle: String {
        if isSearching { return "搜索结果" }
        switch filter {
        case .all: return "全部生词"
        case .ungrouped: return "未分组"
        case .group(let id): return groups.first(where: { $0.id == id })?.name ?? "分组"
        }
    }

    @ViewBuilder
    private func card(_ word: VocabStore.WordSummary) -> some View {
        let selected = selectedIds.contains(word.id)
        let ordinal = words.firstIndex(where: { $0.id == word.id }).map { $0 + 1 }
        let canReorder = sortMode == .manual && listMode != .select && !isSearching

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
            VocabCardView(
                compact: compactLayout,
                word: word,
                store: store,
                ordinal: (sortMode == .manual && !isSearching) ? ordinal : nil,
                selecting: listMode == .select,
                selected: selected,
                dragging: draggingId == word.id,
                onAudio: {
                    SpeechService.shared.speak(word.surface, language: SpeechService.usVoice)
                },
                onJump: word.sourceDocSha != nil ? { jumpToSource(word) } : nil,
                onContexts: word.occurrenceCount > 0 ? { contextWord = word } : nil
            )
        }
        .buttonStyle(DSPressableButtonStyle())
        .contextMenu { rowMenu(word) }
        .id(word.id)
        .background(GeometryReader { geometry in Color.clear.preference(key:VocabCardFrames.self,value:[word.id:geometry.frame(in:.named("vocab-scroll"))]) })
        .overlay(alignment:.top) {
            if targetId==word.id && draggingId != nil { Rectangle().fill(DS.accent).frame(height:3) }
        }
        .onDrag {
            if listMode != .select {
                draggingId=word.id;dragOriginal=words.map(\.id);dragGeneration=UUID()
            }
            return NSItemProvider(object:String(word.id) as NSString)
        }
        .onDrop(of:[UTType.text],delegate:VocabGridDropDelegate(enter:{
            dragCancel?.cancel();dragGeneration=UUID()
            guard canReorder,let id=draggingId,id != word.id else { return }
            targetId=word.id
            let ids=VocabReorderPolicy.moving(words.map(\.id),source:id,target:word.id)
            let lookup=Dictionary(uniqueKeysWithValues:words.map { ($0.id,$0) })
            withAnimation(reduceMotion ? nil : DS.Motion.spring) { words=ids.compactMap { lookup[$0] } }
        },leave:{ scheduleDragCancel() },finish:{ finishCardDrag(commit:canReorder) },update:{ point in
            if let frame=cardFrames[word.id] { updateEdgeScroll(y:frame.minY+point.y) }
        }))
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
    }

    private func finishCardDrag(commit:Bool) {
        dragCancel?.cancel();dragCancel=nil;edgeWork?.cancel();edgeWork=nil;edgeDirection=0
        guard draggingId != nil else { return }
        if commit,sortMode == .manual,!isSearching,!dragOriginal.isEmpty {
            store.applyManualOrder(fullOrder:store.listWords(docSha:scopeDocSha).map(\.id),visible:dragOriginal,moved:words.map(\.id))
        }
        draggingId=nil;targetId=nil;dragOriginal=[];reload()
    }
    private func scheduleDragCancel() {
        dragCancel?.cancel();let generation=dragGeneration
        let work=DispatchWorkItem { if generation==dragGeneration { finishCardDrag(commit:false) } }
        dragCancel=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.7,execute:work)
    }
    private func updateEdgeScroll(y:CGFloat) {
        guard draggingId != nil else { return }
        dragCancel?.cancel();dragGeneration=UUID()
        let direction=y<70 ? -1 : (y>scrollHeight-90 ? 1:0)
        if edgeDirection==direction { return }
        edgeDirection=direction;edgeWork?.cancel();edgeWork=nil
        if direction != 0 { stepEdgeScroll() }
    }
    private func stepEdgeScroll() {
        guard draggingId != nil,edgeDirection != 0,!words.isEmpty else { return }
        let visible=words.enumerated().filter { pair in
            guard let frame=cardFrames[pair.element.id] else { return false }
            return frame.maxY>0 && frame.minY<scrollHeight
        }
        let base=edgeDirection<0 ? (visible.first?.offset ?? 0):(visible.last?.offset ?? words.count-1)
        let index=max(0,min(words.count-1,base+edgeDirection*2))
        withAnimation(reduceMotion ? nil : .linear(duration:0.12)) { scrollProxy?.scrollTo(words[index].id,anchor:edgeDirection<0 ? .top:.bottom) }
        let work=DispatchWorkItem { stepEdgeScroll() };edgeWork=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.18,execute:work)
    }

    private func toggleSelection(_ id: Int64) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    // MARK: - 顺序

    /// 把 id 插到 targetId 的位置(卡片拖到卡片上)。
    private func move(id: Int64, before targetId: Int64) {
        guard id != targetId, sortMode == .manual else { return }
        var visible = words.map(\.id)
        guard let from = visible.firstIndex(of: id), let to = visible.firstIndex(of: targetId) else { return }
        visible.remove(at: from)
        let insert = from < to ? to - 1 : to
        visible.insert(id, at: max(0, min(insert, visible.count)))
        commitOrder(visible, reason: "drag \(id) -> \(targetId)")
    }

    private func nudge(_ word: VocabStore.WordSummary, by delta: Int) {
        guard sortMode == .manual else { return }
        var visible = words.map(\.id)
        guard let index = visible.firstIndex(of: word.id) else { return }
        let target = index + delta
        guard target >= 0, target < visible.count else { return }
        visible.swapAt(index, target)
        commitOrder(visible, reason: "nudge \(word.id) \(delta > 0 ? "down" : "up")")
    }

    private func moveToEdge(_ word: VocabStore.WordSummary, front: Bool) {
        guard sortMode == .manual else { return }
        var visible = words.map(\.id)
        guard let index = visible.firstIndex(of: word.id) else { return }
        visible.remove(at: index)
        if front {
            visible.insert(word.id, at: 0)
        } else {
            visible.append(word.id)
        }
        commitOrder(visible, reason: "edge \(word.id) \(front ? "top" : "bottom")")
    }

    private func commitOrder(_ visible: [Int64], reason: String) {
        let before = words.map(\.id)
        let full = store.listWords(docSha: scopeDocSha).map(\.id)
        store.applyManualOrder(fullOrder: full, visible: before, moved: visible)
        DiagLog.log("vocab: \(reason)")
        reload()
    }

    // MARK: - 卡片菜单

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
                ForEach(groups) { group in
                    Button {
                        store.setMembership(wordId: word.id, groupId: group.id, member: true)
                        reload()
                    } label: {
                        Label(group.name, systemImage: "folder")
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
        if sortMode == .manual {
            Divider()
            Button {
                nudge(word, by: -1)
            } label: {
                Label("上移一位", systemImage: "arrow.up")
            }
            Button {
                nudge(word, by: 1)
            } label: {
                Label("下移一位", systemImage: "arrow.down")
            }
            Button {
                moveToEdge(word, front: true)
            } label: {
                Label("移到最前", systemImage: "arrow.up.to.line")
            }
            Button {
                moveToEdge(word, front: false)
            } label: {
                Label("移到最后", systemImage: "arrow.down.to.line")
            }
        }
        if word.sourceDocSha != nil {
            Divider()
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

    private var emptyState: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: emptyIcon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(DS.accent)
                .frame(width: 64, height: 64)
                .background(DSReliefSurface(radius: 18, inset: true))
            Text(emptyTitle)
                .font(DS.Fonts.title2)
                .foregroundStyle(DS.foreground1)
            Text(emptyHintText)
                .font(DS.Fonts.subhead)
                .foregroundStyle(DS.foreground3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.comfy, style: .continuous)
                .fill(DS.background2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.comfy, style: .continuous)
                .strokeBorder(DS.foreground1.opacity(0.065), lineWidth: 0.8)
        )
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
            return "长按单词拖到上方的分组胶囊即可加入"
        }
    }

    // MARK: - 语境面板

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
                            .buttonStyle(DSPressableButtonStyle())
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

    // MARK: - 底部动作条(与文档库同一个悬浮胶囊)

    private var dockLayer: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            dockContent.padding(DS.Space.s)
        }
        .background(DSReliefSurface(radius: 24, inset: true))
        .contentTransition(.numericText())
    }

    private var dockContent: some View {
        HStack(spacing: DS.Space.x3s) {
            HStack(spacing: DS.Space.x2s) {
                Image(systemName: listMode == .select ? "checkmark.circle.fill" : "text.book.closed.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text(listMode == .select ? "已选 \(selectedIds.count)" : "\(words.count) 词")
                    .font(DS.Fonts.caption2)
            }
            .foregroundStyle(DS.foreground2)
            .padding(.horizontal, DS.Space.s)
            .frame(minHeight: 44)

            Rectangle()
                .fill(DS.foreground1.opacity(0.09))
                .frame(width: 1, height: 22)

            switch listMode {
            case .browse:
                dockGhost(title: "选择", icon: "checkmark.circle") {
                    withAnimation(reduceMotion ? nil : DS.Motion.spring) { listMode = .select }
                }
                dockGhost(title: "排序", icon: "arrow.up.arrow.down") {
                    if sortRaw != "manual" { sortRaw = "manual" }
                    withAnimation(reduceMotion ? nil : DS.Motion.spring) { listMode = .reorder }
                }
                dockAccent(title: "导出 Anki", icon: "square.and.arrow.up") {
                    showExport = true
                }
                .disabled(words.isEmpty)

            case .select:
                dockGhost(title: "删除", icon: "trash") {
                    showBatchDeleteConfirm = true
                }
                .disabled(selectedIds.isEmpty)
                dockAccent(title: "完成", icon: "checkmark") {
                    withAnimation(reduceMotion ? nil : DS.Motion.spring) { exitSpecialMode() }
                }

            case .reorder:
                Text("把卡片拖到另一张卡上换位")
                    .font(DS.Fonts.caption2)
                    .foregroundStyle(DS.foreground3)
                    .padding(.horizontal, DS.Space.xs)
                dockAccent(title: "完成", icon: "checkmark") {
                    withAnimation(reduceMotion ? nil : DS.Motion.spring) { exitSpecialMode() }
                }
            }
        }
    }

    private func dockGhost(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.x2s) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(DS.Fonts.caption2)
            }
            .foregroundStyle(DS.foreground2)
            .padding(.horizontal, DS.Space.s)
            .frame(minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.sharp))
        }
        .buttonStyle(DSPressableButtonStyle())
    }

    private func dockAccent(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.x2s) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                Text(title)
                    .font(DS.Fonts.caption2)
            }
            .foregroundStyle(DS.onAccent)
            .padding(.horizontal, DS.Space.m)
            .frame(minHeight: 44)
            .background(DSReliefSurface(radius: 16, fill: DS.accent))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.sharp))
        }
        .buttonStyle(DSPressableButtonStyle())
    }

    private func exitSpecialMode() {
        listMode = .browse
        selectedIds.removeAll()
        draggingId = nil
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

// MARK: - 拖动(卡片之间换位)

/// 排序/浏览模式下都可拖:浏览时拖到分组胶囊 = 换分组。
private struct CardDragModifier: ViewModifier {
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

/// 只有手动排序且不在选择态时,卡片才是拖放目标(放到谁身上 = 插到谁的位置)。
private struct CardDropModifier: ViewModifier {
    let enabled: Bool
    let onDrop: ([String]) -> Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: String.self) { items, _ in
                onDrop(items)
            }
        } else {
            content
        }
    }
}

// MARK: - 生词卡(与文档库的卡片同一套:白面 + 细边 + 轻阴影)

private struct VocabCardView: View {
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let word: VocabStore.WordSummary
    let store: VocabStore
    let ordinal: Int?
    let selecting: Bool
    let selected: Bool
    let dragging: Bool
    var onAudio: () -> Void
    var onJump: (() -> Void)?
    var onContexts: (() -> Void)?

    @State private var translation: String?
    @State private var note: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .top, spacing: DS.Space.xs) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(selected ? DS.accent : DS.foreground4)
                        .padding(.top, 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.x2s) {
                        Text(word.surface)
                            .font(DS.Fonts.wordCard)
                            .foregroundStyle(DS.foreground1)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        if word.occurrenceCount > 1 {
                            Text("×\(word.occurrenceCount)")
                                .font(DS.Fonts.micro.monospacedDigit())
                                .foregroundStyle(DS.foreground3)
                        }
                        Spacer(minLength: 0)
                    }
                    if let ordinal {
                        Text(String(format: "%02d", ordinal))
                            .font(DS.Fonts.micro.monospacedDigit())
                            .foregroundStyle(DS.foreground4)
                    }
                }
                Button(action: onAudio) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.accent)
                        .frame(width: 44, height: 44)
                        .background(DSReliefSurface(radius: 18, inset: true))
                }
                .buttonStyle(DSPressableButtonStyle())
                .accessibilityLabel("发音")
            }

            if let translation, !translation.isEmpty {
                Text(translation)
                    .font(DS.Fonts.wordBody)
                    .foregroundStyle(DS.foreground2)
                    .lineLimit(3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !note.isEmpty {
                Text(note)
                    .font(DS.Fonts.wordQuote)
                    .foregroundStyle(DS.foreground3)
                    .lineLimit(2)
            }

            Spacer(minLength: DS.Space.x2s)

            footer
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, minHeight: compact ? 108 : 176, alignment: .topLeading)
        .background(DSReliefSurface(radius: 26, inset: selected))
        .overlay(alignment: .topTrailing) {
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.accent).padding(8) }
        }
        .scaleEffect(dragging && !reduceMotion ? 1.02 : 1)
        .animation(reduceMotion ? nil : DS.Motion.quickSpring, value: dragging)
        .animation(reduceMotion ? nil : DS.Motion.quickSpring, value: selected)
        .contentShape(Rectangle())
        .task(id: word.id) { await loadPreview() }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: DS.Space.x2s) {
            if let onContexts, let page = word.sourcePage {
                Button(action: onContexts) {
                    HStack(spacing: 3) {
                        Text("第 \(page + 1) 页 · \(word.occurrenceCount) 处语境")
                            .font(DS.Fonts.micro)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(DS.foreground3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DSPressableButtonStyle())
            } else if let title = word.sourceDocTitle {
                Text(title)
                    .font(DS.Fonts.micro)
                    .foregroundStyle(DS.foreground3)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let onJump {
                Button(action: onJump) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.foreground2)
                        .frame(width: 24, height: 24)
                        .background(DS.background1, in: Circle())
                }
                .buttonStyle(DSPressableButtonStyle())
                .accessibilityLabel("跳转至原文")
            }
        }
    }

    /// 释义 + 备注一次异步取(别在主线程查 ECDICT,2000 词会卡)
    private func loadPreview() async {
        let lemma = word.lemma
        let storeRef = store
        let translation = await Task.detached(priority: .utility) { () -> String? in
            let outcome = DictionaryService.lookup(lemma)
            guard case .found(let entry) = outcome, let raw = entry.translation, !raw.isEmpty else { return nil }
            return raw.split(separator: "\n").first.map(String.init)
        }.value
        let storedNote = await Task.detached(priority: .utility) { storeRef.note(forLemma: lemma) }.value
        guard !Task.isCancelled else { return }
        self.translation = translation
        self.note = storedNote
    }
}

private struct VocabCardFrames:PreferenceKey {
    static var defaultValue:[Int64:CGRect]=[:]
    static func reduce(value:inout [Int64:CGRect],nextValue:()->[Int64:CGRect]) { value.merge(nextValue()) { _,new in new } }
}
private struct VocabGridDropDelegate:DropDelegate {
    var enter:()->Void
    var leave:()->Void
    var finish:()->Void
    var update:(CGPoint)->Void
    func validateDrop(info:DropInfo)->Bool { info.hasItemsConforming(to:[UTType.text]) }
    func dropEntered(info:DropInfo) { enter() }
    func dropExited(info:DropInfo) { leave() }
    func dropUpdated(info:DropInfo)->DropProposal? { update(info.location);return DropProposal(operation:.move) }
    func performDrop(info:DropInfo)->Bool { finish();return true }
}
enum VocabReorderPolicy {
    static func moving(_ ids:[Int64],source:Int64,target:Int64)->[Int64] {
        guard source != target,let from=ids.firstIndex(of:source),let to=ids.firstIndex(of:target) else { return ids }
        var result=ids;result.remove(at:from);result.insert(source,at:min(to,result.count));return result
    }
}
