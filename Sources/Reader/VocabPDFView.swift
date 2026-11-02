import UIKit
import PDFKit

/// PDFView 子类:屏蔽编辑菜单中的"全选"。
/// 原因:文字量大的 PDF 上,全选会选中整篇文档,触发海量高亮注解/内存暴涨,
/// 造成卡死甚至被系统杀死(社区已知问题)。其余菜单项(复制等)保留。
final class VocabPDFView: PDFView {
    var handwritingMode = false

    // Text selection owns page taps. Native annotation actions must never run
    // before the second tap/long press and move the page under the user's finger.
    override func perform(_ action: PDFAction) {
        DiagLog.log("link: native action blocked type=\(type(of: action))")
    }

    func openLink(_ annotation: PDFAnnotation) {
        DiagLog.log("link: explicitly opened")
        if let action = annotation.action { super.perform(action) }
        else if let destination = annotation.destination { go(to: destination) }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Resolve enlarged handle targets before PDFKit's page tree can cover them.
        let handles=subviews.compactMap { $0 as? SelectionHandleView }.filter {
            !$0.isHidden && $0.alpha>0.01 && $0.point(inside:$0.convert(point,from:self),with:event)
        }
        if let handle=handles.min(by:{ $0.hitDistance(to:$0.convert(point,from:self)) < $1.hitDistance(to:$1.convert(point,from:self)) }) {
            return handle
        }
        return super.hitTest(point,with:event)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if handwritingMode { return false }
        if action == #selector(UIResponderStandardEditActions.selectAll(_:)) {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }
}
