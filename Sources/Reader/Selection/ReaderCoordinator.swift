import UIKit
import PDFKit

/// 取词交互协调器(v0.5.0「推倒重来」版)。
///
/// 设计原则(详见 docs/SELECTION-PARITY.md):
/// - **仿照 iOS 原生**:长按选词、按住拖动扩选、双击选词、三击选行、拖柄微调、选区本体拖动、
///   放大镜(系统 `UITextLoupeSession`)、菜单(系统 `UIEditMenuInteraction`)、菜单时机、
///   点选区/点空白规则、贴边自动滚动 —— 全部逐条对标原生;
/// - **不用 PDFKit 内置选择机制**:该机制在非线性化文档上会把选区解析到文档末尾(跳页+卡死,真机实证),
///   故停用其长按/双击手势,取词走"纯点坐标"自有管线;全程不设置 PDFView 的选区状态;
/// - **词粒度**吸附(iOS 18 起字符索引 API 有系统回归;也符合"取词"产品语义);
/// - 拖动期间冻结滚动 + 贴边自动滚动,由本协调器自己控制(只写 contentOffset,不触发 PDFKit 自动行为)。
final class ReaderCoordinator: NSObject {

    // MARK: - 依赖与回调

    weak var pdfView: PDFView?
    var onPageChanged: (Int) -> Void
    var onSelectionInfo: ((SelectionInfo?) -> Void)
    /// 「翻译」菜单项回调(SwiftUI 层弹系统翻译面板)
    var onTranslate: ((String) -> Void)?
    /// 阅读位置变化(节流 ≈1.2s 触发一次;宿主做尾随防抖写库)
    var onReadingTick: (() -> Void)?
    /// 文档标识(sha 前缀,仅用于日志)
    var docLabel = ""
    /// 待恢复的阅读位置(由 PDFKitView 在加载文档前注入)
    var pendingRestore: ReadingState?
    /// 视图拆卸前的兜底回调(保存阅读位置等)
    var onTeardown: (() -> Void)?

    // MARK: - 选区状态

    private var annotations: [String: (page: PDFPage, annotation: PDFAnnotation)] = [:]
    private var rects: [(page: PDFPage, rect: CGRect)] = []
    private var appliedKey: String?
    private var appliedCharCount = 0
    private var selectionText = ""

    // MARK: - 手势

    private weak var fingerPressRef: UILongPressGestureRecognizer?
    private weak var pencilPressRef: UILongPressGestureRecognizer?
    private weak var tapRef: UITapGestureRecognizer?
    private weak var doubleTapRef: UITapGestureRecognizer?
    private weak var tripleTapRef: UITapGestureRecognizer?
    private var suppressLogged = false

    // MARK: - 拖动状态

    private enum DragKind: String, Equatable { case word, body, handleStart, handleEnd }
    private struct DragState {
        var kind: DragKind
        var page: PDFPage
        var anchorPoint: CGPoint
        var anchorWord: PDFSelection
        var lastPoint: CGPoint
        var didMove = false
    }
    private var drag: DragState?
    private var holdMenuWork: DispatchWorkItem?

    // MARK: - 拖动柄 / 放大镜 / 菜单

    private var startHandle: SelectionHandleView?
    private var endHandle: SelectionHandleView?
    private let loupe = LoupeController()
    private let menu = SelectionMenuController()

    // MARK: - 冻结滚动 / 贴边自动滚动

    private weak var frozenScrollView: UIScrollView?
    private var scrollWasEnabled = false
    private var autoscrollLink: CADisplayLink?
    private var autoscrollSpeed: CGFloat = 0
    private var lastTouchViewPoint: CGPoint = .zero

    // MARK: - 观察

    private var observers: [NSObjectProtocol] = []
    private var scrollObservers: [NSKeyValueObservation] = []
    private weak var observedScrollView: UIScrollView?

    // MARK: - 防跳页

    private var lastGoodPage: (index: Int, time: CFAbsoluteTime) = (0, 0)
    private var jumpGuardUntil: CFAbsoluteTime = 0
    private var lastAnySelectionChangeTime: CFAbsoluteTime = 0

    // MARK: - 阅读位置 / 节流

    private var hasUserInteracted = false
    private var lastTickTime: CFAbsoluteTime = 0

