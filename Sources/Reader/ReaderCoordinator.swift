import UIKit
import PDFKit

/// 取词交互协调器(v0.2.5)。
///
/// - 手指:PDFView 原生选择(监听 .PDFViewSelectionChanged)。
/// - Pencil:让位于原生(手势延后 0.75s;检测到"原生驱动的非空选择变化"即让位);
///   原生未接管时走自定义路径,并在手势结束时**主动弹出我们自己的编辑菜单**(复制),
///   不再依赖系统概率性弹菜单。
/// - 取词/扩展:纯点坐标 API(selectionForWord / selectionForLine / selection(from:to:))。
/// - 防护:选区合法性校验(非法巨型选区拒绝)/ 设置选区后恢复滚动位置(防"跳最后一页")/
///   差量高亮 / 自适应节流。
/// - **诊断日志**:关键路径与耗时写入 Documents/diagnostics.log,便于定位真机卡顿。
final class ReaderCoordinator: NSObject {
    weak var pdfView: PDFView?
    var onPageChanged: (Int) -> Void
    var onSelectionInfo: ((SelectionInfo?) -> Void)

    private var tempAnnotations: [String: (page: PDFPage, annotation: PDFAnnotation)] = [:]
    private var tempRects: [(page: PDFPage, rect: CGRect)] = []
    private var suppressSelectionNotification = false
    private var lastAppliedSelectionKey: String?
    private var observers: [NSObjectProtocol] = []

    // Pencil 让位逻辑
    private var lastNativeSelectionChangeTime: CFAbsoluteTime = 0
    private var lastOwnSelectionActionTime: CFAbsoluteTime = 0
    private var yieldedToNative = false
    private var lastAppliedCharCount = 0

    // 自定义编辑菜单(用于自定义路径)
    private var editMenuInteraction: UIEditMenuInteraction?

