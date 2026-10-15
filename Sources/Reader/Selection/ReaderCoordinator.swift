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
    /// 文档内容哈希(v0.7.0:生词本按它关联;由 PDFKitView 注入)
    var docSha = ""
    /// 生词本数据层(v0.7.0;由 PDFKitView 注入)
    var vocabStore: VocabStore?
    /// 点中「永久加亮的词」时回调(宿主打开/切换词卡,v0.7.0)
    var onVocabWordTap: ((String) -> Void)?
    /// 待恢复的阅读位置(由 PDFKitView 在加载文档前注入)
    var pendingRestore: ReadingState?
    /// 视图拆卸前的兜底回调(保存阅读位置等)
    var onTeardown: (() -> Void)?

    // MARK: - 选区状态

    private var annotations: [String: (page: PDFPage, annotation: PDFAnnotation)] = [:]
    private var rects: [(page: PDFPage, rect: CGRect)] = []

    // v0.7.0:永久加亮(生词本)层——与临时选区层分开管理
    private var permAnnotations: [String: (page: PDFPage, annotation: PDFAnnotation)] = [:]
    private var permHitRects: [(page: PDFPage, rect: CGRect, term: String)] = []

    // v0.8.0:生词本跳转(v0.8.0)——橙色临时高亮,短暂显示后自动消失
    var pendingVocabJump: VocabJumpTarget?
    var onVocabJumpPerformed: (() -> Void)?
    private var jumpAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []
    private var jumpClearWork: DispatchWorkItem?

    // v0.9.0(M4):Pencil 标记层(按页 PKCanvasView 叠加)+ Pencil Pro 挤压交互
    var inkStore: PencilInkStore?
    var onPencilSqueeze: (() -> Void)?
    var markMode = false
    private var overlayProvider: PencilOverlayProvider?
    private var squeezeRef: UIPencilInteraction?
    private var appliedKey: String?
    private var appliedCharCount = 0
    /// v0.8.3:拖柄对齐自检——每次选区变化只记一行(柄中线 vs 高亮边缘)
    private var lastHandleCheckKey: String?
    private var selectionText = ""

    // MARK: - 手势

    private weak var fingerPressRef: UILongPressGestureRecognizer?
    private weak var pencilPressRef: UILongPressGestureRecognizer?
    private weak var tapRef: UITapGestureRecognizer?
    private weak var doubleTapRef: UITapGestureRecognizer?
    private weak var tripleTapRef: UITapGestureRecognizer?
    private var suppressLogged = false
    /// 原生选区清除重入保护(v0.6.6:防 clearSelection 触发通知再杀形成死循环)
    private var killingNativeSelection = false

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

    // MARK: - 编辑菜单避让(v0.6.10)

    /// 菜单与拖柄圆点之间的最小间距(包络扩边与锚点偏移共用)
    private let menuHandleGap: CGFloat = 8
    /// 编辑菜单高度估计(用于"上方放得下"判断;系统菜单竖排高度 ≈ 56–64pt)
    private let menuHeightEstimate: CGFloat = 64

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
        if let jump = pendingVocabJump {
            // v0.8.0:生词本跳转(橙色临时高亮)——优先于阅读位置恢复(预览不覆盖进度)
            pendingVocabJump = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, let doc = self.pdfView?.document else { return }
                self.performVocabJump(jump, doc: doc)
            }
        } else if let state = pendingRestore {
            pendingRestore = nil
            applyReadingState(state)
        }
        reloadPermanentHighlights()
    }

    /// 视图拆卸前调用(先兜底保存,再停掉所有活动机制,防止悬挂)
    func prepareForTeardown() {
        onTeardown?()
        overlayProvider?.flushAll()   // v0.9.0:收尾把未落盘的手写存库
        holdMenuWork?.cancel()
        holdMenuWork = nil
        stopAutoscroll()
        loupe.end()
        menu.dismiss()
        clearJumpHighlight()
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
        reloadPermanentHighlights()
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
        guard let pdfView, !killingNativeSelection else { return }
        let text = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            // 内置手势漏网(被重建/再长按):立刻清掉原生选区 + 再压制(v0.6.5;v0.6.6 加重入保护)
            DiagLog.log("native sel detected(len=\(text.count)); kill + re-suppress")
            killingNativeSelection = true
            suppressNativeSelection(in: pdfView)
            pdfView.currentSelection = nil
            pdfView.clearSelection()
            DispatchQueue.main.async { [weak self] in
                self?.killingNativeSelection = false
            }
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

        // v0.9.0(M4):Pencil 标记层(PDFPageOverlayViewProvider 按页叠 PKCanvasView;不改动原 PDF)
        let provider = PencilOverlayProvider(pdfView: view, docSha: docSha, inkStore: inkStore, markMode: markMode)
        overlayProvider = provider
        view.pageOverlayViewProvider = provider

        // Pencil Pro 挤压(iPadOS 17.5+):默认切换标记/选词模式(动作映射设置项留 M4-B 后续)
        // UIPencilInteraction 是 UIInteraction(不是手势识别器)→ 用 addInteraction 安装
        let squeeze = UIPencilInteraction()
        squeeze.delegate = self
        view.addInteraction(squeeze)
        squeezeRef = squeeze

        // 编辑菜单(系统组件)
        menu.onTranslate = { [weak self] text in
            self?.onTranslate?(text)
        }
        menu.textProvider = { [weak self] in
            self?.selectionText ?? ""
        }
        menu.install(on: view)
        menu.targetRectProvider = { [weak self] _ in
            self?.menuEnvelopeRect()
        }

        suppressNativeSelection(in: view)
        observeScrolling()
    }

    /// 停用 PDFKit 内置的选择手势(长按 / 双击)。保留滚动、缩放与链接单击。
    func suppressNativeSelection(in view: UIView?) {
        guard let view else { return }
        var disabled = 0
        func walk(_ v: UIView) {
            // v0.9.0:不动标记画布子树(其内部识别器属于 PencilKit 绘制体系)
            if v is InkOverlayView { return }
            for gr in v.gestureRecognizers ?? [] {
                if gr === fingerPressRef || gr === pencilPressRef || gr === tapRef
                    || gr === doubleTapRef || gr === tripleTapRef { continue }
                let isLongPress = gr is UILongPressGestureRecognizer
                let isMultiTap = (gr as? UITapGestureRecognizer).map { $0.numberOfTapsRequired >= 2 } ?? false
                // v0.6.6:回退"按类名压制私有手势"(v0.6.5 的做法在文字层 PDF 上误伤 PDFKit 文本链路,
                // 导致"不能选词");泄漏改由 selectionDidChange 的即时清除兜底。
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

    /// 下一主线程周期再压一遍(v0.6.5):捕获"操作后系统重建选择手势"的窗口期。
    private func resuppressSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.pdfView else { return }
            self.suppressNativeSelection(in: view)
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
            // v0.6.5:长按生效前再压一遍(防"已有选区后再长按"时被重建的选择手势漏网)
            suppressNativeSelection(in: pdfView)
            guard let hit = pageHit(viewPoint) else {
                DiagLog.log("press.began(\(kind)): no page")
                return
            }

            // v0.8.1:触点落在拖柄热区内(≥44×44,以"圆点+竖线"整体为中心)→ 让位给拖柄拖动;
            // 避免与"按住选区本体拖动"互相打架(两种拖动各管各的)。
            if handleHitTest(viewPoint) {
                DiagLog.log("press.began(\(kind)): on handle → yield")
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
                self.presentMenu()
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
                presentMenu()
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
            suppressNativeSelection(in: pdfView)
            holdMenuWork?.cancel()
            holdMenuWork = nil
            menu.dismiss()
            guard let (page, lineRects) = orderedSelectionRects(),
                  let firstLine = lineRects.first, let lastLine = lineRects.last else { return }
            // v0.8.3:lineRects 为显示矩形;锚点仍取"原始文字边缘"内侧 0.6pt(与扩边前行为一致)
            let fixedPoint = isStart
                ? CGPoint(x: HandleMetrics.lineRect(fromDisplay: lastLine).maxX - 0.6, y: lastLine.midY)
                : CGPoint(x: HandleMetrics.lineRect(fromDisplay: firstLine).minX + 0.6, y: firstLine.midY)
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
                presentMenu()
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
            // v0.7.0:命中「永久加亮的词」→ 打开/切换词卡(优先于菜单切换)
            if let hit = permHitRects.first(where: { $0.page === page && $0.rect.insetBy(dx: -6, dy: -6).contains(pagePoint) }) {
                DiagLog.log("tap: vocab word 「\(hit.term)」 → card")
                clearTempOnly()
                onVocabWordTap?(hit.term)
                return
            }
            // 命中判定留宽容差(行间隙/选区边缘的点击都算"点选区")
            let onSelection = rects.contains { $0.page === page && $0.rect.insetBy(dx: -10, dy: -10).contains(pagePoint) }
            if onSelection {
                // 点选区:只切换菜单,**永不关闭选区**
                let anchor = menuAnchor()
                menu.toggle(at: anchor.point, arrowDirection: anchor.arrow)
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
        presentMenu()
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
        presentMenu()
    }

    // MARK: - 选区应用 / 高亮

    private func applySelection(_ selection: PDFSelection, src: String) {
        guard let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastAnySelectionChangeTime = CFAbsoluteTimeGetCurrent()
        guard SelectionGeometry.isSane(selection, maxPages: 1, maxChars: 6_000) else {
            // v0.6.6:坏帧只记录、**不清空现有选区**(拖动中偶发解析异常时保留上一个好状态)
            DiagLog.log("applySelection rejected(\(src)): pages=\(selection.pages.count) len=\(text.count)")
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
        let wordCount = WordPicker.countWords(in: text)
        let primaryTerm = WordPicker.firstLexicalWord(in: text) ?? ""
        onSelectionInfo(SelectionInfo(
            text: display,
            wordCount: wordCount,
            primaryTerm: primaryTerm
        ))
        if wordCount <= 1, !primaryTerm.isEmpty {
            vocabDidSelectWord(term: primaryTerm)
        }
        resuppressSoon()
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
            // v0.8.3:选区显示矩形(±扩边)——与拖柄摆放共用同一来源(HandleMetrics.displayRect)
            let annotation = PDFAnnotation(
                bounds: HandleMetrics.displayRect(entry.rect),
                forType: .highlight,
                withProperties: nil
            )
            annotation.color = UIColor.systemBlue.withAlphaComponent(0.35)
            entry.page.addAnnotation(annotation)
            annotations[key] = (entry.page, annotation)
        }
        // v0.8.3:写回**显示矩形**——拖柄(竖线中线=高亮边缘)与生词本存储都读这一份
        rects = desired.values.map { ($0.page, HandleMetrics.displayRect($0.rect)) }

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
        clearJumpHighlight()
        freezeScrolling(false)
        pdfView?.currentSelection = nil
        pdfView?.clearSelection()
        appliedKey = nil
        appliedCharCount = 0
        selectionText = ""
        clearTempHighlight()
        refreshHandles()
        onSelectionInfo(nil)
        resuppressSoon()
    }

    /// 关闭整条选中链(供侧边词卡关闭按钮等外部调用)。
    func dismissSelection() {
        clearSelection()
    }

    // MARK: - 生词本联动(v0.7.0,M3-A)

    /// 只清"临时选区"相关状态(高亮/拖柄/菜单);不回调 onSelectionInfo(nil)、不动词卡。
    private func clearTempOnly() {
        holdMenuWork?.cancel()
        holdMenuWork = nil
        stopAutoscroll()
        loupe.end()
        menu.dismiss()
        clearJumpHighlight()
        appliedKey = nil
        appliedCharCount = 0
        selectionText = ""
        clearTempHighlight()
        refreshHandles()
        resuppressSoon()
    }

    private func currentPageIndex() -> Int {
        guard let pdfView, let page = pdfView.currentPage else { return 0 }
        return pdfView.document?.index(for: page) ?? 0
    }

    /// 重新渲染本文件的永久加亮:按 docSha 从生词本取所有行矩形(页坐标),逐条加回注解;
    /// 同时重建点击命中表(点已加亮的词 → 开/切词卡)。
    func reloadPermanentHighlights() {
        guard let pdfView, let vocabStore, let doc = pdfView.document, !docSha.isEmpty else { return }
        for (_, entry) in permAnnotations {
            entry.page.removeAnnotation(entry.annotation)
        }
        permAnnotations.removeAll()
        permHitRects.removeAll()
        let rows = vocabStore.highlights(docSha: docSha)
        var rectCount = 0
        for row in rows {
            guard let page = doc.page(at: row.page) else { continue }
            for rect in row.rects where SelectionGeometry.isValid(rect) {
                let key = "\(ObjectIdentifier(page).hashValue)_\(annotationKey(page, rect))"
                // v0.8.3:存储的 rects 即"显示矩形"(收录时经 HandleMetrics.displayRect);直接使用,不再二次扩边
                let annotation = PDFAnnotation(
                    bounds: rect,
                    forType: .highlight,
                    withProperties: nil
                )
                annotation.color = VocabStore.highlightColor(named: row.color).withAlphaComponent(0.35)
                page.addAnnotation(annotation)
                permAnnotations[key] = (page, annotation)
                permHitRects.append((page, rect, row.term))
                rectCount += 1
            }
        }
        DiagLog.log("vocab: perm highlights \(rectCount) rects / \(rows.count) words")
    }

    /// 加入生词本 / 重新收录(词卡按钮):建卡 + 记录语境 + 用当前选区矩形永久加亮;返回新状态。
    /// 仅当"当前选区就是这个词"时把选区矩形作为加亮位置,否则只建卡(如从整句卡词块点进来的)。
    func collectWord(key: String, surface: String) -> VocabStore.Status? {
        guard let vocabStore, !docSha.isEmpty else { return nil }
        let selectionIsTerm = selectionText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == surface.lowercased()
        // v0.8.3:rects 现为"显示矩形"(含扩边)——直接作为生词本高亮存储,与拖柄对齐同一口径
        let useRects: [CGRect] = selectionIsTerm ? rects.map { $0.rect } : []
        let page = rects.first.flatMap { pdfView?.document?.index(for: $0.page) } ?? currentPageIndex()
        let context = sentenceContextOrSelection(surface: surface)   // v0.8.2:整句原句语境
        let wordId = vocabStore.collectWord(
            lemma: key,
            surface: surface,
            docSha: docSha,
            page: page,
            context: context,
            rectsJSON: VocabStore.rectsToJSON(useRects)
        )
        guard wordId != nil else {
            DiagLog.log("vocab: collect FAILED 「\(surface)」")
            return nil
        }
        reloadPermanentHighlights()
        DiagLog.log("vocab: collect 「\(surface)」(\(key)) rects=\(useRects.count) page=\(page)")
        return .new
    }

    /// v0.8.2:原句提取(整句语境;无文本层/失败时回退选中文本,再回退词面)。
    private func sentenceContextOrSelection(surface: String) -> String {
        if let (page, lineRects) = orderedSelectionRects(),
           let first = lineRects.first, let last = lineRects.last,
           let sentence = SentenceExtractor.sentenceContext(firstLine: first, lastLine: last, on: page) {
            DiagLog.log("context: sentence len=\(sentence.count)")
            return sentence
        }
        let fallback = selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? surface : fallback
    }

    /// 标记已掌握:取消加亮(status 保留为 mastered,供 P1 批量过滤/排除)。
    func masterWord(key: String) -> VocabStore.Status? {
        guard let vocabStore, let wordId = vocabStore.entryId(forLemma: key) else { return nil }
        vocabStore.setStatus(wordId: wordId, status: .mastered)
        vocabStore.removeHighlights(wordId: wordId)
        reloadPermanentHighlights()
        DiagLog.log("vocab: mastered 「\(key)」")
        return .mastered
    }

    /// 设置某词高亮颜色(v0.8.0)。
    func setHighlightColor(key: String, colorName: String) {
        guard let vocabStore else { return }
        vocabStore.setHighlightColor(forLemma: key, colorName: colorName)
        reloadPermanentHighlights()
        DiagLog.log("vocab: color 「\(key)」→\(colorName)")
    }

    /// 取消某词的全部高亮(保留词条与语境,v0.8.0)。
    func removeWordHighlights(key: String) {
        guard let vocabStore, let wordId = vocabStore.entryId(forLemma: key) else { return }
        vocabStore.removeHighlights(wordId: wordId)
        reloadPermanentHighlights()
        DiagLog.log("vocab: highlights removed 「\(key)」")
    }

    /// v0.9.0(M4):标记 / 选词模式切换——标记模式下 Pencil 交给画布(Pencil 专属选区手势让位),
    /// 手指的滚动/缩放/长按选词两种模式都保留;切到标记模式时清掉当前选区。
    func setMarkMode(_ on: Bool) {
        guard markMode != on else { return }
        markMode = on
        overlayProvider?.setMarkMode(on)
        pencilPressRef?.isEnabled = !on
        let types: [NSNumber] = on
            ? [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            : [NSNumber(value: UITouch.TouchType.direct.rawValue),
               NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        tapRef?.allowedTouchTypes = types
        doubleTapRef?.allowedTouchTypes = types
        tripleTapRef?.allowedTouchTypes = types
        if on, !selectionText.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.clearSelection() }
        }
        DiagLog.log("pencil: markMode=\(on)")
    }

    /// 生词本 → 出处跳转:跳页 + 橙色临时高亮(约 2.5s 自动消失;点空白/清选区也会清掉)。
    func jumpToVocab(target: VocabJumpTarget) {
        guard let pdfView, let doc = pdfView.document else { return }
        performVocabJump(target, doc: doc)
    }

    private func performVocabJump(_ target: VocabJumpTarget, doc: PDFDocument) {
        guard let pdfView else { return }
        clearJumpHighlight()
        let idx = min(max(target.page, 0), max(doc.pageCount - 1, 0))
        guard let page = doc.page(at: idx) else { return }
        pdfView.go(to: page)
        lastGoodPage = (idx, CFAbsoluteTimeGetCurrent())
        jumpGuardUntil = CFAbsoluteTimeGetCurrent() + 0.6
        var added = 0
        if let json = target.rectsJSON {
            for rect in VocabStore.rectsFromJSON(json) where SelectionGeometry.isValid(rect) {
                // v0.8.3:存储的 rects 即"显示矩形",直接使用(不再二次扩边)
                let annotation = PDFAnnotation(
                    bounds: rect,
                    forType: .highlight,
                    withProperties: nil
                )
                annotation.color = UIColor.systemOrange.withAlphaComponent(0.4)
                page.addAnnotation(annotation)
                jumpAnnotations.append((page, annotation))
                added += 1
            }
        }
        DiagLog.log("vocab jump: page->\(idx) 「\(target.term)」 rects=\(added)")
        let work = DispatchWorkItem { [weak self] in self?.clearJumpHighlight() }
        jumpClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        onVocabJumpPerformed?()
    }

    private func clearJumpHighlight() {
        jumpClearWork?.cancel()
        jumpClearWork = nil
        guard !jumpAnnotations.isEmpty else { return }
        for (page, annotation) in jumpAnnotations {
            page.removeAnnotation(annotation)
        }
        jumpAnnotations.removeAll()
    }

    /// 选词后的生词本联动(后台):已收录 → 追加新语境(不重复建卡);
    /// 开启「选中即自动收录」→ 自动建卡 + 永久加亮(已掌握的词不自动复活)。
    private func vocabDidSelectWord(term: String) {
        guard let vocabStore, !docSha.isEmpty else { return }
        let autoCollect = UserDefaults.standard.bool(forKey: "autoCollectOnSelect")
        let page = rects.first.flatMap { pdfView?.document?.index(for: $0.page) } ?? currentPageIndex()
        let context = sentenceContextOrSelection(surface: term)   // v0.8.2:整句语境
        let docSha = docSha
        let rectsJSON = VocabStore.rectsToJSON(rects.map { $0.rect })
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let key = VocabStore.normalizedKey(term)
            if let wordId = vocabStore.entryId(forLemma: key) {
                vocabStore.addOccurrence(wordId: wordId, docSha: docSha, page: page, context: context)
            } else if autoCollect {
                vocabStore.collectWord(
                    lemma: key,
                    surface: term,
                    docSha: docSha,
                    page: page,
                    context: context,
                    rectsJSON: rectsJSON
                )
                DispatchQueue.main.async {
                    self?.reloadPermanentHighlights()
                }
            }
        }
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
        // v0.8.1(用户指定):竖线 = 首/末行**选区高**(随缩放自适应,多行选区各取首/末行);
        // 圆点定尺寸、紧贴竖线外端、位于选区外;两端共用同一几何,线宽/圆点/交叠全取自 HandleMetrics。
        let firstView = pdfView.convert(firstLine, from: page)
        let lastView = pdfView.convert(lastLine, from: page)
        let w = HandleMetrics.handleWidth
        let startH = HandleMetrics.handleHeight(forLineHeight: firstView.height)
        let endH = HandleMetrics.handleHeight(forLineHeight: lastView.height)
        // 起点柄:线沿首行左边缘[顶..底],圆点在上端、选区外(框顶 = minY − dotProtrusion)
        place(startHandle,
              center: CGPoint(x: firstView.minX, y: firstView.minY - HandleMetrics.dotProtrusion + startH / 2),
              size: CGSize(width: w, height: startH))
        // 终点柄:线沿末行右边缘[顶..底],圆点在下端、选区外(框底 = maxY + dotProtrusion)
        place(endHandle,
              center: CGPoint(x: lastView.maxX, y: lastView.minY + endH / 2),
              size: CGSize(width: w, height: endH))
        // v0.8.3:对齐自检——柄竖线中线 vs 高亮边缘(两者同源自 HandleMetrics.displayRect,Δ 应恒 ≈ 0)
        if drag == nil, appliedKey != lastHandleCheckKey {
            lastHandleCheckKey = appliedKey
            let ds = abs((startHandle?.frame.midX ?? 0) - firstView.minX)
            let de = abs((endHandle?.frame.midX ?? 0) - lastView.maxX)
            DiagLog.log(String(format: "handles: Δstart=%.2f Δend=%.2f pt(目标 ≤0.5)", ds, de))
        }
    }

    private func place(_ handle: SelectionHandleView?, center: CGPoint, size: CGSize) {
        guard let handle else { return }
        handle.frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                              width: size.width, height: size.height)
        handle.isHidden = false
    }

    /// 触点(pdfView 视图坐标)是否落在任一端拖柄的热区内(v0.8.1;
    /// 热区由 SelectionHandleView.point(inside:) 扩到 ≥44×44、以"圆点+竖线"整体为中心)。
    private func handleHitTest(_ viewPoint: CGPoint) -> Bool {
        guard let pdfView else { return false }
        for handle in [startHandle, endHandle] {
            guard let handle, !handle.isHidden else { continue }
            let p = handle.convert(viewPoint, from: pdfView)
            if handle.point(inside: p, with: nil) { return true }
        }
        return false
    }

    private func hideHandles() {
        startHandle?.isHidden = true
        endHandle?.isHidden = true
    }

    // MARK: - 编辑菜单定位(v0.6.10:拖柄包络 + 方向决策)

    /// 菜单锚点与方向(方向供 preferredArrowDirection 提示;nil = 系统自动)。
    private struct MenuAnchor {
        var point: CGPoint
        var arrow: UIEditMenuArrowDirection?
    }

    /// 拖柄包络矩形(视图坐标):选区并集,上下各扩「圆点伸出距离 + menuHandleGap」——
    /// 系统据此摆放编辑栏,无论菜单出现在选区**上方还是下方**,都与两端圆点保持间距、绝不遮挡。
    private func menuEnvelopeRect() -> CGRect? {
        guard let pdfView, let (page, lineRects) = orderedSelectionRects(), !lineRects.isEmpty else {
            return nil
        }
        var union: CGRect = .null
        for rect in lineRects {
            union = union.union(pdfView.convert(rect, from: page))
        }
        guard !union.isNull else { return nil }
        let clearance = HandleMetrics.dotProtrusion + menuHandleGap
        var result = union.insetBy(dx: -4, dy: 0)
        result.origin.y -= clearance
        result.size.height += clearance * 2
        return result
    }

    /// 菜单锚点 + 方向决策(v0.6.10):
    /// ① 上方放得下(起点圆点上沿 − menuHeightEstimate − menuHandleGap ≥ 可见区顶部,含 safeArea)
    ///    → 锚在起点圆点上方(保留 v0.6.1"默认出现在起点圆点上方"的行为,箭头朝下);
    /// ② 否则下方放得下 → 锚在终点圆点下沿 + menuHandleGap(箭头朝上);
    /// ③ 上下都放不下(选区撑满屏幕)→ 取选区可见部分中部;
    /// ④ 起点/终点柄有一个滚出屏幕时,按可见的那一端取锚点。水平居中于锚点、屏内钳制。
    private func menuAnchor() -> MenuAnchor {
        guard let pdfView, let (page, lineRects) = orderedSelectionRects(),
              let firstLine = lineRects.first, let lastLine = lineRects.last else {
            return MenuAnchor(point: lastTouchViewPoint, arrow: nil)
        }
        var union: CGRect = .null
        for rect in lineRects {
            union = union.union(pdfView.convert(rect, from: page))
        }
        let firstView = pdfView.convert(firstLine, from: page)
        let lastView = pdfView.convert(lastLine, from: page)
        let bounds = pdfView.bounds
        let safeTop = bounds.minY + max(pdfView.safeAreaInsets.top, 0)
        let safeBottom = bounds.maxY - max(pdfView.safeAreaInsets.bottom, 0)
        let dotTop = union.minY - HandleMetrics.dotProtrusion      // 起点圆点上沿(视图坐标)
        let dotBottom = union.maxY + HandleMetrics.dotProtrusion   // 终点圆点下沿(视图坐标)
        let startVisible = dotTop >= safeTop + 4
        let endVisible = dotBottom <= safeBottom - 4
        let needed = menuHeightEstimate + menuHandleGap

        var direction: String
        var arrow: UIEditMenuArrowDirection?
        var anchorX: CGFloat
        var anchorY: CGFloat
        if startVisible, dotTop - safeTop >= needed {
            anchorY = dotTop - menuHandleGap
            anchorX = firstView.minX
            direction = "上"
            arrow = .down
        } else if endVisible, safeBottom - dotBottom >= needed {
            anchorY = dotBottom + menuHandleGap
            anchorX = lastView.maxX
            direction = "下"
            arrow = .up
        } else if startVisible {
            anchorY = max(dotTop - menuHandleGap, safeTop + 8)
            anchorX = firstView.minX
            direction = "上(挤)"
            arrow = .down
        } else if endVisible {
            anchorY = min(dotBottom + menuHandleGap, safeBottom - 8)
            anchorX = lastView.maxX
            direction = "下(挤)"
            arrow = .up
        } else {
            // 上下都放不下:选区可见部分中部(仍避开可见的拖柄——包络矩形继续兜底)
            let viewport = CGRect(x: bounds.minX, y: safeTop, width: bounds.width, height: safeBottom - safeTop)
            let visible = union.intersection(viewport)
            anchorY = visible.isNull ? viewport.midY : visible.midY
            anchorX = visible.isNull ? bounds.midX : visible.midX
            direction = "中"
            arrow = nil
        }
        let x = min(max(anchorX, bounds.minX + 44), bounds.maxX - 44)
        let y = min(max(anchorY, safeTop + 8), safeBottom - 8)
        let envString = menuEnvelopeRect().map { NSCoder.string(for: $0) } ?? "-"
        DiagLog.log("menu: sel=\(NSCoder.string(for: union)) env=\(envString) dir=\(direction) anchor=(\(Int(x)),\(Int(y)))")
        return MenuAnchor(point: CGPoint(x: x, y: y), arrow: arrow)
    }

    /// 弹出菜单(锚点 + 方向一次算好)。
    private func presentMenu() {
        let anchor = menuAnchor()
        menu.present(at: anchor.point, arrowDirection: anchor.arrow)
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
            self.menu.updatePosition(animated: false)   // v0.6.10:滚动后菜单随选区同步
            if sv.isDragging || sv.isDecelerating {
                self.hasUserInteracted = true
            }
            self.fireReadingTick()
        })
        scrollObservers.append(sv.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in
            self?.refreshHandles()
            self?.menu.updatePosition(animated: false)  // v0.6.10:缩放后菜单随选区同步
            self?.fireReadingTick()
        })
        scrollObservers.append(pdfView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            self?.refreshHandles()
            self?.menu.updatePosition(animated: false)  // v0.6.10:旋转/布局变化后菜单随选区同步
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

    /// 拖动扩选:v0.6.6 起 **字符粒度优先、词粒度兜底**(用户要求"一个字母一个字母地拖动")——
    /// ① 先试字符粒度:终点直接取原始触点(`selection(from:to:)` 在最近的字符边界收口);
    /// ② 若解析异常(损坏文档上 point-pair 可能返回非法选区)→ 用词边界点重试;
    /// ③ 全部失败返回 nil(保持上一个好选区,不清空)。
    private func selectionBetween(_ dragState: DragState, and current: CGPoint) -> PDFSelection? {
        let page = dragState.page
        let anchorRect = dragState.anchorWord.bounds(for: page)
        guard SelectionGeometry.isValid(anchorRect) else { return nil }
        let wordStart = CGPoint(x: anchorRect.minX + 0.6, y: anchorRect.midY)
        let wordEnd = CGPoint(x: anchorRect.maxX - 0.6, y: anchorRect.midY)
        // 当前点在锚点词之前(同行左侧或上方)→ 以"词尾"为锚向前拖;否则从"词首"向后拖
        let sameLine = abs(current.y - wordStart.y) < 12
        let beforeWord = sameLine ? (current.x < wordStart.x) : (current.y > wordStart.y + 12)
        let charFrom = beforeWord ? current : wordStart
        let charTo = beforeWord ? wordEnd : current
        // ① 字符粒度
        if let sel = page.selection(from: charFrom, to: charTo),
           SelectionGeometry.isSane(sel, maxPages: 1, maxChars: 6_000),
           let text = sel.string, !text.isEmpty {
            return sel
        }
        // ② 词粒度兜底
        if let currentWord = page.selectionForWord(at: current) {
            let currentRect = currentWord.bounds(for: page)
            if SelectionGeometry.isValid(currentRect) {
                let leftPoint = CGPoint(x: anchorRect.minX + 0.6, y: anchorRect.midY)
                let rightPoint = CGPoint(x: currentRect.maxX - 0.6, y: currentRect.midY)
                let (from, to) = SelectionGeometry.ordered(leftPoint, rightPoint)
                if let sel = page.selection(from: from, to: to),
                   SelectionGeometry.isSane(sel, maxPages: 1, maxChars: 6_000),
                   let text = sel.string, !text.isEmpty {
                    return sel
                }
            }
        }
        return nil
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

extension ReaderCoordinator: UIPencilInteractionDelegate {
    /// Pencil Pro 挤压(iPadOS 17.5+):默认映射 = 切换标记/选词模式(v0.9.0;动作映射设置项留 M4-B)。
    func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
        guard squeeze.phase == .began else { return }
        DiagLog.log("pencil: squeeze → toggle mark mode")
        onPencilSqueeze?()
    }
}
