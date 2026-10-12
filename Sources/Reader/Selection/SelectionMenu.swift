import UIKit
import PDFKit

/// 编辑菜单封装(UIEditMenuInteraction = 系统原生菜单组件,弹出动画/位置/键盘导航均由系统负责)。
/// 菜单项:复制 / 查询(系统词典)/ 翻译(宿主回调,系统翻译面板)/ 搜索网页 / 共享。
final class SelectionMenuController: NSObject {

    weak var host: UIView?
    /// 当前选中文本(由协调器喂入;菜单动作全部经由它取词)
    var textProvider: (() -> String)?
    /// 菜单定位矩形(由协调器喂入;系统把编辑栏放在该矩形上方,避免压住选区)
    var targetRectProvider: ((CGPoint) -> CGRect?)?
    /// 「翻译」动作(宿主负责弹系统翻译面板)
    var onTranslate: ((String) -> Void)?

    private(set) var isPresented = false
    private var interaction: UIEditMenuInteraction?

    func install(on view: UIView) {
        host = view
        let interaction = UIEditMenuInteraction(delegate: self)
        view.addInteraction(interaction)
        self.interaction = interaction
    }

    func present(at point: CGPoint) {
        guard let interaction else { return }
        interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    /// 点选区:已弹出则收起、未弹出则呼出(选区不动)。
    func toggle(at point: CGPoint) {
        if isPresented { dismiss() } else { present(at: point) }
    }

    func dismiss() {
        guard isPresented else { return }
        interaction?.dismissMenu()
        isPresented = false
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

extension SelectionMenuController: UIEditMenuInteractionDelegate {

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        willPresentMenuFor configuration: UIEditMenuConfiguration,
        animator: UIEditMenuInteractionAnimating
    ) {
        isPresented = true
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: UIEditMenuInteractionAnimating
    ) {
        isPresented = false
    }

    /// 菜单定位:以"选区矩形"为基准——系统会把编辑栏放到矩形**上方**(原生行为),
    /// 而不是像"裸锚点"那样挂在下边(会盖住选区、挡住点词)。
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        if let rect = targetRectProvider?(configuration.sourcePoint) {
            return rect
        }
        let p = configuration.sourcePoint
        return CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {

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
            self.presentShare(text: self.currentText(), sourcePoint: configuration.sourcePoint)
        }

        return UIMenu(children: [copy, lookup, translate, webSearch, share])
    }
}
