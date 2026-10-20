import Foundation
import PencilKit

/// v0.27.0:**整份文档的墨迹撤销栈** —— 一条记录可以横跨多页。
///
/// 每条记录保存一组「页面 → 该页**页面坐标**下的 PKDrawing 数据」的前后快照,
/// 所以下列动作都只占**一次**撤销:
/// - 跨页书写(原点页 + 目标页一起回退,不再"撤销一次只回退半个笔迹")
/// - 直线吸附(回退到吸附前的弯笔)
/// - 橡皮一次拖动、形状一次拖动、书法一笔、清空本页
///
/// 坐标与墨迹库一致(已含超采样倍数、不含顶部出血偏移),叠层没创建时也能换算回库。
struct InkUndoEntry {
    let name: String
    let before: [Int: PKDrawing]
    let after: [Int: PKDrawing]

    /// 用序列化结果比较内容(`PKDrawing` 的 `==` 语义在新旧 SDK 上不一致,
    /// 这里只在实际入栈时比较一次,不影响落笔性能)
    var isEmpty: Bool {
        guard before.count == after.count else { return false }
        for (page, drawing) in before {
            guard let other = after[page],
                  drawing.dataRepresentation() == other.dataRepresentation() else { return false }
        }
        return true
    }
}

final class InkUndoStack {
    private var undoEntries: [InkUndoEntry] = []
    private var redoEntries: [InkUndoEntry] = []
    /// 上限:一条记录可能带两三页的快照(COW,内存占用很小)
    private let limit = 60

    var canUndo: Bool { !undoEntries.isEmpty }
    var canRedo: Bool { !redoEntries.isEmpty }
    var undoDepth: Int { undoEntries.count }
    var redoDepth: Int { redoEntries.count }

    func push(_ entry: InkUndoEntry) {
        guard !entry.isEmpty else { return }
        undoEntries.append(entry)
        if undoEntries.count > limit {
            undoEntries.removeFirst(undoEntries.count - limit)
        }
        redoEntries.removeAll()
    }

    func popUndo() -> InkUndoEntry? { undoEntries.popLast() }
    func popRedo() -> InkUndoEntry? { redoEntries.popLast() }
    func pushRedo(_ entry: InkUndoEntry) { redoEntries.append(entry) }
    func pushUndoBack(_ entry: InkUndoEntry) { undoEntries.append(entry) }
    func clear() { undoEntries.removeAll(); redoEntries.removeAll() }
}
