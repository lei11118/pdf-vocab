import SwiftUI

/// 生词本列表(v0.7.0,M3-A 基础版):词 + 语境数 + 已掌握标记。
/// 分组/标签/筛选/批量操作留给 M3-B。
struct VocabListView: View {
    let store: VocabStore

    @Environment(\.dismiss) private var dismiss
    @State private var words: [VocabStore.WordSummary] = []

    var body: some View {
        NavigationStack {
            Group {
                if words.isEmpty {
                    ContentUnavailableView {
                        Label("生词本还是空的", systemImage: "text.book.closed")
                    } description: {
                        Text("阅读时选中单词,在词卡上点「加入生词本」。")
                    }
                } else {
                    List(words) { word in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(word.surface)
                                    .font(.body.weight(.medium))
                                Text("\(word.occurrenceCount) 处语境")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if word.status == .mastered {
                                Text("已掌握")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color(.secondarySystemBackground), in: Capsule())
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("生词本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                words = store.listWords()
            }
        }
    }
}
