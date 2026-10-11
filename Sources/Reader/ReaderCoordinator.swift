import UIKit
import PDFKit

/// 取词交互协调器(v0.2.4)。
///
/// 设计:
/// - 手指:PDFView 原生选择(监听 .PDFViewSelectionChanged)。
/// - Pencil:**让位于原生**。PDFKit 原生选择在 iPadOS 26 可响应 Pencil(含编辑菜单);
///   我们的自定义长按手势延后到 0.75s,且若 0.7s 内检测到"原生驱动的选择变化"就完全让位
///   (修复编辑栏概率性不出现/被顶掉的问题)。原生确实未响应时,我们兜底接管。
/// - 取词/扩展:纯点坐标 API(selectionForWord / selectionForLine / selection(from:to:)),
///   不经字符串索引(规避 iOS 18+ PDFKit 索引回归)。
/// - **选区合法性校验**:异常巨大/跨页过多的选择(内部数据损坏时出现)一律拒绝,
///   不设置不高亮——避免"跳转到最后一页 + 卡死数秒"(由巨型非法选区触发)。
/// - 临时高亮:差量更新;行数先截取再取边界;选区越大节流步进越大。
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
            // 若 0.7s 内有"原生驱动"的选择变化,说明原生已接管这次按压 → 让位
            if CFAbsoluteTimeGetCurrent() - lastNativeSelectionChangeTime < 0.7 {
                yieldedToNative = true
                return
            }
            guard let hit = pageHit(viewPoint),
                  let word = hit.page.selectionForWord(at: hit.point)
                      ?? hit.page.selectionForLine(at: hit.point),
                  Self.isSane(word, maxPages: 1, maxChars: 300) else { return }
            pencilDrag = PencilDrag(page: hit.page, anchorPoint: hit.point, anchorWord: word, lastPoint: hit.point)
            setCurrentSelection(word)

        case .changed:
            guard !yieldedToNative else { return }
            guard let drag = pencilDrag,
                  let hit = pageHit(viewPoint), hit.page === drag.page else { return }
            // 自适应节流:选区越大步进越大(长跨度拖动减负)
            let step: CGFloat = lastAppliedCharCount > 800 ? 8 : 3
            let dx = hit.point.x - drag.lastPoint.x
            let dy = hit.point.y - drag.lastPoint.y
            guard dx * dx + dy * dy >= step * step else { return }
            pencilDrag?.lastPoint = hit.point
            if let selection = selectionBetween(drag, and: hit.point) {
                setCurrentSelection(selection)
            }

        case .ended, .cancelled, .failed:
            yieldedToNative = false
            pencilDrag = nil

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

        // 记录"原生驱动"的选择变化时间(用于 Pencil 让位判断;50ms 窗口滤掉我们自己的设置)
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastOwnSelectionActionTime > 0.05 {
            lastNativeSelectionChangeTime = now
        }

        let selection = pdfView.currentSelection
        let text = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let selection, !selection.pages.isEmpty, !text.isEmpty {
            // 合法性校验:异常选择(内部数据损坏时出现的全文档巨型选区)一律跳过,
            // 避免 PDFKit 滚动到"最后一页"以及 selectionsByLine 展开数千行导致的主线程卡死
            guard Self.isSane(selection, maxPages: 5, maxChars: 10_000) else {
                lastAppliedSelectionKey = nil
                lastAppliedCharCount = 0
                clearTempHighlight()
                onSelectionInfo(nil)
                return
            }
            let pageIndex = selection.pages.first.flatMap { pdfView.document?.index(for: $0) } ?? -1
            let key = "\(pageIndex)|\(text.count)|\(text.hashValue)"
            guard key != lastAppliedSelectionKey else { return } // 内容未变不重建
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
        var desired: [String: (page: PDFPage, rect: CGRect)] = [:]
        for page in selection.pages {
            // 先截取行数上限,再取 bounds(避免在超大选区上展开数千行)
            let lineSelections = selection.selectionsByLine()
                .prefix(Self.maxHighlightLines)
                .filter { $0.pages.first === page }
            var rects = lineSelections.map { $0.bounds(for: page) }
            if rects.isEmpty { rects = [selection.bounds(for: page)] }

            for rect in rects where Self.isValid(rect) {
                desired[annotationKey(page, rect)] = (page, rect)
            }
        }

        // 移除不再需要的
        let staleKeys = tempAnnotations.keys.filter { desired[$0] == nil }
        for key in staleKeys {
            if let entry = tempAnnotations.removeValue(forKey: key) {
                entry.page.removeAnnotation(entry.annotation)
            }
        }

        // 新增缺少的
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
        // 退化:锚点到当前点之间的字符级选择(setCurrentSelection 里还有一次合法性校验)
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
        // 容错:贴近页面边缘时取最近页,但必须落在页内(防止外推产生大偏移)
        guard let page = pdfView.page(for: viewPoint, nearest: true) else { return nil }
        let point = pdfView.convert(viewPoint, to: page)
        let bounds = page.bounds(for: pdfView.displayBox)
        guard bounds.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        return (page, point)
    }

    private func setCurrentSelection(_ selection: PDFSelection?) {
        guard let pdfView, let selection, let text = selection.string, !text.isEmpty else { return }
        guard Self.isSane(selection, maxPages: 2, maxChars: 6_000) else { return }
        lastOwnSelectionActionTime = CFAbsoluteTimeGetCurrent()
        pdfView.setCurrentSelection(selection, animate: false)
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