    private static let maxHighlightLines = 150

    init(
        onPageChanged: @escaping (Int) -> Void,
        onSelectionInfo: @escaping (SelectionInfo?) -> Void
    ) {
        self.onPageChanged = onPageChanged
        self.onSelectionInfo = onSelectionInfo
    }

    deinit {
        autoscrollLink?.invalidate()
        scrollObservers.forEach { $0.invalidate() }
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

    /// 文档加载完成后调用(压制内置手势 + 挂滚动观察 + 恢复阅读位置)
    func documentDidLoad(_ document: PDFDocument) {
        DiagLog.log("doc: \(document.pageCount) pages sha=\(docLabel.prefix(8))")
        suppressNativeSelection(in: pdfView)
        observeScrolling()
        for delay in [0.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let view = self.pdfView else { return }
                self.suppressNativeSelection(in: view)
            }
        }
        if let state = pendingRestore {
            pendingRestore = nil
            applyReadingState(state)
        }
    }

    /// 视图拆卸前调用(先兜底保存,再停掉所有活动机制,防止悬挂)
    func prepareForTeardown() {
        onTeardown?()
        holdMenuWork?.cancel()
        holdMenuWork = nil
        stopAutoscroll()
        loupe.end()
        menu.dismiss()
        freezeScrolling(false)
        clearTempHighlight()
        removeObservers()
    }

    private func documentDidChange() {
        guard let pdfView else { return }
        if let doc = pdfView.document {
            DiagLog.log("docChanged: \(doc.pageCount) pages")
        }
        jumpGuardUntil = 0
        let index = pdfView.document.flatMap { doc in pdfView.currentPage.map { doc.index(for: $0) } } ?? 0
        lastGoodPage = (index, CFAbsoluteTimeGetCurrent())
        stopAutoscroll()
        freezeScrolling(false)
        suppressNativeSelection(in: pdfView)
        observeScrolling()
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
        refreshHandles()
        onPageChanged(index)
        fireReadingTick()
    }

