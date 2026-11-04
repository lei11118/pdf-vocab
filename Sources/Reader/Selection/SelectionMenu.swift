import UIKit
import PDFKit
import SwiftUI

/// Non-modal selection toolbar. Only its own visible bounds receive touches,
/// leaving reader windows and the arc palette draggable while it is open.
/// 菜单项:复制 / 查询(系统词典)/ 翻译(宿主回调,系统翻译面板)/ 搜索网页 / 共享。
final class SelectionMenuController: NSObject {

    weak var host: UIView?
    /// 当前选中文本(由协调器喂入;菜单动作全部经由它取词)
    var textProvider: (() -> String)?
    /// 菜单定位矩形(由协调器喂入;系统把编辑栏放在该矩形上方,避免压住选区)
    var targetRectProvider: ((CGPoint) -> CGRect?)?
    /// 「翻译」动作(宿主负责弹系统翻译面板)
    var onTranslate: ((String) -> Void)?
    /// v0.10.0(Task 2.1):编辑栏「生词本」——加入 / 高亮色 / 取消高亮(宿主实现)
    var onCollectWord: (() -> Void)?
    var onHighlight: ((String) -> Void)?
    var onRemoveHighlight: (() -> Void)?
    /// 当前选词的收录状态(收录与否 + 现有高亮色),菜单构建时取一次
    var vocabStateProvider: (() -> (collected: Bool, colorName: String?))?
    var customActions: (() -> [UIMenuElement])?

    private(set) var isPresented = false
    private var toolbar: UIVisualEffectView?
    private var sourcePoint = CGPoint.zero
    private var preferredArrow: UIEditMenuArrowDirection?
    func containsToolbar(_ view:UIView?) -> Bool {
        guard let view,let toolbar else { return false }
        return view === toolbar || view.isDescendant(of:toolbar)
    }

    func install(on view: UIView) {
        host = view
    }

    /// 弹出菜单。arrowDirection 为方向提示(v0.6.10):菜单在锚点**上方**时箭头朝下(.down)、
    /// 下方时朝上(.up);nil = 不设置(等价系统默认 .automatic)。
    func present(at point: CGPoint, arrowDirection: UIEditMenuArrowDirection? = nil) {
        guard let host else { return }
        dismiss()
        sourcePoint = point; preferredArrow = arrowDirection
        let surface = UIVisualEffectView(effect:UIBlurEffect(style:.systemMaterial))
        surface.layer.cornerRadius = 16; surface.clipsToBounds = true
        surface.accessibilityIdentifier = "selection-edit-bar"
        let scroll = UIScrollView(); scroll.showsHorizontalScrollIndicator = false
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 2
        let actions = menuActions(at:point).children
        // All original actions stay available; nested menus open only when
        // explicitly requested, never as a touch-blocking presentation shell.
        for element in actions {
            let button: UIButton
            if let action = element as? UIAction {
                button = UIButton(type:.system,primaryAction:action)
            } else if let menu = element as? UIMenu {
                button = UIButton(type:.system)
                button.setTitle(menu.title,for:.normal)
                button.menu = menu; button.showsMenuAsPrimaryAction = true
            } else { continue }
            button.titleLabel?.font = .preferredFont(forTextStyle:.subheadline)
            button.tintColor = UIColor(DS.accent)
            button.setContentHuggingPriority(.required,for:.horizontal)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant:64).isActive = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive = true
            row.addArrangedSubview(button)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row); surface.contentView.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo:surface.contentView.leadingAnchor,constant:6),
            scroll.trailingAnchor.constraint(equalTo:surface.contentView.trailingAnchor,constant:-6),
            scroll.topAnchor.constraint(equalTo:surface.contentView.topAnchor,constant:4),
            scroll.bottomAnchor.constraint(equalTo:surface.contentView.bottomAnchor,constant:-4),
            row.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo:scroll.frameLayoutGuide.heightAnchor)
        ])
        host.addSubview(surface); toolbar = surface; isPresented = true
        updatePosition(animated:false)
    }

    /// 点选区:已弹出则收起、未弹出则呼出(选区不动)。
    func toggle(at point: CGPoint, arrowDirection: UIEditMenuArrowDirection? = nil) {
        if isPresented { dismiss() } else { present(at: point, arrowDirection: arrowDirection) }
    }

    func dismiss() {
        guard isPresented else { return }
        toolbar?.removeFromSuperview(); toolbar = nil
        isPresented = false
    }

    /// 菜单已显示时,内容/布局变化(滚动、缩放、旋转)后同步位置——
    /// 系统会重新调用 `editMenuInteraction(_:targetRectFor:)`,把菜单贴回新的包络矩形(v0.6.10)。
    func updatePosition(animated: Bool) {
        guard isPresented else { return }
        guard let host,let toolbar else { return }
        let target = targetRectProvider?(sourcePoint) ?? CGRect(origin:sourcePoint,size:.zero)
        let visible = host.bounds.inset(by:host.safeAreaInsets).insetBy(dx:8,dy:8)
        let height = max(52,UIFont.preferredFont(forTextStyle:.subheadline).lineHeight+24)
        let width = min(430,visible.width)
        let above = target.minY-height-8
        let y = preferredArrow == .up || above < visible.minY ? target.maxY+8 : above
        toolbar.frame = CGRect(x:min(max(target.midX-width/2,visible.minX),visible.maxX-width),
            y:min(max(y,visible.minY),visible.maxY-height),width:width,height:height)
    }

    // MARK: - 菜单动作实现

    private func currentText() -> String {
        textProvider?() ?? ""
    }

    private func topViewController() -> UIViewController? {
        var vc = host?.window?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }

    /// 系统词典「查询」
    private func presentLookup(term: String) {
        guard let host, let top = topViewController() else { return }
        if UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: term) {
            top.present(UIReferenceLibraryViewController(term: term), animated: true)
            DiagLog.log("lookup presented")
        } else {
            let alert = UIAlertController(title: "未找到词条", message: "系统词典中没有「\(term)」的释义。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            top.present(alert, animated: true)
            DiagLog.log("lookup: no definition")
        }
        _ = host
    }

    /// 系统分享面板(iPad 需要 popover 锚点)
    private func presentShare(text: String, sourcePoint: CGPoint) {
        guard let host, let top = topViewController() else {
            DiagLog.log("share: no host")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            if let pop = vc.popoverPresentationController {
                pop.sourceView = host
                pop.sourceRect = CGRect(x: sourcePoint.x, y: sourcePoint.y, width: 1, height: 1)
            }
            top.present(vc, animated: true)
            DiagLog.log("share presented")
        }
    }
}

