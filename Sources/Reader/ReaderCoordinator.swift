import UIKit
import PDFKit
import AVFoundation

/// 取词交互协调器(v0.3.0)。
///
/// 架构:**手指与 Pencil 统一走自有取词管线**,全程**不设置 PDFView 的选区状态**
/// (`setCurrentSelection` 已移除),黄高亮/信息条/菜单全部由自有状态驱动,
/// 从根上消除"PDFKit 因异常文档几何自动滚动/跳页"的触发面。
/// 同时停用 PDFKit 内置选择手势(长按/双击),保留滚动、缩放、链接单击。
///
/// v0.3.0:
/// - 长按拖动期间**冻结滚动**(pan 手势临时禁用),拖动=稳定扩选,不再被滚动抢走;
/// - 编辑菜单补全:复制 / 翻译(translationPresentation)/ 朗读(美音)/ 共享(系统分享)。
final class ReaderCoordinator: NSObject {
    weak var pdfView: PDFView?
    var onPageChanged: (Int) -> Void
    var onSelectionInfo: ((SelectionInfo?) -> Void)
    /// 「翻译」菜单项的回调(由 SwiftUI 层弹出系统翻译面板)
    var onTranslate: ((String) -> Void)?
    /// 当前文档标识(sha 前 8 位,取自文件名),仅用于日志
    var docLabel = ""

    private var tempAnnotations: [String: (page: PDFPage, annotation: PDFAnnotation)] = [:]
    private var tempRects: [(page: PDFPage, rect: CGRect)] = []
    private var suppressSelectionNotification = false
    private var lastAppliedSelectionKey: String?
    private var observers: [NSObjectProtocol] = []

    // 手势状态
    private weak var fingerSelectRef: UILongPressGestureRecognizer?
    private weak var pencilSelectRef: UILongPressGestureRecognizer?
    private var lastOwnSelectionActionTime: CFAbsoluteTime = 0
    private var lastAnySelectionChangeTime: CFAbsoluteTime = 0
    private var lastAppliedCharCount = 0
    private var suppressLogged = false
    /// 自有路线最近一次选中的文本(菜单各项与手势结束判断用)
    private var lastOurSelectionText = ""

    // 拖动期间冻结滚动
    private weak var frozenScrollView: UIScrollView?
    private var scrollWasEnabled = false

    // 朗读
    private let speaker = AVSpeechSynthesizer()

    // 防跳页
    private var lastGoodPage: (index: Int, time: CFAbsoluteTime) = (0, 0)
    private var jumpGuardUntil: CFAbsoluteTime = 0

    // 自定义编辑菜单
    private var editMenuInteraction: UIEditMenuInteraction?

    private struct DragState {
        var page: PDFPage
        var anchorPoint: CGPoint
        var anchorWord: PDFSelection
        var lastPoint: CGPoint
    }
    private var drag: DragState?

    private static let maxHighlightLines = 150

    init(
        onPageChanged: @escaping (Int) -> Void,
        onSelectionInfo: @escaping (SelectionInfo?) -> Void
    ) {
        self.onPageChanged = onPageChanged
        self.onSelectionInfo = onSelectionInfo
    }

    deinit {
        removeObservers()
    }

    // MARK: - 通知

