import UIKit
import PDFKit

/// PDFView 子类:屏蔽编辑菜单中的"全选"。
/// 原因:文字量大的 PDF 上,全选会选中整篇文档,触发海量高亮注解/内存暴涨,
/// 造成卡死甚至被系统杀死(社区已知问题)。其余菜单项(复制等)保留。
final class VocabPDFView: PDFView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponderStandardEditActions.selectAll(_:)) {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }
}
