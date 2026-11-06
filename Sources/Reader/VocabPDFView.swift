import UIKit
import PDFKit
import ObjectiveC

/// PDFView 子类:屏蔽编辑菜单中的"全选"。
/// 原因:文字量大的 PDF 上,全选会选中整篇文档,触发海量高亮注解/内存暴涨,
/// 造成卡死甚至被系统杀死(社区已知问题)。其余菜单项(复制等)保留。
final class VocabPDFView: PDFView {
    private final class ReadingInsetState: NSObject {
        let base: UIEdgeInsets
        let applied: UIEdgeInsets

        init(base: UIEdgeInsets, applied: UIEdgeInsets) {
            self.base = base
            self.applied = applied
        }
    }

    private enum AssociatedKeys {
        static var readingInsetState: UInt8 = 0
    }

    static let readingEdgeInset: CGFloat = 100

    var handwritingMode = false

    func openLink(_ annotation: PDFAnnotation) {
        DiagLog.log("link: explicitly opened")
        if let action = annotation.action { super.perform(action) }
        else if let destination = annotation.destination { go(to: destination) }
    }

    static func hasTapAction(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "Link" || annotation.action != nil || annotation.destination != nil
    }

    private let linkOutline = CAShapeLayer()

    /// Display-only overlay: never mutates PDF annotations or intercepts touches.
    func refreshLinkOutlines() {
        let path = UIBezierPath()
        if !handwritingMode {
            for page in visiblePages {
                for annotation in page.annotations where Self.hasTapAction(annotation) || annotation.type == "Widget" {
                    let rect = convert(annotation.bounds,from:page)
                    if rect.intersects(bounds), !rect.isEmpty { path.append(UIBezierPath(rect:rect)) }
                }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        linkOutline.bounds = bounds
        linkOutline.position = CGPoint(x:bounds.midX,y:bounds.midY)
        linkOutline.path = path.cgPath
        linkOutline.fillColor = UIColor.clear.cgColor
        linkOutline.strokeColor = UIColor.systemBlue.withAlphaComponent(0.8).cgColor
        linkOutline.lineWidth = 1
        if layer.sublayers?.last !== linkOutline { layer.addSublayer(linkOutline) }
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        installReadingEdgeInsets()
        refreshLinkOutlines()
    }

    /// Adds breathing room around the PDF content without changing page coordinates.
    /// Associated state lets PDFKit rebuild or reset its scroll view without accumulating 100pt.
    func installReadingEdgeInsets() {
        let scrollView = documentView?.superview as? UIScrollView
            ?? PencilTouchIsolation.scrollViews(in: self).first
        guard let scrollView else { return }
        if displayMode == .singlePageContinuous {
            Self.addReadingEdgeInsets(to: scrollView)
        } else {
            Self.removeReadingEdgeInsets(from: scrollView)
        }
    }

    static func addReadingEdgeInsets(to scrollView: UIScrollView) {
        let current = scrollView.contentInset
        let previous = objc_getAssociatedObject(scrollView, &AssociatedKeys.readingInsetState) as? ReadingInsetState
        let base = UIEdgeInsets(
            top: restoredInset(current.top, previous?.applied.top, previous?.base.top),
            left: restoredInset(current.left, previous?.applied.left, previous?.base.left),
            bottom: restoredInset(current.bottom, previous?.applied.bottom, previous?.base.bottom),
            right: restoredInset(current.right, previous?.applied.right, previous?.base.right)
        )
        let inset = readingEdgeInset
        let applied = UIEdgeInsets(top: base.top + inset,
                                   left: base.left + inset,
                                   bottom: base.bottom + inset,
                                   right: base.right + inset)
        if !insetsMatch(current, applied) {
            scrollView.contentInset = applied
        }
        objc_setAssociatedObject(scrollView,
                                 &AssociatedKeys.readingInsetState,
                                 ReadingInsetState(base: base, applied: applied),
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func removeReadingEdgeInsets(from scrollView: UIScrollView) {
        guard let previous = objc_getAssociatedObject(scrollView, &AssociatedKeys.readingInsetState) as? ReadingInsetState else {
            return
        }
        let current = scrollView.contentInset
        let restored = UIEdgeInsets(
            top: restoredInset(current.top, previous.applied.top, previous.base.top),
            left: restoredInset(current.left, previous.applied.left, previous.base.left),
            bottom: restoredInset(current.bottom, previous.applied.bottom, previous.base.bottom),
            right: restoredInset(current.right, previous.applied.right, previous.base.right)
        )
        if !insetsMatch(current, restored) {
            scrollView.contentInset = restored
        }
        objc_setAssociatedObject(scrollView, &AssociatedKeys.readingInsetState, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static func restoredInset(_ current: CGFloat, _ previousApplied: CGFloat?, _ previousBase: CGFloat?) -> CGFloat {
        guard let previousApplied, let previousBase, abs(current - previousApplied) <= 0.01 else { return current }
        return previousBase
    }

    private static func insetsMatch(_ lhs: UIEdgeInsets, _ rhs: UIEdgeInsets) -> Bool {
        abs(lhs.top - rhs.top) <= 0.01
            && abs(lhs.left - rhs.left) <= 0.01
            && abs(lhs.bottom - rhs.bottom) <= 0.01
            && abs(lhs.right - rhs.right) <= 0.01
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