    func installObservers() {
        guard let pdfView else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.pageDidChange()
        })
        observers.append(nc.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.selectionDidChange()
        })
        observers.append(nc.addObserver(forName: .PDFViewDocumentChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.documentDidChange()
        })
    }

    func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// 文档加载完成后调用:记录信息 + 压制内置手势(PDFKit 可能在加载后重建内部手势,延时再压)
    func documentDidLoad(_ document: PDFDocument) {
        DiagLog.log("doc: \(document.pageCount) pages sha=\(docLabel.prefix(8))")
        suppressNativeSelection(in: pdfView)
        for delay in [0.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let view = self.pdfView else { return }
                self.suppressNativeSelection(in: view)
            }
        }
    }

    private func documentDidChange() {
        guard let pdfView else { return }
        if let doc = pdfView.document {
            DiagLog.log("docChanged: \(doc.pageCount) pages")
        }
        jumpGuardUntil = 0
        let index = pdfView.document.flatMap { doc in pdfView.currentPage.map { doc.index(for: $0) } } ?? 0
        lastGoodPage = (index, CFAbsoluteTimeGetCurrent())
        freezeScrolling(false)
        suppressNativeSelection(in: pdfView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let view = self.pdfView else { return }
            self.suppressNativeSelection(in: view)
        }
    }

    private func pageDidChange() {
        guard let pdfView, let page = pdfView.currentPage else { return }
        let index = pdfView.document?.index(for: page) ?? 0
        let now = CFAbsoluteTimeGetCurrent()
        DiagLog.log("page->\(index)")

        // 防跳页:紧跟选区变化(0.8s 内)的跨页"前跳"判为异常,拉回上次稳定页
        if now > jumpGuardUntil,
           now - lastAnySelectionChangeTime < 0.8,
           abs(index - lastGoodPage.index) > 5,
           index > lastGoodPage.index {
            DiagLog.log("JUMP suspected \(lastGoodPage.index)->\(index); restore")
            jumpGuardUntil = now + 1.0
            if let target = pdfView.document?.page(at: lastGoodPage.index) {
                pdfView.go(to: target)
            }
            return
        }

        lastGoodPage = (index, now)
        suppressNativeSelection(in: pdfView)
        onPageChanged(index)
    }

    // MARK: - 手势

    func installGestures(on view: PDFView) {
        // 手指长按选词(0.5s)
        let fingerSelect = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        fingerSelect.minimumPressDuration = 0.5
        fingerSelect.allowableMovement = 14
        fingerSelect.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.addGestureRecognizer(fingerSelect)
        fingerSelectRef = fingerSelect

        // Pencil 长按选词(0.45s)
        let pencilSelect = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        pencilSelect.minimumPressDuration = 0.45
        pencilSelect.allowableMovement = 14
        pencilSelect.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        view.addGestureRecognizer(pencilSelect)
        pencilSelectRef = pencilSelect

        // 自绘编辑菜单
        let menuInteraction = UIEditMenuInteraction(delegate: self)
        view.addInteraction(menuInteraction)
        editMenuInteraction = menuInteraction

        // 单击:点在已加亮词上保持,点空白清除;须等长按失败(避免与长按双击发)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]
        tap.delegate = self
        tap.require(toFail: fingerSelect)
        tap.require(toFail: pencilSelect)
        view.addGestureRecognizer(tap)

        suppressNativeSelection(in: view)
    }

    /// 停用 PDFKit 内置的选择手势(长按 / 双击)。
    /// 这些机制在异常文本层文档上会触发"跳最后一页 + 卡死",且与自有管线冲突;
    /// 保留滚动、缩放与链接单击。
    func suppressNativeSelection(in view: UIView?) {
        guard let view else { return }
        var disabled = 0
        func walk(_ v: UIView) {
            for gr in v.gestureRecognizers ?? [] {
                if gr === fingerSelectRef || gr === pencilSelectRef { continue }
                let isLongPress = gr is UILongPressGestureRecognizer
                let isMultiTap = (gr as? UITapGestureRecognizer).map { $0.numberOfTapsRequired >= 2 } ?? false
                if (isLongPress || isMultiTap), gr.isEnabled {
                    gr.isEnabled = false
                    disabled += 1
                }
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        if disabled > 0, !suppressLogged {
            suppressLogged = true
            DiagLog.log("suppressNative: disabled \(disabled) recognizers")
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let pdfView else { return }
        let kind = Self.kind(of: gesture)
        let viewPoint = gesture.location(in: pdfView)

        switch gesture.state {
        case .began:
            guard let hit = pageHit(viewPoint) else {
                DiagLog.log("press.began(\(kind)): no page")
                return
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            let word = hit.page.selectionForWord(at: hit.point) ?? hit.page.selectionForLine(at: hit.point)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            guard let word, Self.isSane(word, maxPages: 1, maxChars: 300) else {
                DiagLog.log(String(format: "press.began(%@): no word (%.0fms)", kind, ms))
                return
            }
            let snippet = Self.logSnippet(word.string ?? "")
            DiagLog.log(String(format: "press.began(%@): word=「%@」 len=%d pickup=%.0fms", kind, snippet, word.string?.count ?? 0, ms))
            drag = DragState(page: hit.page, anchorPoint: hit.point, anchorWord: word, lastPoint: hit.point)
            freezeScrolling(true) // 拖动期间页面不再滚动,拖动=稳定扩选
            applyOurSelection(word)

        case .changed:
            guard let dragState = drag,
                  let hit = pageHit(viewPoint), hit.page === dragState.page else { return }
            let step: CGFloat = lastAppliedCharCount > 800 ? 8 : 3
            let dx = hit.point.x - dragState.lastPoint.x
            let dy = hit.point.y - dragState.lastPoint.y
            guard dx * dx + dy * dy >= step * step else { return }
            drag?.lastPoint = hit.point
            let t0 = CFAbsoluteTimeGetCurrent()
            if let selection = selectionBetween(dragState, and: hit.point) {
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                if ms > 60 {
                    DiagLog.log(String(format: "press.changed slow %.0fms", ms))
                }
                applyOurSelection(selection)
            }

        case .ended, .cancelled, .failed:
            let hadDrag = drag != nil
            let isEnded = gesture.state == .ended
            drag = nil
            freezeScrolling(false)
            DiagLog.log("press.end(\(kind)) ours=\(hadDrag) ended=\(isEnded)")
            if hadDrag, isEnded, !lastOurSelectionText.isEmpty {
                let point = gesture.location(in: pdfView)
                editMenuInteraction?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
                DiagLog.log("menu presented")
            }

        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let pdfView else { return }
        let point = gesture.location(in: pdfView)

        if let page = pdfView.page(for: point, nearest: false) {
            let pagePoint = pdfView.convert(point, to: page)
            let hitRect = CGRect(x: pagePoint.x - 2, y: pagePoint.y - 2, width: 4, height: 4)
            let onHighlight = tempRects.contains { $0.page === page && $0.rect.intersects(hitRect) }
            if onHighlight {
                DiagLog.log("tap: onHighlight")
                // 点在已加亮的词上:M1 保持高亮;M2 起在此打开/切换词卡
                return
            }
        }
        DiagLog.log("tap: clear")
        clearSelectionEverything()
    }

    // MARK: - 选择 / 高亮

    /// 自有路线选中:只更新黄高亮与信息条,**不触碰 PDFView 的选区状态**。
    private func applyOurSelection(_ selection: PDFSelection) {
        guard let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lastOwnSelectionActionTime = now
        lastAnySelectionChangeTime = now
        lastOurSelectionText = text
        applySelection(selection, text: text, src: "own")
    }

    private func selectionDidChange() {
        guard !suppressSelectionNotification, let pdfView else { return }

        let selection = pdfView.currentSelection
        let text = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let now = CFAbsoluteTimeGetCurrent()
        let isOurs = now - lastOwnSelectionActionTime <= 0.05
        lastAnySelectionChangeTime = now
        if !isOurs, !text.isEmpty {
            // 内置手势没能压住(被重建):再次压制,并留下证据
            DiagLog.log("native sel detected; re-suppress")
            suppressNativeSelection(in: pdfView)
        }
        DiagLog.log("selChange(\(isOurs ? "own" : "native")): len=\(text.count) pages=\(selection?.pages.count ?? 0) 「\(Self.logSnippet(text))」")

        if let selection, !selection.pages.isEmpty, !text.isEmpty {
            applySelection(selection, text: text, src: isOurs ? "own" : "native")
        } else {
            lastAppliedSelectionKey = nil
            lastAppliedCharCount = 0
            lastOurSelectionText = ""
            clearTempHighlight()
            onSelectionInfo(nil)
        }
    }

    private func applySelection(_ selection: PDFSelection, text: String, src: String) {
        guard Self.isSane(selection, maxPages: 1, maxChars: 6_000) else {
            DiagLog.log("applySelection rejected(\(src)): pages=\(selection.pages.count) len=\(text.count)")
            lastAppliedSelectionKey = nil
            lastAppliedCharCount = 0
            clearTempHighlight()
            onSelectionInfo(nil)
            return
        }
        let pageIndex = selection.pages.first.flatMap { pdfView?.document?.index(for: $0) } ?? -1
        let key = "\(pageIndex)|\(text.count)|\(text.hashValue)"
        guard key != lastAppliedSelectionKey else { return }
        lastAppliedSelectionKey = key
        lastAppliedCharCount = text.count
        updateTempHighlight(for: selection)
        let display = text.count > 400 ? String(text.prefix(400)) + "…" : text
        onSelectionInfo(SelectionInfo(text: display, wordCount: WordPicker.countWords(in: text)))
    }

    /// 差量更新临时高亮:只移除消失的行、只新增出现的行;越界矩形拒绝并计数。
    private func updateTempHighlight(for selection: PDFSelection) {
        let t0 = CFAbsoluteTimeGetCurrent()
        var desired: [String: (page: PDFPage, rect: CGRect)] = [:]
        var rejected = 0
        for page in selection.pages {
            let pageBounds = page.bounds(for: pdfView?.displayBox ?? .cropBox)
            let lineSelections = selection.selectionsByLine()
                .prefix(Self.maxHighlightLines)
                .filter { $0.pages.first === page }
            var rects = lineSelections.map { $0.bounds(for: page) }
            if rects.isEmpty { rects = [selection.bounds(for: page)] }

            for rect in rects {
                guard Self.isValid(rect) else { rejected += 1; continue }
                guard rect.intersects(pageBounds.insetBy(dx: -24, dy: -24)) else { rejected += 1; continue }
                desired[annotationKey(page, rect)] = (page, rect)
            }
        }

        let staleKeys = tempAnnotations.keys.filter { desired[$0] == nil }
        for key in staleKeys {
            if let entry = tempAnnotations.removeValue(forKey: key) {
                entry.page.removeAnnotation(entry.annotation)
            }
        }

        for (key, entry) in desired where tempAnnotations[key] == nil {
            let annotation = PDFAnnotation(
                bounds: entry.rect.insetBy(dx: -1, dy: -1),
                forType: .highlight,
                withProperties: nil
            )
            annotation.color = UIColor.systemYellow.withAlphaComponent(0.45)
            entry.page.addAnnotation(annotation)
            tempAnnotations[key] = (entry.page, annotation)
        }

        tempRects = desired.values.map { ($0.page, $0.rect) }

        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        DiagLog.log(String(format: "hl: lines=%d ms=%.0f rej=%d", desired.count, ms, rejected))
    }

    func clearTempHighlight() {
        for (_, entry) in tempAnnotations {
            entry.page.removeAnnotation(entry.annotation)
        }
        tempAnnotations.removeAll()
        tempRects.removeAll()
    }

    private func clearSelectionEverything() {
        guard let pdfView else { return }
        DiagLog.log("clearSelection")
        freezeScrolling(false)
        suppressSelectionNotification = true
        pdfView.currentSelection = nil
        pdfView.clearSelection()
        suppressSelectionNotification = false
        lastAppliedSelectionKey = nil
        lastAppliedCharCount = 0
        lastOurSelectionText = ""
        clearTempHighlight()
        onSelectionInfo(nil)
    }

    // MARK: - 拖选计算(纯点坐标)

    private func selectionBetween(_ dragState: DragState, and current: CGPoint) -> PDFSelection? {
        let page = dragState.page
        let anchorRect = dragState.anchorWord.bounds(for: page)

        if let currentWord = page.selectionForWord(at: current) {
            let currentRect = currentWord.bounds(for: page)
            if Self.isValid(anchorRect), Self.isValid(currentRect) {
                let leftPoint = CGPoint(x: anchorRect.minX + 0.6, y: anchorRect.midY)
                let rightPoint = CGPoint(x: currentRect.maxX - 0.6, y: currentRect.midY)
                let (from, to) = Self.ordered(leftPoint, rightPoint)
                if let selection = page.selection(from: from, to: to),
                   Self.isSane(selection, maxPages: 2, maxChars: 6_000),
                   let text = selection.string, !text.isEmpty {
                    return selection
                }
            }
        }
        return page.selection(from: dragState.anchorPoint, to: current)
    }

    /// 页面坐标 y 向上:先按行(容差 6pt),同行按 x 排序,保证 from 在 to 之前。
    private static func ordered(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
        if abs(a.y - b.y) < 6 { return a.x <= b.x ? (a, b) : (b, a) }
        return a.y > b.y ? (a, b) : (b, a)
    }

    private static func isSane(_ selection: PDFSelection, maxPages: Int, maxChars: Int) -> Bool {
        guard !selection.pages.isEmpty, selection.pages.count <= maxPages else { return false }
        guard let text = selection.string, !text.isEmpty, text.count <= maxChars else { return false }
        return true
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.width < 10_000 && rect.height < 10_000
    }

    private static func kind(of gesture: UILongPressGestureRecognizer) -> String {
        if let t = gesture.allowedTouchTypes.first, t.intValue == Int32(UITouch.TouchType.pencil.rawValue) {
            return "pencil"
        }
        return "finger"
    }

    private static func logSnippet(_ s: String) -> String {
        String(s.replacingOccurrences(of: "\n", with: " ").prefix(16))
    }

    // MARK: - 工具

    private func annotationKey(_ page: PDFPage, _ rect: CGRect) -> String {
        let r = String(format: "%.1f_%.1f_%.1f_%.1f", rect.minX, rect.minY, rect.width, rect.height)
        return "\(ObjectIdentifier(page).hashValue)_\(r)"
    }

    private func pageHit(_ viewPoint: CGPoint) -> (page: PDFPage, point: CGPoint)? {
        guard let pdfView else { return nil }
        if let page = pdfView.page(for: viewPoint, nearest: false) {
            return (page, pdfView.convert(viewPoint, to: page))
        }
        guard let page = pdfView.page(for: viewPoint, nearest: true) else { return nil }
        let point = pdfView.convert(viewPoint, to: page)
        let bounds = page.bounds(for: pdfView.displayBox)
        guard bounds.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        return (page, point)
    }

    private func pdfScrollView(_ view: PDFView) -> UIScrollView? {
        if let scroll = view.documentView?.superview as? UIScrollView { return scroll }
        return Self.findScrollView(in: view)
    }

    private static func findScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for subview in view.subviews {
            if let scroll = findScrollView(in: subview) { return scroll }
        }
        return nil
    }

    /// 长按拖动期间冻结/恢复页面滚动(与原生选择手感一致,避免拖动被滚动抢走)。
    private func freezeScrolling(_ freeze: Bool) {
        guard let pdfView else { return }
        if freeze {
            if frozenScrollView == nil, let sv = pdfScrollView(pdfView) {
                scrollWasEnabled = sv.panGestureRecognizer.isEnabled
                if scrollWasEnabled {
                    sv.panGestureRecognizer.isEnabled = false
                }
                frozenScrollView = sv
                DiagLog.log("scroll frozen")
            }
        } else {
            if let sv = frozenScrollView, scrollWasEnabled {
                sv.panGestureRecognizer.isEnabled = true
            }
            frozenScrollView = nil
        }
    }

    private static func topViewController(from view: UIView) -> UIViewController? {
        var vc = view.window?.rootViewController
        while let presented = vc?.presentedViewController {
            vc = presented
        }
        return vc
    }

    private func presentShare(text: String, sourcePoint: CGPoint) {
        guard let pdfView, let host = Self.topViewController(from: pdfView) else {
            DiagLog.log("share: no host")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            if let pop = vc.popoverPresentationController {
                pop.sourceView = pdfView
                pop.sourceRect = CGRect(x: sourcePoint.x, y: sourcePoint.y, width: 1, height: 1)
            }
            host.present(vc, animated: true)
            DiagLog.log("share presented")
        }
    }
}

extension ReaderCoordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

extension ReaderCoordinator: UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        let text = lastOurSelectionText.isEmpty ? (pdfView?.currentSelection?.string ?? "") : lastOurSelectionText

        let copy = UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            guard let self else { return }
            var value = self.lastOurSelectionText
            if value.isEmpty { value = self.pdfView?.currentSelection?.string ?? "" }
            guard !value.isEmpty else { return }
            UIPasteboard.general.string = value
        }

        let translate = UIAction(title: "翻译", image: UIImage(systemName: "translate")) { [weak self] _ in
            guard let self, !text.isEmpty else { return }
            self.onTranslate?(text)
        }

        let speak = UIAction(title: "朗读", image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in
            guard let self, !text.isEmpty else { return }
            self.speaker.stopSpeaking(at: .immediate)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            self.speaker.speak(utterance)
            DiagLog.log("speak selection")
        }

        let share = UIAction(title: "共享", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self, !text.isEmpty else { return }
            self.presentShare(text: text, sourcePoint: configuration.sourcePoint)
        }

        return UIMenu(children: [copy, translate, speak, share])
    }
}
