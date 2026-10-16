import SwiftUI

/// 生词详情(v0.10.0,Task 2.2):复用词卡内容 + 备注 + 分组勾选 + 「跳转至原文」。
struct VocabularyDetailView: View {
    let store: VocabStore
    let word: VocabStore.WordSummary
    var onJump: ((VocabJumpTarget) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var groups: [VocabStore.GroupSummary] = []
    @State private var members: Set<Int64> = []
    @State private var noteSaveWork: DispatchWorkItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 复用词卡内容(音标 / 美英发音 / 考试标签 / 中英释义);v0.13.0:提供义项勾选桥
                let vs = store
                WordCardPanel(
                    content: .word(word.lemma),
                    onClose: { dismiss() },
                    onSelectWord: { _ in },
                    vocab: CardVocabBridge(
                        query: { key in
                            (collected: vs.entryId(forLemma: key) != nil,
                             occurrenceCount: vs.occurrenceCount(forLemma: key))
                        },
                        excludedSenses: { key in vs.excludedSenseIndices(forLemma: key) },
                        setSense: { key, idx, keep in vs.setSenseSelection(forLemma: key, idx: idx, keep: keep) }
                    )
                )
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("备注")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("写点备注(词根 / 记忆法 / 出处…)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.callout)
                        .onChange(of: note) { _, _ in scheduleNoteSave() }
                    HStack(spacing: 12) {
                        Menu {
                            if groups.isEmpty {
                                Text("暂无分组(在生词本页「新建分组」)")
                            } else {
                                ForEach(groups) { g in
                                    Button {
                                        toggleGroup(g.id)
                                    } label: {
                                        Label(g.name, systemImage: members.contains(g.id) ? "checkmark.circle.fill" : "circle")
                                    }
                                }
                            }
                        } label: {
                            Label("分组", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()

                        if let target = jumpTarget {
                            Button {
                                onJump?(target)
                                dismiss()
                            } label: {
                                Label("跳转至原文", systemImage: "arrow.up.right")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("生词详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { load() }
            .onDisappear { saveNoteNow() }
        }
    }

    private var jumpTarget: VocabJumpTarget? {
        guard let title = word.sourceDocTitle, let page = word.sourcePage, let sha = word.sourceDocSha else { return nil }
        return VocabJumpTarget(
            docSha: sha,
            docTitle: title,
            page: page,
            term: word.surface,
            rectsJSON: word.sourceRectsJSON
        )
    }

    private func load() {
        note = store.note(forLemma: word.lemma)
        groups = store.groups()
        members = store.groupIds(forLemma: word.lemma)
    }

    private func toggleGroup(_ groupId: Int64) {
        let member = !members.contains(groupId)
        store.setMembership(wordId: word.id, groupId: groupId, member: member)
        if member {
            members.insert(groupId)
        } else {
            members.remove(groupId)
        }
        groups = store.groups()
    }

    // MARK: - 备注(0.8s 防抖 + 退出兜底)

    private func scheduleNoteSave() {
        noteSaveWork?.cancel()
        let lemma = word.lemma
        let value = note
        let work = DispatchWorkItem { store.setNote(forLemma: lemma, note: value) }
        noteSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func saveNoteNow() {
        noteSaveWork?.cancel()
        noteSaveWork = nil
        store.setNote(forLemma: word.lemma, note: note)
    }
}
