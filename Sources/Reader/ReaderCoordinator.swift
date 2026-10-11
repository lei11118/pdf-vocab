import UIKit
import PDFKit

/// 取词交互协调器:
/// - 手指:依赖 PDFView 原生选择(监听 .PDFViewSelectionChanged)
/// - Pencil:自定义长按/拖选(原生手势若不接受 Pencil,这里兜底;接受则属于同一条视觉链路)
/// - 选中后立即创建"临时高亮"注解;点空白清除
final class ReaderCoordinator: NSObject {
    weak var pdfView: PDFView?
    var onPageChanged: (Int) -> Void
    var onSelectionInfo: ((SelectionInfo?) -> Void)

    private var tempAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []
    private var tempRects: [(page: PDFPage, rect: CGRect)] = []
    private var suppressSelectionNotification = false
    private var pencilAnchor: (page: PDFPage, range: NSRange)?
    private var observers: [NSObjectProtocol] = []

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
        // Pencil 长按选词(按下后可直接拖动扩展范围)
        let pencilSelect = UILongPressGestureRecognizer(target: self, action: #selector(handlePencilLongPress(_:)))
        pencilSelect.minimumPressDuration = 0.35
        pencilSelect.allowableMovement = 12
        pencilSelect.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        view.addGestureRecognizer(pencilSelect)

        // 点击:点已加亮的词 → 保持(M2 起开词卡);点空白 → 清除临时高亮
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
        let point = gesture.location(in: pdfView)

        switch gesture.state {
        case .began:
            guard let hit = hitTestPoint(point),
                  let range = WordPicker.wordRange(in: hit.page, at: hit.index) else { return }
            pencilAnchor = (hit.page, range)
            setSelection(page: hit.page, range: range)

        case .changed:
            guard let anchor = pencilAnchor,
                  let hit = hitTestPoint(point), hit.page === anchor.page,
                  let range = WordPicker.extendedRange(in: anchor.page, from: anchor.range, to: hit.index) else { return }
            setSelection(page: anchor.page, range: range)

        case .ended, .cancelled, .failed:
            pencilAnchor = nil
            // 手势结束:清掉原生蓝色选择,保留黄色临时高亮与信息条
            suppressSelectionNotification = true
            pdfView.currentSelection = nil
            pdfView.clearSelection()
            suppressSelectionNotification = false

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
            applyTempHighlight(for: selection)
            onSelectionInfo(SelectionInfo(text: text, wordCount: WordPicker.countWords(in: text)))
        } else {
            clearTempHighlight()
            onSelectionInfo(nil)
        }
    }

    private func applyTempHighlight(for selection: PDFSelection) {
        clearTempHighlight()

        for page in selection.pages {
            let lineSelections = selection.selectionsByLine().filter { $0.pages.first === page }
            let lineRects = lineSelections.map { $0.bounds(for: page) }.filter { !$0.isNull && !$0.isEmpty }
            let rects = lineRects.isEmpty ? [selection.bounds(for: page)] : lineRects

            for rect in rects where !rect.isNull && !rect.isEmpty {
                let annotation = PDFAnnotation(
                    bounds: rect.insetBy(dx: -1, dy: -1),
                    forType: .highlight,
                    withProperties: nil
                )
                annotation.color = UIColor.systemYellow.withAlphaComponent(0.45)
                page.addAnnotation(annotation)
                tempAnnotations.append((page, annotation))
                tempRects.append((page, rect))
            }
        }
    }

    func clearTempHighlight() {
        for (page, annotation) in tempAnnotations {
            page.removeAnnotation(annotation)
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
        clearTempHighlight()
        onSelectionInfo(nil)
    }

    // MARK: - 工具

    private func hitTestPoint(_ point: CGPoint) -> (page: PDFPage, index: Int)? {
        guard let pdfView, let page = pdfView.page(for: point, nearest: true) else { return nil }
        let pagePoint = pdfView.convert(point, to: page)
        let index = page.characterIndex(at: pagePoint)
        guard index != NSNotFound else { return nil }
        return (page, index)
    }

    private func setSelection(page: PDFPage, range: NSRange) {
        guard let selection = page.selection(for: range) else { return }
        pdfView?.currentSelection = selection
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
