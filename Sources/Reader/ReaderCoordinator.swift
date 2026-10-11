import UIKit
import PDFKit

/// 取词交互协调器(v0.2.3)。
///
/// - 手指:依赖 PDFView 原生选择(监听 `.PDFViewSelectionChanged`)。
/// - Pencil:自定义长按/拖选。命中与范围全部走「点坐标」API
///   (`selectionForWord` / `selectionForLine` / `selection(from:to:)`),
///   不经过字符串索引——规避 iOS 18+ PDFKit `characterBounds(at:)`/`page.string`
///   顺序回归导致的"选词位置与笔触偏差 / 拖动跳变"问题。
/// - 临时高亮:差量更新(只增删变化的行注解,不再清空重建),大选区不卡顿。
/// - 点空白清除;Pencil 手势结束后保留原生选择(可用手指手柄继续调整)。
final class ReaderCoordinator: NSObject {
    weak var pdfView: PDFView?
    var onPageChanged: (Int) -> Void
    var onSelectionInfo: ((SelectionInfo?) -> Void)

    private var tempAnnotations: [String: (page: PDFPage, annotation: PDFAnnotation)] = [:]
    private var tempRects: [(page: PDFPage, rect: CGRect)] = []
    private var suppressSelectionNotification = false
    private var lastAppliedSelectionKey: String?
    private var observers: [NSObjectProtocol] = []

    private struct PencilDrag {
        var page: PDFPage
        var anchorPoint: CGPoint
        var anchorWord: PDFSelection
        var lastPoint: CGPoint
    }
    private var pencilDrag: PencilDrag?

    private static let maxHighlightLines = 120

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
        pencilSelect.minimumPressDuration = 0.3
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
            guard let hit = pageHit(viewPoint),
                  let word = hit.page.selectionForWord(at: hit.point)
                      ?? hit.page.selectionForLine(at: hit.point) else { return }
            pencilDrag = PencilDrag(page: hit.page, anchorPoint: hit.point, anchorWord: word, lastPoint: hit.point)
            setCurrentSelection(word)

        case .changed:
            guard let drag = pencilDrag,
                  let hit = pageHit(viewPoint), hit.page === drag.page else { return }
            let dx = hit.point.x - drag.lastPoint.x
            let dy = hit.point.y - drag.lastPoint.y
            guard dx * dx + dy * dy >= 9 else { return } // 移动小于 3pt 不重算(节流防卡顿)
            pencilDrag?.lastPoint = hit.point
            if let selection = selectionBetween(drag, and: hit.point) {
                setCurrentSelection(selection)
            }

        case .ended, .cancelled, .failed:
            // 保留原生选择(之后可用手指拖动手柄继续调整;点空白处清除)
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
        let selection = pdfView.currentSelection
        let text = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let selection, !selection.pages.isEmpty, !text.isEmpty {
            let pageIndex = selection.pages.first.flatMap { pdfView.document?.index(for: $0) } ?? -1
            let key = "\(pageIndex)|\(text.count)|\(text.hashValue)"
            guard key != lastAppliedSelectionKey else { return } // 内容未变不重建
            lastAppliedSelectionKey = key
            updateTempHighlight(for: selection)
            let display = text.count > 400 ? String(text.prefix(400)) + "…" : text
            onSelectionInfo(SelectionInfo(text: display, wordCount: WordPicker.countWords(in: text)))
        } else {
            lastAppliedSelectionKey = nil
            clearTempHighlight()
            onSelectionInfo(nil)
        }
    }

    /// 差量更新临时高亮:只移除消失的行、只新增出现的行(避免"清空重建"造成的大文档卡顿)。
    private func updateTempHighlight(for selection: PDFSelection) {
        var desired: [String: (page: PDFPage, rect: CGRect)] = [:]
        for page in selection.pages {
            let lineSelections = selection.selectionsByLine().filter { $0.pages.first === page }
            var rects = lineSelections.map { $0.bounds(for: page) }
            if rects.isEmpty { rects = [selection.bounds(for: page)] }

            for rect in rects.prefix(Self.maxHighlightLines) where Self.isValid(rect) {
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

        // 命中判断用的矩形(无注解开销)
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
                   let text = selection.string, !text.isEmpty {
                    return selection
                }
            }
        }
        // 退化:锚点到当前点之间的字符级选择
        return page.selection(from: drag.anchorPoint, to: current)
    }

    /// 页面坐标 y 向上:先按行(容差 6pt),同行按 x 排序,保证 from 在 to 之前。
    private static func ordered(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
        if abs(a.y - b.y) < 6 { return a.x <= b.x ? (a, b) : (b, a) }
        return a.y > b.y ? (a, b) : (b, a)
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
