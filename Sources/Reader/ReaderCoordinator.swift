import UIKit
import PDFKit

/// 取词交互协调器(v0.3.1)。
///
/// 架构(回归原生 + 修复层):
/// - **选择交互完全回归 PDFView 原生**:长按/拖选/双击选词/原生蓝色手柄/原生编辑菜单,
///   手指与 Pencil 一致。编辑菜单已通过 `VocabPDFView.canPerformAction` 屏蔽"全选"。
///   根因(非线性化文档触发 PDFKit 异常,导致"跳最后一页/卡死")已由**规范化读取副本**修复;
///   本类不再自建手势、不再压制原生手势、不再弹自绘菜单。
/// - 监听 .PDFViewSelectionChanged:为选区绘制**黄色临时高亮** + 更新底部信息条(产品核心"加亮")。
/// - 保险层:选区合法性校验(异常巨型选区拒绝)、**跳页护栏**(紧跟选区的跨页前跳自动拉回)、
///   高亮矩形页面边界校验、全量诊断日志(Documents/diagnostics.log)。
final class ReaderCoordinator: NSObject {
    weak var pdfView: PDFView?
    var onPageChanged: (Int) -> Void
    var onSelectionInfo: ((SelectionInfo?) -> Void)
    /// 当前文档标识(sha 前 8 位,取自文件名),仅用于日志
    var docLabel = ""

    private var tempAnnotations: [String: (page: PDFPage, annotation: PDFAnnotation)] = [:]
    private var tempRects: [(page: PDFPage, rect: CGRect)] = []
    private var lastAppliedSelectionKey: String?
    private var observers: [NSObjectProtocol] = []

    private var lastAnySelectionChangeTime: CFAbsoluteTime = 0

    // 防跳页
    private var lastGoodPage: (index: Int, time: CFAbsoluteTime) = (0, 0)
    private var jumpGuardUntil: CFAbsoluteTime = 0

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

    func documentDidLoad(_ document: PDFDocument) {
        DiagLog.log("doc: \(document.pageCount) pages sha=\(docLabel.prefix(8))")
    }

    private func documentDidChange() {
        guard let pdfView else { return }
        if let doc = pdfView.document {
            DiagLog.log("docChanged: \(doc.pageCount) pages")
        }
        jumpGuardUntil = 0
        let index = pdfView.document.flatMap { doc in pdfView.currentPage.map { doc.index(for: $0) } } ?? 0
        lastGoodPage = (index, CFAbsoluteTimeGetCurrent())
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
        onPageChanged(index)
    }

    // MARK: - 选择 / 高亮

    private func selectionDidChange() {
        guard let pdfView else { return }

        let selection = pdfView.currentSelection
        let text = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let now = CFAbsoluteTimeGetCurrent()
        lastAnySelectionChangeTime = now
        DiagLog.log("selChange: len=\(text.count) pages=\(selection?.pages.count ?? 0) 「\(Self.logSnippet(text))」")

        if let selection, !selection.pages.isEmpty, !text.isEmpty {
            applySelection(selection, text: text)
        } else {
            lastAppliedSelectionKey = nil
            clearTempHighlight()
            onSelectionInfo(nil)
        }
    }

    private func applySelection(_ selection: PDFSelection, text: String) {
        guard Self.isSane(selection, maxPages: 5, maxChars: 10_000) else {
            DiagLog.log("applySelection rejected: pages=\(selection.pages.count) len=\(text.count)")
            lastAppliedSelectionKey = nil
            clearTempHighlight()
            onSelectionInfo(nil)
            return
        }
        let pageIndex = selection.pages.first.flatMap { pdfView?.document?.index(for: $0) } ?? -1
        let key = "\(pageIndex)|\(text.count)|\(text.hashValue)"
        guard key != lastAppliedSelectionKey else { return }
        lastAppliedSelectionKey = key
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

    // MARK: - 工具

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

    private static func logSnippet(_ s: String) -> String {
        String(s.replacingOccurrences(of: "\n", with: " ").prefix(16))
    }

    private func annotationKey(_ page: PDFPage, _ rect: CGRect) -> String {
        let r = String(format: "%.1f_%.1f_%.1f_%.1f", rect.minX, rect.minY, rect.width, rect.height)
        return "\(ObjectIdentifier(page).hashValue)_\(r)"
    }
}