extension SelectionMenuController {
    private func menuActions(at sourcePoint:CGPoint) -> UIMenu {
        if let customActions { return UIMenu(children:customActions()) }

        let copy = UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            let value = self?.currentText() ?? ""
            guard !value.isEmpty else { return }
            UIPasteboard.general.string = value
        }

        let lookup = UIAction(title: "查询", image: UIImage(systemName: "book")) { [weak self] _ in
            guard let self else { return }
            let text = self.currentText()
            guard !text.isEmpty else { return }
            let term = text.split(separator: " ").first.map(String.init) ?? text
            self.presentLookup(term: term)
        }

        let translate = UIAction(title: "翻译", image: UIImage(systemName: "translate")) { [weak self] _ in
            guard let self else { return }
            let text = self.currentText()
            guard !text.isEmpty else { return }
            self.onTranslate?(text)
        }

        let webSearch = UIAction(title: "搜索网页", image: UIImage(systemName: "globe")) { [weak self] _ in
            let query = (self?.currentText() ?? "").replacingOccurrences(of: "\n", with: " ")
            guard !query.isEmpty,
                  let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://www.bing.com/search?q=" + encoded) else { return }
            UIApplication.shared.open(url)
            DiagLog.log("web search")
        }

        let share = UIAction(title: "共享", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self else { return }
            self.presentShare(text: self.currentText(), sourcePoint: sourcePoint)
        }

        // v0.10.0(Task 2.1):「生词本」子菜单——加入 / 高亮(4 色带勾选)/ 取消高亮
        let state = vocabStateProvider?() ?? (collected: false, colorName: nil)
        let collect = UIAction(
            title: state.collected ? "已收录" : "加入生词本",
            image: UIImage(systemName: state.collected ? "checkmark.circle" : "plus.circle")
        ) { [weak self] _ in
            guard !state.collected else { return }
            self?.onCollectWord?()
        }
        if state.collected { collect.attributes.insert(.disabled) }

        let colorNames: [(String, String)] = [("蓝", "blue"), ("橙", "orange"), ("绿", "green"), ("粉", "pink")]
        let colorActions: [UIAction] = colorNames.map { pair in
            let action = UIAction(title: pair.0) { [weak self] _ in
                self?.onHighlight?(pair.1)
            }
            action.state = (state.colorName == pair.1) ? .on : .off
            return action
        }
        let highlightMenu = UIMenu(
            title: "高亮",
            image: UIImage(systemName: "highlighter"),
            children: colorActions
        )
        let removeHighlight = UIAction(title: "取消高亮", image: UIImage(systemName: "eraser")) { [weak self] _ in
            self?.onRemoveHighlight?()
        }
        if state.colorName == nil { removeHighlight.attributes.insert(.disabled) }

        let vocabMenu = UIMenu(
            title: "生词本",
            image: UIImage(systemName: "text.book.closed"),
            children: [collect, highlightMenu, removeHighlight]
        )

        return UIMenu(children: [copy, lookup, translate, vocabMenu, webSearch, share])
    }
}