    private func selectionDidChange() {
        guard let pdfView else { return }
        let text = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            // 内置手势没能压住(被重建):再次压制,并留下证据
            DiagLog.log("native sel detected(len=\(text.count)); re-suppress")
            suppressNativeSelection(in: pdfView)
        }
    }

    // MARK: - 手势安装

    func installGestures(on view: PDFView) {
        // 长按选词(手指 0.5s / Pencil 0.45s)
        let fingerPress = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        fingerPress.minimumPressDuration = 0.5
        fingerPress.allowableMovement = 14
        fingerPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.addGestureRecognizer(fingerPress)
        fingerPressRef = fingerPress

        let pencilPress = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        pencilPress.minimumPressDuration = 0.45
        pencilPress.allowableMovement = 14
        pencilPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        view.addGestureRecognizer(pencilPress)
        pencilPressRef = pencilPress

        // 单击 / 双击 / 三击(原生手势集)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]
        tap.delegate = self
        tap.require(toFail: fingerPress)
        tap.require(toFail: pencilPress)
        view.addGestureRecognizer(tap)
        tapRef = tap

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]
        view.addGestureRecognizer(doubleTap)
        doubleTapRef = doubleTap

        let tripleTap = UITapGestureRecognizer(target: self, action: #selector(handleTripleTap(_:)))
        tripleTap.numberOfTapsRequired = 3
        tripleTap.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]
        view.addGestureRecognizer(tripleTap)
        tripleTapRef = tripleTap

        tap.require(toFail: doubleTap)
        doubleTap.require(toFail: tripleTap)

        // 拖动柄(原生不对称布局)
        let start = SelectionHandleView(isStart: true)
        start.isHidden = true
        view.addSubview(start)
        startHandle = start
        let end = SelectionHandleView(isStart: false)
        end.isHidden = true
        view.addSubview(end)
        endHandle = end
        for handle in [start, end] {
            let pan = PencilAwarePanGestureRecognizer(target: self, action: #selector(handleHandlePan(_:)))
            handle.addGestureRecognizer(pan)
        }

        // 编辑菜单(系统组件)
        menu.onTranslate = { [weak self] text in
            self?.onTranslate?(text)
        }
        menu.textProvider = { [weak self] in
            self?.selectionText ?? ""
        }
        menu.install(on: view)

        suppressNativeSelection(in: view)
        observeScrolling()
    }

    /// 停用 PDFKit 内置的选择手势(长按 / 双击)。保留滚动、缩放与链接单击。
    func suppressNativeSelection(in view: UIView?) {
        guard let view else { return }
        var disabled = 0
        func walk(_ v: UIView) {
            for gr in v.gestureRecognizers ?? [] {
                if gr === fingerPressRef || gr === pencilPressRef || gr === tapRef
                    || gr === doubleTapRef || gr === tripleTapRef { continue }
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

    // MARK: - 长按选词 / 本体拖动(一个连续手势)

    /// 建立一次拖动(冻结滚动,记录触点)。
    private func beginDrag(kind: DragKind, page: PDFPage, anchorPoint: CGPoint, anchorWord: PDFSelection, touchPoint: CGPoint, viewPoint: CGPoint) {
        drag = DragState(kind: kind, page: page, anchorPoint: anchorPoint, anchorWord: anchorWord, lastPoint: touchPoint, didMove: false)
        lastTouchViewPoint = viewPoint
        freezeScrolling(true)
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        guard let pdfView else { return }
        let kind = Self.kind(of: gesture)
        let viewPoint = gesture.location(in: pdfView)

        switch gesture.state {
        case .began:
            hasUserInteracted = true
            guard drag == nil else { return }
            guard let hit = pageHit(viewPoint) else {
                DiagLog.log("press.began(\(kind)): no page")
                return
            }

            // ① 长按落在已有选区内 → 选区本体拖动微调(以远端为锚,与原生"按住选区拖动"一致)
            if let (page, lineRects) = orderedSelectionRects(),
               page === hit.page,
               let firstLine = lineRects.first, let lastLine = lineRects.last,
               lineRects.contains(where: { $0.insetBy(dx: -6, dy: -6).contains(hit.point) }) {
                let startAnchor = CGPoint(x: firstLine.minX + 0.6, y: firstLine.midY)
                let endAnchor = CGPoint(x: lastLine.maxX - 0.6, y: lastLine.midY)
                let nearerStart = SelectionGeometry.distanceSquared(hit.point, startAnchor)
                    < SelectionGeometry.distanceSquared(hit.point, endAnchor)
                let fixedPoint = nearerStart ? endAnchor : startAnchor
                guard let anchor = page.selectionForWord(at: fixedPoint) ?? page.selectionForLine(at: fixedPoint) else { return }
                beginDrag(kind: .body, page: page, anchorPoint: fixedPoint, anchorWord: anchor, touchPoint: hit.point, viewPoint: viewPoint)
                if kind == "finger" {
                    loupe.begin(at: viewPoint, widget: nil, in: pdfView)
                }
                DiagLog.log("press.began(\(kind)): body-drag")
                return
            }

            // ② 新选词
            let t0 = CFAbsoluteTimeGetCurrent()
            guard let word = hit.page.selectionForWord(at: hit.point) ?? hit.page.selectionForLine(at: hit.point),
                  SelectionGeometry.isSane(word, maxPages: 1, maxChars: 300) else {
                DiagLog.log(String(format: "press.began(%@): no word (%.0fms)", kind, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
                return
            }
            DiagLog.log(String(format: "press.began(%@): word=「%@」 len=%d", kind,
                               SelectionGeometry.logSnippet(word.string ?? ""), word.string?.count ?? 0))
            beginDrag(kind: .word, page: hit.page, anchorPoint: hit.point, anchorWord: word, touchPoint: hit.point, viewPoint: viewPoint)
            applySelection(word, src: "own")
            if kind == "finger" {
                loupe.begin(at: viewPoint, widget: nil, in: pdfView)
            }
            // 按住不动 ~0.35s 后菜单先弹出(原生时机);一旦拖动立即取消
            let work = DispatchWorkItem { [weak self] in
                guard let self, let d = self.drag, d.kind == .word, !d.didMove,
                      !self.selectionText.isEmpty, !self.menu.isPresented else { return }
                self.menu.present(at: self.menuSourcePoint())
                DiagLog.log("menu presented (hold)")
            }
            holdMenuWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)

        case .changed:
            guard var d = drag, d.kind == .word || d.kind == .body,
                  let hit = pageHit(viewPoint), hit.page === d.page else { return }
            lastTouchViewPoint = viewPoint
            let moved = SelectionGeometry.distanceSquared(hit.point, d.anchorPoint) > 16
            if !d.didMove, moved {
                d.didMove = true
                drag = d
                holdMenuWork?.cancel()
                holdMenuWork = nil
                menu.dismiss()
            }
            let step: CGFloat = appliedCharCount > 800 ? 8 : 3
            let dx = hit.point.x - d.lastPoint.x
            let dy = hit.point.y - d.lastPoint.y
            guard dx * dx + dy * dy >= step * step else {
                updateAutoscroll(for: viewPoint)
                return
            }
            drag?.lastPoint = hit.point
            extendDrag(to: hit, viewPoint: viewPoint)
            updateAutoscroll(for: viewPoint)

        case .ended, .cancelled, .failed:
            let wasDrag = drag
            let isEnded = gesture.state == .ended
            if let k = wasDrag?.kind, k != .word && k != .body { return } // 与拖柄状态隔离
            drag = nil
            holdMenuWork?.cancel()
            holdMenuWork = nil
            stopAutoscroll()
            loupe.end()
            freezeScrolling(false)
            DiagLog.log("press.end(\(kind)) moved=\(wasDrag?.didMove ?? false) ended=\(isEnded)")
            refreshHandles()
            if isEnded, wasDrag != nil, !selectionText.isEmpty, !menu.isPresented {
                menu.present(at: menuSourcePoint())
            }

        default:
            break
        }
    }

    // MARK: - 拖动柄(拖任意一端的圆点,以另一端为锚微调)

    @objc private func handleHandlePan(_ gesture: UIPanGestureRecognizer) {
        guard let pdfView else { return }
        let isStart = (gesture.view === startHandle)
        let viewPoint = gesture.location(in: pdfView)

        switch gesture.state {
        case .began:
            hasUserInteracted = true
            guard drag == nil else { return }
            holdMenuWork?.cancel()
            holdMenuWork = nil
            menu.dismiss()
            guard let (page, lineRects) = orderedSelectionRects(),
                  let firstLine = lineRects.first, let lastLine = lineRects.last else { return }
            let fixedPoint = isStart
                ? CGPoint(x: lastLine.maxX - 0.6, y: lastLine.midY)
                : CGPoint(x: firstLine.minX + 0.6, y: firstLine.midY)
            guard let anchor = page.selectionForWord(at: fixedPoint) ?? page.selectionForLine(at: fixedPoint) else { return }
            drag = DragState(kind: isStart ? .handleStart : .handleEnd,
                             page: page, anchorPoint: fixedPoint, anchorWord: anchor, lastPoint: fixedPoint, didMove: true)
            lastTouchViewPoint = viewPoint
            freezeScrolling(true)
            let pencil = (gesture as? PencilAwarePanGestureRecognizer)?.isPencilDriven ?? false
            if !pencil {
                loupe.begin(at: viewPoint, widget: isStart ? startHandle : endHandle, in: pdfView)
            }
            DiagLog.log("handle.drag began isStart=\(isStart) pencil=\(pencil)")

        case .changed:
            guard let d = drag, d.kind == .handleStart || d.kind == .handleEnd,
                  let hit = pageHit(viewPoint), hit.page === d.page else { return }
            lastTouchViewPoint = viewPoint
            let dx = hit.point.x - d.lastPoint.x
            let dy = hit.point.y - d.lastPoint.y
            guard dx * dx + dy * dy >= 4 else {
                updateAutoscroll(for: viewPoint)
                return
            }
            drag?.lastPoint = hit.point
            extendDrag(to: hit, viewPoint: viewPoint)
            updateAutoscroll(for: viewPoint)

        case .ended, .cancelled, .failed:
            if let k = drag?.kind, k != .handleStart && k != .handleEnd { return }
            drag = nil
            stopAutoscroll()
            loupe.end()
            freezeScrolling(false)
            DiagLog.log("handle.drag end")
            refreshHandles()
            if gesture.state == .ended, !selectionText.isEmpty, !menu.isPresented {
                menu.present(at: menuSourcePoint())
            }

        default:
            break
        }
    }

    /// 把拖动的活动端延伸到指定落点(供手势 .changed 与贴边自动滚动共用)。
    private func extendDrag(to hit: (page: PDFPage, point: CGPoint), viewPoint: CGPoint) {
        guard let d = drag, hit.page === d.page else { return }
        if let selection = selectionBetween(d, and: hit.point) {
            applySelection(selection, src: "own")
        }
        loupe.move(to: viewPoint)
    }

    // MARK: - 单击 / 双击 / 三击

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let pdfView else { return }
        hasUserInteracted = true
        let point = gesture.location(in: pdfView)

        if let page = pdfView.page(for: point, nearest: false) {
            let pagePoint = pdfView.convert(point, to: page)
            // 命中判定留宽容差(行间隙/选区边缘的点击都算"点选区")
            let onSelection = rects.contains { $0.page === page && $0.rect.insetBy(dx: -10, dy: -10).contains(pagePoint) }
            if onSelection {
                // 点选区:只切换菜单,**永不关闭选区**
                menu.toggle(at: menuSourcePoint())
                DiagLog.log(menu.isPresented ? "tap: show menu (selection kept)" : "tap: dismiss menu (selection kept)")
                return
            }
        }
        // 点空白:蓝色选区与编辑栏**一起消失**(与参考截图/原生一致)
        guard !rects.isEmpty || menu.isPresented else { return }
        DiagLog.log("tap: clear all (menu+selection together)")
        clearSelection()
    }

    /// 双击选词(并弹菜单)。
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let pdfView, gesture.state == .ended else { return }
        hasUserInteracted = true
        let viewPoint = gesture.location(in: pdfView)
        guard let hit = pageHit(viewPoint),
              let word = hit.page.selectionForWord(at: hit.point) ?? hit.page.selectionForLine(at: hit.point),
              SelectionGeometry.isSane(word, maxPages: 1, maxChars: 300) else { return }
        DiagLog.log("doubleTap: word=「\(SelectionGeometry.logSnippet(word.string ?? ""))」")
        applySelection(word, src: "doubleTap")
        refreshHandles()
        menu.present(at: menuSourcePoint())
    }

    /// 三击选行(对应原生"三击选段落";PDF 场景取整行)。
    @objc private func handleTripleTap(_ gesture: UITapGestureRecognizer) {
        guard let pdfView, gesture.state == .ended else { return }
        hasUserInteracted = true
        let viewPoint = gesture.location(in: pdfView)
        guard let hit = pageHit(viewPoint),
              let line = hit.page.selectionForLine(at: hit.point),
              SelectionGeometry.isSane(line, maxPages: 1, maxChars: 2_000) else { return }
        DiagLog.log("tripleTap: line=「\(SelectionGeometry.logSnippet(line.string ?? ""))」")
        applySelection(line, src: "tripleTap")
        refreshHandles()
        menu.present(at: menuSourcePoint())
    }

    // MARK: - 选区应用 / 高亮

    private func applySelection(_ selection: PDFSelection, src: String) {
        guard let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastAnySelectionChangeTime = CFAbsoluteTimeGetCurrent()
        guard SelectionGeometry.isSane(selection, maxPages: 1, maxChars: 6_000) else {
            DiagLog.log("applySelection rejected(\(src)): pages=\(selection.pages.count) len=\(text.count)")
            appliedKey = nil
            appliedCharCount = 0
            clearTempHighlight()
            onSelectionInfo(nil)
            return
        }
        let pageIndex = selection.pages.first.flatMap { pdfView?.document?.index(for: $0) } ?? -1
        let key = "\(pageIndex)|\(text.count)|\(text.hashValue)"
        guard key != appliedKey else { return }
        appliedKey = key
        appliedCharCount = text.count
        selectionText = text
        updateHighlight(for: selection)
        refreshHandles()
        let display = text.count > 400 ? String(text.prefix(400)) + "…" : text
        onSelectionInfo(SelectionInfo(
            text: display,
            wordCount: WordPicker.countWords(in: text),
            primaryTerm: WordPicker.firstLexicalWord(in: text) ?? ""
        ))
    }

    /// 差量更新蓝色高亮:只移除消失的行、只新增出现的行;越界矩形拒绝并计数。
    private func updateHighlight(for selection: PDFSelection) {
        let t0 = CFAbsoluteTimeGetCurrent()
        var desired: [String: (page: PDFPage, rect: CGRect)] = [:]
        var rejected = 0
        for page in selection.pages {
            let pageBounds = page.bounds(for: pdfView?.displayBox ?? .cropBox)
            let lineSelections = selection.selectionsByLine()
                .prefix(Self.maxHighlightLines)
                .filter { $0.pages.first === page }
            var lineRects = lineSelections.map { $0.bounds(for: page) }
            if lineRects.isEmpty { lineRects = [selection.bounds(for: page)] }
            for rect in lineRects {
                guard SelectionGeometry.isValid(rect) else { rejected += 1; continue }
                guard rect.intersects(pageBounds.insetBy(dx: -24, dy: -24)) else { rejected += 1; continue }
                desired[annotationKey(page, rect)] = (page, rect)
            }
        }

        let staleKeys = annotations.keys.filter { desired[$0] == nil }
        for key in staleKeys {
            if let entry = annotations.removeValue(forKey: key) {
                entry.page.removeAnnotation(entry.annotation)
            }
        }
        for (key, entry) in desired where annotations[key] == nil {
            let annotation = PDFAnnotation(
                bounds: entry.rect.insetBy(dx: -1, dy: -1),
                forType: .highlight,
                withProperties: nil
            )
            annotation.color = UIColor.systemBlue.withAlphaComponent(0.35)
            entry.page.addAnnotation(annotation)
            annotations[key] = (entry.page, annotation)
        }
        rects = desired.values.map { ($0.page, $0.rect) }

        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        DiagLog.log(String(format: "hl: lines=%d ms=%.0f rej=%d", desired.count, ms, rejected))
    }

    func clearTempHighlight() {
        for (_, entry) in annotations {
            entry.page.removeAnnotation(entry.annotation)
        }
        annotations.removeAll()
        rects.removeAll()
    }

    private func clearSelection() {
        DiagLog.log("clearSelection")
        holdMenuWork?.cancel()
        holdMenuWork = nil
        stopAutoscroll()
        loupe.end()
        menu.dismiss()
        freezeScrolling(false)
        pdfView?.currentSelection = nil
        pdfView?.clearSelection()
        appliedKey = nil
        appliedCharCount = 0
        selectionText = ""
        clearTempHighlight()
        refreshHandles()
        onSelectionInfo(nil)
    }

    /// 关闭整条选中链(供侧边词卡关闭按钮等外部调用)。
    func dismissSelection() {
        clearSelection()
    }

    // MARK: - 拖柄显示(拖动中也实时跟随)

    /// 选区行矩形,按阅读顺序(从上到下、从左到右)。
    private func orderedSelectionRects() -> (page: PDFPage, rects: [CGRect])? {
        guard let first = rects.first else { return nil }
        let page = first.page
        let sorted = rects.filter { $0.page === page }.map { $0.rect }
            .sorted { a, b in
                if abs(a.midY - b.midY) < 2 { return a.minX < b.minX }
                return a.midY > b.midY
            }
        return (page, sorted)
    }

    private func refreshHandles() {
        guard let pdfView, let (page, lineRects) = orderedSelectionRects(),
              let firstLine = lineRects.first, let lastLine = lineRects.last else {
            hideHandles()
            return
        }
        // v0.6.1:两端各一个蓝色圆点(去短柄)——起点圆点在首行上方、终点圆点在末行下方
        let startView = pdfView.convert(CGPoint(x: firstLine.minX, y: firstLine.maxY), from: page)
        let endView = pdfView.convert(CGPoint(x: lastLine.maxX, y: lastLine.minY), from: page)
        place(startHandle, at: CGPoint(x: startView.x, y: startView.y - 12))
        place(endHandle, at: CGPoint(x: endView.x, y: endView.y + 12))
    }

    private func place(_ handle: SelectionHandleView?, at center: CGPoint) {
        guard let handle else { return }
        handle.isHidden = false
        handle.center = center
    }

    private func hideHandles() {
        startHandle?.isHidden = true
        endHandle?.isHidden = true
    }

    /// 编辑菜单锚点:永远在**第一个小柄(起点圆点)正上方**(用户要求,v0.6.1)。
    private func menuSourcePoint() -> CGPoint {
        guard let pdfView, let (page, lineRects) = orderedSelectionRects(), let firstLine = lineRects.first else {
            return lastTouchViewPoint
        }
        let startView = pdfView.convert(CGPoint(x: firstLine.minX, y: firstLine.maxY), from: page)
        let bounds = pdfView.bounds
        let x = min(max(startView.x, bounds.minX + 44), bounds.maxX - 44)
        let y = min(max(startView.y - 26, bounds.minY + 44), bounds.maxY - 16)
        return CGPoint(x: x, y: y)
    }

    // MARK: - 滚动观察(拖柄跟随 + 阅读位置节流回调)

    private func observeScrolling() {
        guard let pdfView else { return }
        guard let sv = pdfScrollView(pdfView) else { return }
        if observedScrollView === sv, scrollObservers.count == 3 {
            return
        }
        scrollObservers.forEach { $0.invalidate() }
        scrollObservers.removeAll()
        observedScrollView = sv
        scrollObservers.append(sv.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            self.refreshHandles()
            if sv.isDragging || sv.isDecelerating {
                self.hasUserInteracted = true
            }
            self.fireReadingTick()
        })
        scrollObservers.append(sv.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in
            self?.refreshHandles()
            self?.fireReadingTick()
        })
        scrollObservers.append(pdfView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            self?.refreshHandles()
        })
    }

    private func fireReadingTick() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastTickTime > 1.2 else { return }
        lastTickTime = now
        onReadingTick?()
    }

    // MARK: - 阅读位置(记忆退出位置)

    /// 捕捉当前阅读位置(页码 + 页内比例 + 缩放)。
    func captureReadingState() -> ReadingState? {
        guard let pdfView, let doc = pdfView.document, let page = pdfView.currentPage else { return nil }
        let index = doc.index(for: page)
        let pageRect = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
        guard SelectionGeometry.isValid(pageRect), pageRect.width > 1, pageRect.height > 1 else { return nil }
        let viewport = pdfView.bounds
        let xFrac = (viewport.minX - pageRect.minX) / pageRect.width
        let yFrac = (viewport.minY - pageRect.minY) / pageRect.height
        let clamp: (CGFloat) -> Double = { v in Double(min(max(v, -0.5), 1.5)) }
        return ReadingState(
            page: index,
            pageX: clamp(xFrac),
            pageY: clamp(yFrac),
            zoom: Double(pdfView.scaleFactor),
            zoomAuto: pdfView.autoScales
        )
    }

    /// 恢复阅读位置:先定位页面与缩放,布局后按"页内比例"落位(两次校正,用户已手动操作则跳过)。
    func applyReadingState(_ state: ReadingState) {
        guard let pdfView, let doc = pdfView.document else { return }
        let pageIndex = min(max(state.page, 0), doc.pageCount - 1)
        guard let page = doc.page(at: pageIndex) else { return }
        DiagLog.log("restore: begin page=\(pageIndex) zoom=\(String(format: "%.2f", state.zoom)) auto=\(state.zoomAuto)")
        if !state.zoomAuto, state.zoom > 0.01 {
            pdfView.autoScales = false
            pdfView.scaleFactor = min(max(CGFloat(state.zoom), pdfView.minScaleFactor), pdfView.maxScaleFactor)
        } else {
            pdfView.autoScales = true
        }
        pdfView.go(to: page)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.scrollToFractionalPosition(state, page: page)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, !self.hasUserInteracted else { return }
            self.scrollToFractionalPosition(state, page: page)
        }
    }

    private func scrollToFractionalPosition(_ state: ReadingState, page: PDFPage) {
        guard let pdfView, let sv = pdfScrollView(pdfView) else { return }
        let pageRectView = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
        guard SelectionGeometry.isValid(pageRectView), pageRectView.height > 1 else { return }
        let pageRectContent = pageRectView.offsetBy(dx: sv.contentOffset.x, dy: sv.contentOffset.y)
        var x = pageRectContent.minX + CGFloat(state.pageX) * pageRectContent.width
        var y = pageRectContent.minY + CGFloat(state.pageY) * pageRectContent.height
        let minX = -sv.adjustedContentInset.left
        let minY = -sv.adjustedContentInset.top
        let maxX = max(minX, sv.contentSize.width - sv.bounds.width + sv.adjustedContentInset.right)
        let maxY = max(minY, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
        x = min(max(x, minX), maxX)
        y = min(max(y, minY), maxY)
        sv.setContentOffset(CGPoint(x: x, y: y), animated: false)
        DiagLog.log(String(format: "restore: off %.0f,%.0f", x, y))
    }

    /// 跳转到指定页(页码跳转面板用)。
    func go(toPage index: Int) {
        guard let pdfView, let doc = pdfView.document else { return }
        let idx = min(max(index, 0), doc.pageCount - 1)
        guard let page = doc.page(at: idx) else { return }
        hasUserInteracted = true
        pdfView.go(to: page)
        DiagLog.log("jump: page->\(idx)")
    }

    // MARK: - 拖选计算(纯点坐标 + 词粒度)

    private func selectionBetween(_ dragState: DragState, and current: CGPoint) -> PDFSelection? {
        let page = dragState.page
        let anchorRect = dragState.anchorWord.bounds(for: page)

        if let currentWord = page.selectionForWord(at: current) {
            let currentRect = currentWord.bounds(for: page)
            if SelectionGeometry.isValid(anchorRect), SelectionGeometry.isValid(currentRect) {
                let leftPoint = CGPoint(x: anchorRect.minX + 0.6, y: anchorRect.midY)
                let rightPoint = CGPoint(x: currentRect.maxX - 0.6, y: currentRect.midY)
                let (from, to) = SelectionGeometry.ordered(leftPoint, rightPoint)
                if let selection = page.selection(from: from, to: to),
                   SelectionGeometry.isSane(selection, maxPages: 2, maxChars: 6_000),
                   let text = selection.string, !text.isEmpty {
                    return selection
                }
            }
        }
        return page.selection(from: dragState.anchorPoint, to: current)
    }

    // MARK: - 冻结滚动 + 贴边自动滚动

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

    /// 拖动到屏幕上下边缘时自动滚动(只写 contentOffset,速度封顶)。
    private func updateAutoscroll(for touchViewPoint: CGPoint) {
        guard drag != nil, let pdfView, let sv = pdfScrollView(pdfView) else { return }
        let height = pdfView.bounds.height
        guard height > 1 else { return }
        let edge: CGFloat = 64
        var speed: CGFloat = 0
        if touchViewPoint.y < edge {
            speed = -(edge - touchViewPoint.y) / edge * 7
        } else if touchViewPoint.y > height - edge {
            speed = (touchViewPoint.y - (height - edge)) / edge * 7
        }
        let canScroll = sv.contentSize.height > sv.bounds.height + 1
        if abs(speed) > 0.5, canScroll {
            autoscrollSpeed = speed
            if autoscrollLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(autoscrollTick))
                link.add(to: .main, forMode: .common)
                autoscrollLink = link
                DiagLog.log("autoscroll: start")
            }
        } else {
            stopAutoscroll()
        }
    }

    private func stopAutoscroll() {
        if autoscrollLink != nil {
            DiagLog.log("autoscroll: stop")
        }
        autoscrollLink?.invalidate()
        autoscrollLink = nil
        autoscrollSpeed = 0
    }

    @objc private func autoscrollTick() {
        guard drag != nil, let pdfView, let sv = pdfScrollView(pdfView) else {
            stopAutoscroll()
            return
        }
        guard abs(autoscrollSpeed) > 0.05 else { return }
        let minY = -sv.adjustedContentInset.top
        let maxY = max(minY, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
        var y = sv.contentOffset.y + autoscrollSpeed
        y = min(max(y, minY), maxY)
        guard abs(y - sv.contentOffset.y) > 0.25 else { return }
        sv.contentOffset = CGPoint(x: sv.contentOffset.x, y: y)
        // 手指不动、内容在动:用同一屏幕点重算选区,实现"贴边延伸"
        if let hit = pageHit(lastTouchViewPoint) {
            extendDrag(to: hit, viewPoint: lastTouchViewPoint)
        }
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

    private static func kind(of gesture: UILongPressGestureRecognizer) -> String {
        if let t = gesture.allowedTouchTypes.first, t.intValue == Int32(UITouch.TouchType.pencil.rawValue) {
            return "pencil"
        }
        return "finger"
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