    private struct PencilDrag {
        var page: PDFPage
        var anchorPoint: CGPoint
        var anchorWord: PDFSelection
        var lastPoint: CGPoint
    }
    private var pencilDrag: PencilDrag?

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
    }

    func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func pageDidChange() {
        guard let pdfView, let page = pdfView.currentPage else { return }
        let index = pdfView.document?.index(for: page) ?? 0
        onPageChanged(index)
    }

    // MARK: - 手势

    func installGestures(on view: PDFView) {
        let pencilSelect = UILongPressGestureRecognizer(target: self, action: #selector(handlePencilLongPress(_:)))
        pencilSelect.minimumPressDuration = 0.75 // 晚于原生(约 0.5s):让原生优先
        pencilSelect.allowableMovement = 14
        pencilSelect.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        view.addGestureRecognizer(pencilSelect)

        let menuInteraction = UIEditMenuInteraction(delegate: self)
        view.addInteraction(menuInteraction)
        editMenuInteraction = menuInteraction

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    @objc private func handlePencilLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let pdfView else { return }
        let viewPoint = gesture.location(in: pdfView)

        switch gesture.state {
        case .began:
            yieldedToNative = false
            if CFAbsoluteTimeGetCurrent() - lastNativeSelectionChangeTime < 0.7 {
                yieldedToNative = true
                DiagLog.log("pencil.began: gave way to native")
                return
            }
            guard let hit = pageHit(viewPoint) else {
                DiagLog.log("pencil.began: no page at point")
                return
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            let word = hit.page.selectionForWord(at: hit.point) ?? hit.page.selectionForLine(at: hit.point)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            guard let word, Self.isSane(word, maxPages: 1, maxChars: 300) else {
                DiagLog.log(String(format: "pencil.began: no word (%.0fms)", ms))
                return
            }
            let snippet = String((word.string ?? "").prefix(20))
            DiagLog.log(String(format: "pencil.began: word=「%@」 len=%d pickup=%.0fms", snippet, word.string?.count ?? 0, ms))
            pencilDrag = PencilDrag(page: hit.page, anchorPoint: hit.point, anchorWord: word, lastPoint: hit.point)
            setCurrentSelection(word)

        case .changed:
            guard !yieldedToNative else { return }
            guard let drag = pencilDrag,
                  let hit = pageHit(viewPoint), hit.page === drag.page else { return }
            let step: CGFloat = lastAppliedCharCount > 800 ? 8 : 3
            let dx = hit.point.x - drag.lastPoint.x
            let dy = hit.point.y - drag.lastPoint.y
            guard dx * dx + dy * dy >= step * step else { return }
            pencilDrag?.lastPoint = hit.point
            let t0 = CFAbsoluteTimeGetCurrent()
            if let selection = selectionBetween(drag, and: hit.point) {
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                if ms > 60 {
                    DiagLog.log(String(format: "pencil.changed: build selection slow %.0fms", ms))
                }
                setCurrentSelection(selection)
            }

        case .ended, .cancelled, .failed:
            let ours = pencilDrag != nil
            let isEnded = gesture.state == .ended
            yieldedToNative = false
            pencilDrag = nil
            if ours, isEnded, let pdfView,
               let selText = pdfView.currentSelection?.string, !selText.isEmpty {
                // 自定义路径:主动弹出我们自己的编辑菜单(不依赖系统)
                let point = gesture.location(in: pdfView)
                editMenuInteraction?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
                DiagLog.log("pencil.ended: presented own menu")
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
                // 点在已加亮的词上:M1 保持高亮;M2 起在此打开/切换词卡
                return
            }
        }
        clearSelectionEverything()
    }

    // MARK: - 选择 / 高亮

    private func selectionDidChange() {
        guard !suppressSelectionNotification, let pdfView else { return }

        let selection = pdfView.currentSelection
        let text = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // 记录"原生驱动的非空选择变化"(用于 Pencil 让位判断;50ms 窗口滤掉我们自己的设置)
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastOwnSelectionActionTime > 0.05, !text.isEmpty {
            lastNativeSelectionChangeTime = now
        }

        if let selection, !selection.pages.isEmpty, !text.isEmpty {
            guard Self.isSane(selection, maxPages: 5, maxChars: 10_000) else {
                DiagLog.log("selChanged: rejected pages=\(selection.pages.count) len=\(text.count)")
                lastAppliedSelectionKey = nil
                lastAppliedCharCount = 0
                clearTempHighlight()
                onSelectionInfo(nil)
                return
            }
            let pageIndex = selection.pages.first.flatMap { pdfView.document?.index(for: $0) } ?? -1
            let key = "\(pageIndex)|\(text.count)|\(text.hashValue)"
            guard key != lastAppliedSelectionKey else { return }
            lastAppliedSelectionKey = key
            lastAppliedCharCount = text.count
            updateTempHighlight(for: selection)
            let display = text.count > 400 ? String(text.prefix(400)) + "…" : text
            onSelectionInfo(SelectionInfo(text: display, wordCount: WordPicker.countWords(in: text)))
        } else {
            lastAppliedSelectionKey = nil
            lastAppliedCharCount = 0
            clearTempHighlight()
            onSelectionInfo(nil)
        }
    }

    /// 差量更新临时高亮:只移除消失的行、只新增出现的行。
    private func updateTempHighlight(for selection: PDFSelection) {
        let t0 = CFAbsoluteTimeGetCurrent()
        var desired: [String: (page: PDFPage, rect: CGRect)] = [:]
        for page in selection.pages {
            let lineSelections = selection.selectionsByLine()
                .prefix(Self.maxHighlightLines)
                .filter { $0.pages.first === page }
            var rects = lineSelections.map { $0.bounds(for: page) }
            if rects.isEmpty { rects = [selection.bounds(for: page)] }

            for rect in rects where Self.isValid(rect) {
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
        if ms > 80 {
            DiagLog.log(String(format: "highlight update slow: %.0fms lines=%d", ms, desired.count))
        }
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
        suppressSelectionNotification = true
        pdfView.currentSelection = nil
        pdfView.clearSelection()
        suppressSelectionNotification = false
        lastAppliedSelectionKey = nil
        lastAppliedCharCount = 0
        clearTempHighlight()
        onSelectionInfo(nil)
    }

    // MARK: - Pencil 拖选计算(纯点坐标)

    private func selectionBetween(_ drag: PencilDrag, and current: CGPoint) -> PDFSelection? {
        let page = drag.page
        let anchorRect = drag.anchorWord.bounds(for: page)

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
        return page.selection(from: drag.anchorPoint, to: current)
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
        if let scroll = view as? UIScrollView { return scroll }
        if let scroll = view.documentView?.superview as? UIScrollView { return scroll }
        return view.subviews.compactMap { $0 as? UIScrollView }.first
    }

    /// 设置选择;若 PDFKit 因异常数据出现跳页滚动,则恢复原滚动位置(防"跳最后一页")。
    private func setCurrentSelection(_ selection: PDFSelection?) {
        guard let pdfView, let selection, let text = selection.string, !text.isEmpty else { return }
        guard Self.isSane(selection, maxPages: 1, maxChars: 6_000) else {
            DiagLog.log("setSelection rejected pages=\(selection.pages.count) len=\(text.count)")
            return
        }
        lastOwnSelectionActionTime = CFAbsoluteTimeGetCurrent()

        let t0 = CFAbsoluteTimeGetCurrent()
        let scroll = pdfScrollView(pdfView)
        let offset = scroll?.contentOffset
        pdfView.setCurrentSelection(selection, animate: false)

        if let scroll, let offset {
            let current = scroll.contentOffset
            if abs(current.y - offset.y) > 1 || abs(current.x - offset.x) > 1 {
                scroll.setContentOffset(offset, animated: false)
                DiagLog.log(String(format: "scroll restored y:%.0f -> y:%.0f", offset.y, current.y))
            }
        }

        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if ms > 80 {
            DiagLog.log(String(format: "setCurrentSelection slow: %.0fms len=%d", ms, text.count))
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
        let copy = UIAction(title: "复制") { [weak self] _ in
            guard let text = self?.pdfView?.currentSelection?.string, !text.isEmpty else { return }
            UIPasteboard.general.string = text
        }
        return UIMenu(children: [copy])
    }
}
