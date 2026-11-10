import UIKit
import PDFKit
import PencilKit

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
    var onOCRCharacterRefinementRequested: ((ContextOCRRefinementRequest) -> Void)?
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

    // v0.9.0(M4):Pencil 标记层(按页 PKCanvasView 叠加);v0.10.0:挤压交给原生、触型还原账本
    var inkStore: PencilInkStore?
    /// v0.14.0:手写工具会话(浮动工具带 → 各页画布)
    var toolSession: PencilToolSession?
    /// v0.15.0:挤压 → 弧形工具盘(由 ReaderView 弹层;参数为笔尖视图坐标)
    var onPencilSqueeze: ((CGPoint) -> Void)?
    /// v0.16.0:四指轻点 → 专注模式(ReaderView 负责真正的 chrome 显隐)
    var onFocusToggle: (() -> Void)?
    var markMode = false
    private var overlayProvider: PencilOverlayProvider?
    /// v0.28.0:上次已套用的状态版本。SwiftUI 每次更新都会尝试同步工具,
    /// 无脑 `canvas.tool = ...` 会让 PencilKit 反复重建工具状态,严重时主线程卡死;
    /// 但旧实现的“签名 + 单布尔”会在排队期间永久丢掉一次状态变化,现在改为
    /// latest-wins:异步任务执行时读取最新 state,若有更新再补排一次。
    private var appliedToolRevision = -1
    private var toolApplyScheduled = false
    /// v0.16.2:最近一次落笔/擦除结束时间 —— 双指撤销手势的手掌误触防护
    private var lastInkActivityAt: CFAbsoluteTime = 0
    /// v0.16.2:挤压节流(挤压是持续事件,按住会连发回调)
    /// v0.18.0:书写贴边自动滚动(只观察 Pencil,不抢 PencilKit 手势)
    private var pencilObserver: PencilTouchObserver?
    private var autoScrollLink: CADisplayLink?
    private var autoScrollSpeed: CGFloat = 0
    private weak var autoScrollView: UIScrollView?
    /// v0.28.0:全局湿墨层 —— 常规笔越出当前页的那一段画在 PDFView 之上,不被邻页遮挡
    private var wetHost: PencilWetInkHost?
    /// v0.30.0:跨页干墨层 —— 每页墨迹里越过页面矩形的部分画在邻页上(不切分、不搬迁)
    private var dryHost: PencilDryInkHost?
    /// v0.38.0:可拖动/可旋转的自研直尺(视口坐标,不随滚动移动)
    private var rulerOverlay: SmartRulerView?
    private var wetActive = false
    private var wetPageIndex = 0
    private var wetStrokePoints: [CGPoint] = []   // 页面本地坐标(y 向下)
    private var wetLastDrawAt: CFAbsoluteTime = 0
    /// v0.33.0:最近一次收到采样点的时刻 —— 观察者的 touchesEnded 不稳(真机日志里
    /// 只有 `wet begin`、从来没有 `wet end`),靠它判断"上一笔其实已经结束"。
    private var wetLastSampleAt: CFAbsoluteTime = 0
    private var wetGeneration = 0
    /// v0.13.2(紧急修复):已隔离的滚动 pan 账本(原始触型 / 延迟设置;退出标记模式逐条还原)
    private var armedScrollPans: [ObjectIdentifier: (pan: UIPanGestureRecognizer, scroll: UIScrollView, originalTouchTypes: [NSNumber], originalDelays: Bool)] = [:]
    private var appliedKey: String?
    private var appliedCharCount = 0
    /// v0.8.3:拖柄对齐自检——每次选区变化只记一行(柄中线 vs 高亮边缘)
    private var lastHandleCheckKey: String?
    private var selectionText = ""
    var contextReadingEnabled = false
    var contextReadingGeneration = 0

    /// v0.11.0(M4-B):悬停预览 + 触觉(由 PDFKitView 注入,跟随设置页开关)
    var hoverPreviewEnabled = true
    var hapticsEnabled = true
    var onHoverUpdate: ((String, String, CGPoint, ContextualSelection?) -> Void)?
    var onHoverEnd: (() -> Void)?
    private var hoverKey = ""
    private var hoverEntry: (page: PDFPage, rect: CGRect, annotation: PDFAnnotation)?
    private var verifiedPhraseLookup: VerifiedPhraseGroupLookup?

    /// v0.11.0(M6):扫描版 OCR 取词
    var ocrStore: OCRStore?
    private var docScanned = false
    private var ocrWordsCache: [Int: [OCRWord]] = [:]
    private struct CachedContextOCRSource {
        let source: ContextOCRSelectionSource
        let generation: Int
    }
    private struct OCRCharacterRefinementTarget: Hashable {
        let documentSHA256: String
        let pageIndex: Int
        let blockID: String
        let generation: Int

        init(_ request: ContextOCRRefinementRequest) {
            documentSHA256 = request.documentSHA256
            pageIndex = request.pageIndex
            blockID = request.blockID
            generation = request.generation
        }
    }
    private struct PinnedOCRSelectionSnapshot {
        let page: PDFPage
        let pageIndex: Int
        let documentSHA256: String
        let words: [OCRWord]
        let contextSource: ContextOCRSelectionSource?
        let generation: Int
        var selectedRange: ClosedRange<Int>

        func matches(page candidate: PDFPage, pageIndex candidateIndex: Int, documentSHA256 candidateSHA: String) -> Bool {
            page === candidate && pageIndex == candidateIndex && documentSHA256 == candidateSHA
        }
    }
    private var contextOCRSourceCache: [Int: CachedContextOCRSource] = [:]
    private var contextOCRCacheOrder: [Int] = []
    private var pinnedOCRSelection: PinnedOCRSelectionSnapshot?
    private var ocrCharacterRefinementInFlight: [OCRCharacterRefinementTarget: UUID] = [:]
    private var completedOCRCharacterRefinements = Set<OCRCharacterRefinementTarget>()
    private var completedOCRCharacterRefinementOrder: [OCRCharacterRefinementTarget] = []
    private var failedOCRCharacterRefinementsUntil: [OCRCharacterRefinementTarget: CFAbsoluteTime] = [:]
    private var ocrDrag: (page: PDFPage, pageIndex: Int, anchorIdx: Int, didMove: Bool)?
    private var ocrSelectionActive = false
    private var ocrContextOverride: String?

    /// v0.13.0(P0):已收录词自动加亮(设置开关;按页扫描一次/会话)
    private var autoHighlightDonePages: Set<Int> = []
    private var vocabLemmaCache: Set<String> = []
    private var vocabLemmaCacheTime: CFAbsoluteTime = 0

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
        var contextRoute: Bool
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
    /// v0.23.0:Pencil Pro 悬停位置 —— 挤压时弧形工具盘开在笔尖处
    private var lastHoverViewPoint: CGPoint = .zero
    private var lastHoverAt: CFAbsoluteTime = 0

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
        onSelectionInfo: @escaping (SelectionInfo?) -> Void,
        phraseLookup: VerifiedPhraseGroupLookup? = nil
    ) {
        self.onPageChanged = onPageChanged
        self.onSelectionInfo = onSelectionInfo
        verifiedPhraseLookup = phraseLookup
    }

    deinit {
        if let nativeInkObserver { NotificationCenter.default.removeObserver(nativeInkObserver) }
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
        clearHover()
        // v0.40.2:文档装载后 documentView 才存在 —— 单画布在这里补挂,并补做旧墨迹迁移
        inkSurface?.ensureAttached()
        loadSurfaceInkIfNeeded(docSha: surfaceDocSha ?? "")
        DiagLog.log("doc: \(document.pageCount) pages sha=\(docLabel.prefix(8))")
        docScanned = OCRService.isScanned(document: document)
        ocrWordsCache.removeAll()
        clearContextOCRSourceCache()
        pinnedOCRSelection = nil
        ocrDrag = nil
        autoHighlightDonePages.removeAll()
        DiagLog.log("ocr: scanned=\(docScanned)")
        // v0.23.2:恢复页面排布(纵向/横向/双页)
        if let view = pdfView {
            if let dryHost { view.bringSubviewToFront(dryHost) }
            if let wetHost { view.bringSubviewToFront(wetHost) }
            setLayoutMode(UserDefaults.standard.string(forKey: "readerLayoutMode") ?? "vertical")
            // PDFKit 设文档后会重置缩放上下限,这里重新放开到 4000%
            applyZoomLimits(view)
            DiagLog.log("zoom: limits after load max=\(String(format: "%.1f", view.maxScaleFactor))")
        }
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
        autoHighlightCurrentPage()
        if markMode { setScrollPanPencilExcluded(true) }   // v0.13.1:文档加载后重臂 Pencil 隔离
    }

    /// 视图拆卸前调用(先兜底保存,再停掉所有活动机制,防止悬挂)
    func prepareForTeardown() {
        metalHost?.detach()
        onTeardown?()
        overlayProvider?.flushAll()   // v0.9.0:收尾把未落盘的手写存库
        holdMenuWork?.cancel()
        holdMenuWork = nil
        pinnedOCRSelection = nil
        ocrDrag = nil
        clearContextOCRSourceCache()
        stopAutoscroll()
        stopAutoScroll()
        loupe.end()
        menu.dismiss()
        clearJumpHighlight()
        freezeScrolling(false)
        clearTempHighlight()
        clearWetInk()
        wetHost?.removeFromSuperview()
        wetHost = nil
        dryHost?.removeFromSuperview()
        dryHost = nil
        removeObservers()
    }

    private func documentDidChange() {
        guard let pdfView else { return }
        clearHover()
        if let doc = pdfView.document {
            DiagLog.log("docChanged: \(doc.pageCount) pages")
        }
        jumpGuardUntil = 0
        docScanned = pdfView.document.map { OCRService.isScanned(document: $0) } ?? false
        ocrWordsCache.removeAll()
        clearContextOCRSourceCache()
        pinnedOCRSelection = nil
        ocrDrag = nil
        autoHighlightDonePages.removeAll()
        let index = pdfView.document.flatMap { doc in pdfView.currentPage.map { doc.index(for: $0) } } ?? 0
        lastGoodPage = (index, CFAbsoluteTimeGetCurrent())
        stopAutoscroll()
        freezeScrolling(false)
        suppressNativeSelection(in: pdfView)
        observeScrolling()
        reloadPermanentHighlights()
        if markMode { setScrollPanPencilExcluded(true) }   // v0.13.1:文档切换后重臂
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let view = self.pdfView else { return }
            self.suppressNativeSelection(in: view)
            if self.markMode { self.setScrollPanPencilExcluded(true) }   // 层级落定后再幂等重臂
        }
    }

    private func pageDidChange() {
        // v0.41.0:翻页要把单画布的窗口挪到新页(墨迹留在文档坐标,只换窗口原点)
        inkSurface?.refreshWindow()
        metalHost?.refresh()
        guard let pdfView, let page = pdfView.currentPage else { return }
        let index = pdfView.document?.index(for: page) ?? 0
        let now = CFAbsoluteTimeGetCurrent()
        DiagLog.log("page->\(index)")

        // 防跳页:紧跟选区变化(0.8s 内)的跨页"前跳"判为异常,拉回上次稳定页
        if now > jumpGuardUntil,
           !(PencilTouchIsolation.scrollViews(in:pdfView).contains { $0.isZooming || $0.isZoomBouncing || $0.isDragging || $0.isDecelerating }),
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
        autoHighlightCurrentPage()
        if markMode { setScrollPanPencilExcluded(true) }   // v0.13.1:翻页后新页视图手势可能重建,幂等重臂
    }

    private func selectionDidChange() {
        guard let pdfView, !killingNativeSelection else { return }
        let text = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            if contextReadingEnabled {
                pinnedOCRSelection = nil
                ocrDrag = nil
                ocrSelectionActive = false
                ocrContextOverride = nil
            }
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
        fingerPress.delegate = self
        fingerPress.minimumPressDuration = 0.5
        fingerPress.allowableMovement = 14
        fingerPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.addGestureRecognizer(fingerPress)
        fingerPressRef = fingerPress

        let pencilPress = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        pencilPress.delegate = self
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
        doubleTap.delegate = self
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]
        view.addGestureRecognizer(doubleTap)
        doubleTapRef = doubleTap

        let tripleTap = UITapGestureRecognizer(target: self, action: #selector(handleTripleTap(_:)))
        tripleTap.delegate = self
        tripleTap.numberOfTapsRequired = 3
        tripleTap.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]
        view.addGestureRecognizer(tripleTap)
        tripleTapRef = tripleTap

        tap.require(toFail: doubleTap)
        doubleTap.require(toFail: tripleTap)

        // v0.16.0:四指轻点 = 专注模式(Notability 手势;不影响单/双/三指点选)
        let focusTap = UITapGestureRecognizer(target: self, action: #selector(handleFocusTap(_:)))
        focusTap.numberOfTouchesRequired = 4
        focusTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        focusTap.cancelsTouchesInView = false
        view.addGestureRecognizer(focusTap)

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
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            handle.addGestureRecognizer(pan)
        }

        // v0.9.0(M4):Pencil 标记层(PDFPageOverlayViewProvider 按页叠 PKCanvasView;不改动原 PDF)
        let provider = PencilOverlayProvider(
            pdfView: view, docSha: docSha, inkStore: inkStore, markMode: markMode,
            tool: toolSession?.makeTool(scale: InkGeometry.scale), rulerActive: toolSession?.rulerActive ?? false
        )
        overlayProvider = provider
        // v0.33.0:跨页沿当前排布方向搬(横向连续时邻页在左右)
        provider.flowAxis = view.displayDirection == .horizontal ? .horizontal : .vertical
        // v0.25.0:删除「擦完自动回到上一支笔」—— 用户明确要求选中橡皮(整笔)后要一直保持,
        // 擦完一笔仍留在橡皮上;要换笔自己点。这里不再挂钩任何「手势结束即换工具」的逻辑。
        // One writing owner per reader. Legacy per-page overlays bypass change merging.
        installInkSurface(on: view, docSha: docSha)
        // v0.30.0:干墨层接手后立刻撤湿墨预览(同一段墨不重复画)
        provider.onInkCommitted = { [weak self] in self?.clearWetAfterCommit() }
        // v0.25.1:新 provider 的橡皮/激光/形状配置默认全是"关",必须把当前会话状态推一次,
        // 否则重进文档后(overlay 在创建时继承的是默认关)会出现"工具选中了但画不出/擦不了"。
        applyToolSession(force: true)

        // v0.14.0:自绘浮动工具带取代系统 PKToolPicker —— Pencil 系统手势回到自定义映射:
        // 挤压 = 切换标记/阅读模式;轻点两下 = 橡皮 ⇄ 上一支笔(Notability 式手写体验)。
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = self
        view.addInteraction(pencilInteraction)

        // v0.15.0:Notability 式手势——双指轻点撤销、三指轻点重做(仅标记模式生效)
        let inkUndoTap = UITapGestureRecognizer(target: self, action: #selector(handleInkUndoTap(_:)))
        inkUndoTap.numberOfTouchesRequired = 2
        view.addGestureRecognizer(inkUndoTap)
        let inkRedoTap = UITapGestureRecognizer(target: self, action: #selector(handleInkRedoTap(_:)))
        inkRedoTap.numberOfTouchesRequired = 3
        view.addGestureRecognizer(inkRedoTap)

        // 编辑菜单(系统组件)
        menu.onTranslate = { [weak self] text in
            self?.onTranslate?(text)
        }
        // v0.10.0(Task 2.1):「加入生词本 / 高亮」统一进编辑栏
        menu.vocabStateProvider = { [weak self] in
            self?.currentSelectionVocabState() ?? (collected: false, colorName: nil)
        }
        menu.onCollectWord = { [weak self] in self?.collectFromMenu() }
        menu.onHighlight = { [weak self] name in self?.highlightFromMenu(colorName: name) }
        menu.onRemoveHighlight = { [weak self] in self?.removeHighlightFromMenu() }
        menu.textProvider = { [weak self] in
            self?.selectionText ?? ""
        }
        menu.install(on: view)
        menu.targetRectProvider = { [weak self] _ in
            self?.menuEnvelopeRect()
        }

        // v0.11.0(M4-B):悬停预览(Pencil 悬停;仅在阅读模式 + 开关开启时生效,见 handleHover)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        view.addGestureRecognizer(hover)

        // v0.18.0:书写贴边自动滚动 —— 只观察 Pencil 位置,永不识别,不影响绘制
        // v0.28.0:同一批采样也喂给全局湿墨层(页缝外的溢出段因此能实时显示)。
        let observer = PencilTouchObserver()
        observer.onBegin = { [weak self] in self?.beginWetStroke() }
        observer.onSamples = { [weak self] points in self?.appendWetSamples(points) }
        observer.onMove = { [weak self] point in self?.pencilMoved(to: point) }
        observer.onEnd = { [weak self] in
            self?.stopAutoScroll()
            self?.endWetStroke()
        }
        view.addGestureRecognizer(observer)
        pencilObserver = observer

        // v0.39.0:**删掉湿墨层与干墨镜像层**。
        // 它们是 v0.28–v0.30「只渲染不搬迁」方案的产物;现在跨页靠抬笔切分(v0.32+),
        // 这两层只会在书写过程中反复叠画同一段墨 —— 真机表现就是页缝处闪烁、断续。
        // 形状预览在 wetHost 为 nil 时会自动退回 CAShapeLayer(见 updateShapePreview)。
        overlayProvider?.wetHost = nil
        overlayProvider?.dryHost = nil

        // v0.39.0:尺长取屏幕对角线 —— 横竖都铺满,视觉上就是"无限长"的直尺。
        let ruler = SmartRulerView(length: hypot(view.bounds.width, view.bounds.height), host: view)
        view.addSubview(ruler)
        view.bringSubviewToFront(ruler)
        rulerOverlay = ruler
        ruler.bindDocument(view.documentView)
        // 沿尺绘图:把一笔投影到尺线(画布 ↔ 视口两套坐标互转后做几何判定)
        overlayProvider?.rulerSnapper = { [weak self] stroke, index in
            guard let self, let pdfView = self.pdfView, let ruler = self.rulerOverlay, ruler.isOn,
                  let document = pdfView.document, index >= 0, index < document.pageCount,
                  let page = document.page(at: index) else { return nil }
            let box = page.bounds(for: pdfView.displayBox)
            let points = Array(stroke.path)
            guard points.count >= 2 else { return nil }

            func canvasToView(_ p: CGPoint) -> CGPoint {
                let pagePoint = p.applying(InkGeometry.canvasFromPage.inverted())
                let pdfPoint = CGPoint(x: box.minX + pagePoint.x, y: box.maxY - pagePoint.y)
                return pdfView.convert(pdfPoint, from: page)
            }
            func viewToCanvas(_ v: CGPoint) -> CGPoint {
                let pdfPoint = pdfView.convert(v, to: page)
                let local = CGPoint(x: pdfPoint.x - box.minX, y: box.maxY - pdfPoint.y)
                return local.applying(InkGeometry.canvasFromPage)
            }

            // 所有采样点都要贴着尺线才吸附,避免把普通字迹拉直
            let tolerance: CGFloat = 18
            for point in points where ruler.distanceToLine(from: canvasToView(point.location)) > tolerance {
                return nil
            }
            let firstView = canvasToView(points[0].location)
            let lastView = canvasToView(points[points.count - 1].location)
            guard hypot(lastView.x - firstView.x, lastView.y - firstView.y) > 8 else { return nil }

            let projected = points.map { point -> PKStrokePoint in
                let onLine = viewToCanvas(ruler.projectOnLine(canvasToView(point.location)))
                return PKStrokePoint(location: onLine, timeOffset: point.timeOffset,
                                     size: point.size, opacity: point.opacity, force: point.force,
                                     azimuth: point.azimuth, altitude: point.altitude,
                                     secondaryScale: point.secondaryScale)
            }
            DiagLog.log("pencil: ruler snap page=\(index) angle=\(Int(ruler.angleDegrees))")
            let path = PKStrokePath(controlPoints: projected, creationDate: stroke.path.creationDate)
            return PKStroke(ink: stroke.ink, path: path, transform: .identity, mask: nil)
        }

        suppressNativeSelection(in: view)
        observeScrolling()
        applyToolSession(force: true) // The ruler view is installed after the ink host.
    }

    // MARK: - v0.28.0 全局湿墨(常规笔的跨页溢出段)

    /// 只有常规墨迹笔需要这层;橡皮/套索/形状/激光由各自的手势或预览层负责。
    private var wetToolIsRegular: Bool {
        guard let kind = toolSession?.kind else { return false }
        switch kind {
        case .pen, .brush, .pencil, .marker, .crayon: return true
        case .lasso, .shape, .laser, .eraser: return false
        }
    }

    private func beginWetStroke() {
        wetGeneration &+= 1
        wetActive = false
        wetLastDrawAt = 0
        wetStrokePoints.removeAll(keepingCapacity: true)
        // 切到橡皮/套索等非常规笔时立刻清掉上一笔的湿墨;否则上一笔的延迟清除会被
        // 这次 generation 递增作废,预览会一直留在屏幕上。常规笔则保留到新路径替换它,
        // 避免极快连写时上一笔的跨页溢出预览先消失一下。
        if !wetToolIsRegular { wetHost?.clear() }
    }

    private func appendWetSamples(_ viewPoints: [CGPoint]) {
        guard markMode, wetToolIsRegular, let pdfView, let session = toolSession else { return }
        // v0.33.0:观察者的 touchesEnded 不稳(日志里只有 begin、没有 end)→ 上一笔的湿墨
        // 会一直留在屏上。这里用采样间隔兜底:超过 1s 没新采样,就当作已经开始新一笔。
        let stamp = CFAbsoluteTimeGetCurrent()
        if wetActive, stamp - wetLastSampleAt > 1.0 { beginWetStroke() }
        wetLastSampleAt = stamp
        for viewPoint in viewPoints {
            if !wetActive {
                guard let page = pdfView.page(for: viewPoint, nearest: true) else { continue }
                wetPageIndex = pdfView.document?.index(for: page) ?? 0
                wetActive = true
                wetStrokePoints.removeAll(keepingCapacity: true)
                DiagLog.log("pencil: wet begin epoch=\(wetGeneration) page=\(wetPageIndex) tool=\(session.kind.rawValue)")
            }
            guard let doc = pdfView.document, wetPageIndex >= 0, wetPageIndex < doc.pageCount,
                  let page = doc.page(at: wetPageIndex) else { continue }
            let box = page.bounds(for: pdfView.displayBox)
            let inPage = pdfView.convert(viewPoint, to: page)
            let local = CGPoint(x: inPage.x - box.minX, y: box.maxY - inPage.y)
            // 超出画布四周出血的采样不会再被 PencilKit 保存,预览也不画,避免"抬手即消失"。
            // v0.29.0:左右也有出血(横向排布),x/y 两个方向都要卡。
            guard local.y >= -InkGeometry.bleedTop - 1,
                  local.y <= box.height + InkGeometry.bleed + 1,
                  local.x >= -InkGeometry.bleedX - 1,
                  local.x <= box.width + InkGeometry.bleedX + 1 else { continue }
            wetStrokePoints.append(local)
            if wetStrokePoints.count > 8192 {
                wetStrokePoints.removeFirst(wetStrokePoints.count - 8192)
            }
        }
        guard wetActive, wetStrokePoints.count >= 2 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - wetLastDrawAt >= 0.008 else { return }   // ~120Hz 上限
        wetLastDrawAt = now
        let path = UIBezierPath()
        path.move(to: wetStrokePoints[0])
        for point in wetStrokePoints.dropFirst() { path.addLine(to: point) }
        wetHost?.show(PencilWetStroke(
            pageIndex: wetPageIndex,
            path: path,
            color: session.currentUIColor,
            lineWidth: session.width,
            filled: false,
            clipOutsidePage: true
        ))
    }

    private func endWetStroke() {
        guard wetActive else { return }
        wetActive = false
        let generation = wetGeneration
        DiagLog.log("pencil: wet end epoch=\(generation) points=\(wetStrokePoints.count)")
        // 等提交/跨页搬运完成再撤掉湿墨,避免抬笔瞬间页缝外先“消失”再出现在邻页。
        // v0.29.0:0.18s 太紧 —— 跨页检查排在 0.10s,加上 drawingDidChange 的抖动,
        // 偶尔会先撤湿墨、后落位,视觉上就是页缝处闪一下缺口。放宽到 0.30s。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            guard let self, self.wetGeneration == generation else { return }
            self.wetHost?.clear()
            self.wetStrokePoints.removeAll(keepingCapacity: true)
        }
    }

    private func clearWetInk() {
        wetGeneration &+= 1
        wetActive = false
        wetStrokePoints.removeAll(keepingCapacity: true)
        wetHost?.clear()
    }

    /// v0.30.0:干墨层已经画出这一笔 → 立即撤掉湿墨预览,避免页外那段被两套渲染叠着画。
    /// 若新一笔已经开始(`wetActive` 还是 true),不要清它 —— 交给它自己的结束流程。
    private func clearWetAfterCommit() {
        // v0.33.0:不再因 `wetActive` 卡住。真机日志里 `wet end` 一次都没出现,
        // 说明观察者的结束回调不可靠 —— 湿墨预览会永久留一段"幽灵墨迹"在屏上。
        // 画布内容已经落定(干墨接手)就无条件清掉,预览至多早撤一帧。
        clearWetInk()
    }

    /// 停用 PDFKit 内置的选择手势(长按 / 双击)。保留滚动、缩放；链接改为选词菜单中明确打开。
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
                let isLinkTap = (gr as? UITapGestureRecognizer).map {
                    $0.numberOfTapsRequired == 1 && $0.numberOfTouchesRequired == 1
                } ?? false
                if isLinkTap {
                    // Preserve native controls (form fields etc.). A completed
                    // custom tap/press wins; native tap is available only when
                    // our recognizers deliberately decline the touch.
                    if let tapRef { gr.require(toFail:tapRef) }
                    if let fingerPressRef { gr.require(toFail:fingerPressRef) }
                    if let pencilPressRef { gr.require(toFail:pencilPressRef) }
                }
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
    private func beginDrag(kind: DragKind, page: PDFPage, anchorPoint: CGPoint, anchorWord: PDFSelection,
                           touchPoint: CGPoint, viewPoint: CGPoint, contextRoute: Bool = false) {
        drag = DragState(kind: kind, page: page, anchorPoint: anchorPoint, anchorWord: anchorWord,
                         lastPoint: touchPoint, contextRoute: contextRoute, didMove: false)
        lastTouchViewPoint = viewPoint
        freezeScrolling(true)
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        guard let pdfView else { return }
        let kind = Self.kind(of: gesture)
        guard !(markMode && kind == "pencil") else { return }
        let viewPoint = gesture.location(in: pdfView)

        switch gesture.state {
        case .began:
            hasUserInteracted = true
            clearHover()
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

            requestOCRCharacterRefinement(page: hit.page, at: hit.point)

            // ① 长按落在已有选区内 → 选区本体拖动微调(以远端为锚,与原生"按住选区拖动"一致)
            if let (page, lineRects) = orderedSelectionRects(),
               page === hit.page,
               let firstLine = lineRects.first, let lastLine = lineRects.last,
               lineRects.contains(where: { $0.contains(hit.point) }) {
                if contextReadingEnabled,
                   ocrSelectionActive,
                   let snapshot = pinnedSnapshot(for: page) {
                    let selectedRange = snapshot.selectedRange
                    let startAnchor = CGPoint(x: firstLine.minX + 0.6, y: firstLine.midY)
                    let endAnchor = CGPoint(x: lastLine.maxX - 0.6, y: lastLine.midY)
                    let nearerStart = SelectionGeometry.distanceSquared(hit.point, startAnchor)
                        <= SelectionGeometry.distanceSquared(hit.point, endAnchor)
                    let anchorIndex = nearerStart ? selectedRange.upperBound : selectedRange.lowerBound
                    ocrDrag = (page, snapshot.pageIndex, anchorIndex, false)
                    lastTouchViewPoint = viewPoint
                    freezeScrolling(true)
                    if kind == "finger" { loupe.begin(at: viewPoint, widget: nil, in: pdfView) }
                    scheduleHoldMenu()
                    DiagLog.log("press.began(\(kind)): context OCR body-drag")
                    return
                }
                let startAnchor = CGPoint(x: firstLine.minX + 0.6, y: firstLine.midY)
                let endAnchor = CGPoint(x: lastLine.maxX - 0.6, y: lastLine.midY)
                let nearerStart = SelectionGeometry.distanceSquared(hit.point, startAnchor)
                    < SelectionGeometry.distanceSquared(hit.point, endAnchor)
                let fixedPoint = nearerStart ? endAnchor : startAnchor
                guard let anchor = SelectionGeometry.initialCharacter(on:page,at:fixedPoint) else { return }
                beginDrag(kind: .body, page: page, anchorPoint: fixedPoint, anchorWord: anchor,
                          touchPoint: hit.point, viewPoint: viewPoint, contextRoute: contextReadingEnabled)
                if kind == "finger" {
                    loupe.begin(at: viewPoint, widget: nil, in: pdfView)
                }
                DiagLog.log("press.began(\(kind)): body-drag")
                return
            }

            // ② 新选词:文字层优先;无文字层(扫描版)走 OCR 词框(v0.11.0,M6)
            let t0 = CFAbsoluteTimeGetCurrent()
            let tolerance = min(8,6 / max(pdfView.scaleFactor,0.1))
            let wordSeed = SelectionGeometry.initialWord(on: hit.page, at: hit.point, tolerance: tolerance)
            let characterSeed = wordSeed == nil
                ? SelectionGeometry.initialCharacter(on: hit.page, at: hit.point, tolerance: tolerance)
                : nil
            if let word = wordSeed ?? characterSeed,
               SelectionGeometry.isSane(word, maxPages: 1, maxChars: 300) {
                DiagLog.log(String(format: "press.began(%@): word=「%@」 len=%d", kind,
                                   SelectionGeometry.logSnippet(word.string ?? ""), word.string?.count ?? 0))
                beginDrag(kind: .word, page: hit.page, anchorPoint: hit.point, anchorWord: word,
                          touchPoint: hit.point, viewPoint: viewPoint, contextRoute: contextReadingEnabled)
                applySelection(word, src: "own", contextRoute: contextReadingEnabled,
                               geometryQuality: wordSeed != nil ? .word : .approximate)
                if kind == "finger" {
                    loupe.begin(at: viewPoint, widget: nil, in: pdfView)
                }
                scheduleHoldMenu()
                return
            }
            // ②-b 扫描版 OCR 兜底
            if let wordIdx = ocrWordIndex(at: hit.point, on: hit.page) {
                DiagLog.log(String(format: "press.began(%@): ocr word #%d (%.0fms)", kind, wordIdx, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
                ocrDrag = (hit.page, currentPageIndexFor(page: hit.page), wordIdx, false)
                lastTouchViewPoint = viewPoint
                freezeScrolling(true)
                applyOCRSelection(page: hit.page, range: wordIdx...wordIdx, src: "began")
                if kind == "finger" {
                    loupe.begin(at: viewPoint, widget: nil, in: pdfView)
                }
                scheduleHoldMenu()
                return
            }
            DiagLog.log(String(format: "press.began(%@): no word (%.0fms)", kind, (CFAbsoluteTimeGetCurrent() - t0) * 1000))

        case .changed:
            if ocrDrag != nil {
                extendOCRDrag(to: viewPoint)
                updateAutoscroll(for: viewPoint)
                return
            }
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
            // Preserve the initially recognized whole word through touch jitter.
            // Character-granular adjustment starts only after a deliberate drag.
            guard d.didMove else { return }
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
            let isEnded = gesture.state == .ended
            if ocrDrag != nil {
                ocrDrag = nil
                holdMenuWork?.cancel()
                holdMenuWork = nil
                stopAutoscroll()
                loupe.end()
                freezeScrolling(false)
                DiagLog.log("press.end(\(kind)) ocr ended=\(isEnded)")
                refreshHandles()
                if isEnded, !selectionText.isEmpty {
                    if !menu.isPresented { presentMenu() }
                    if hapticsEnabled { PencilHaptics.selectionCompleted(at: viewPoint) }
                }
                return
            }
            let wasDrag = drag
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
            if isEnded, wasDrag != nil, !selectionText.isEmpty, hapticsEnabled {
                PencilHaptics.selectionCompleted(at: viewPoint)
            }

        default:
            break
        }
    }

    /// 按住不动 ~0.35s 后菜单先弹出(原生时机);一旦拖动立即取消(文字层与 OCR 路径共用)。
    private func scheduleHoldMenu() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.selectionText.isEmpty, !self.menu.isPresented else { return }
            let moved = (self.drag?.didMove ?? false) || (self.ocrDrag?.didMove ?? false)
            guard !moved else { return }
            self.presentMenu()
            DiagLog.log("menu presented (hold)")
        }
        holdMenuWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: - 悬停预览(v0.11.0,M4-B)

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard let pdfView else { return }
        // v0.23.0:无论选词还是书写模式都记录悬停位置 —— 挤压工具盘据此定位
        if gesture.state == .began || gesture.state == .changed {
            lastHoverViewPoint = gesture.location(in: pdfView)
            lastHoverAt = CFAbsoluteTimeGetCurrent()
        }
        guard hoverPreviewEnabled, !markMode else {
            clearHover()
            return
        }
        switch gesture.state {
        case .began, .changed:
            let viewPoint = gesture.location(in: pdfView)
            if let hit = pageHit(viewPoint),
               let word = SelectionGeometry.initialWord(on: hit.page, at: hit.point),
               let text = word.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, text.count <= 40 {
                let target = hoverContextForNativeWord(selection: word,
                                                       page: hit.page,
                                                       displaySurface: text)
                let term = target.phraseSurface ?? WordPicker.firstLexicalWord(in: text) ?? text
                let query = VocabStore.normalizedKey(term)
                guard !query.isEmpty,
                      let rect = hoverPageRect(for: hit.page, selection: target.selection) else {
                    clearHover()
                    return
                }
                publishHover(term: term,
                             query: query,
                             page: hit.page,
                             rect: rect,
                             contextual: target.contextual)
                return
            }

            if let hit = pageHit(viewPoint), let words = ocrWords(for: hit.page),
               let index = ocrWordIndex(at: hit.point, on: hit.page) {
                requestOCRCharacterRefinement(page: hit.page, entryIndex: index)
                let text = words[index].text
                let target = hoverContextForOCR(page: hit.page, index: index)
                let term = target?.phraseSurface ?? WordPicker.firstLexicalWord(in: text) ?? text
                let query = VocabStore.normalizedKey(term)
                guard !query.isEmpty,
                      let rect = target?.rect ?? hoverPageRect(for: hit.page, ocrWord: words[index]) else {
                    clearHover()
                    return
                }
                publishHover(term: term,
                             query: query,
                             page: hit.page,
                             rect: rect,
                             contextual: target?.contextual)
                return
            }
            clearHover()
        case .ended, .cancelled, .failed:
            clearHover()
        default:
            break
        }
    }

    private func publishHover(term: String,
                              query: String,
                              page: PDFPage,
                              rect: CGRect,
                              contextual: ContextualSelection?) {
        let rectChanged = setHoverAnnotation(page: page, rect: rect)
        let occurrenceKey = hoverOccurrenceKey(term: term,
                                               page: page,
                                               rect: rect,
                                               contextual: contextual)
        let keyChanged = occurrenceKey != hoverKey
        hoverKey = occurrenceKey
        guard keyChanged || rectChanged,
              let pdfView else { return }
        let viewRect = pdfView.convert(rect, from: page)
        onHoverUpdate?(term, query, CGPoint(x: viewRect.midX, y: viewRect.minY), contextual)
        if keyChanged { DiagLog.log("hover: 「\(term)」") }
    }

    private func hoverContextForNativeWord(selection: PDFSelection,
                                           page: PDFPage,
                                           displaySurface: String)
        -> (selection: PDFSelection, contextual: ContextualSelection?, phraseSurface: String?) {
        guard contextReadingEnabled,
              let pageIndex = pdfView?.document?.index(for: page), pageIndex >= 0,
              let base = ContextSelectionRouter.route(selection: selection,
                                                      page: page,
                                                      documentSHA256: docSha,
                                                      pageIndex: pageIndex,
                                                      displaySurface: displaySurface,
                                                      geometryQuality: .word,
                                                      generation: contextReadingGeneration) else {
            return (selection, nil, nil)
        }
        if let expansion = verifiedNativePhraseExpansion(seed: selection,
                                                         page: page,
                                                         baseContextual: base) {
            return (expansion.selection, expansion.contextual, expansion.phrase.sourceSurface)
        }
        return (selection, base, nil)
    }

    private func hoverContextForOCR(page: PDFPage, index: Int)
        -> (rect: CGRect?, contextual: ContextualSelection?, phraseSurface: String?)? {
        guard contextReadingEnabled,
              let pageIndex = pdfView?.document?.index(for: page), pageIndex >= 0 else { return nil }
        let source = pinnedSnapshot(for: page)?.contextSource
            ?? cachedContextOCRSource(for: page, pageIndex: pageIndex)
        guard let source,
              index >= 0, index < source.entries.count,
              source.page.lines.indices.contains(source.entries[index].lineIndex),
              let base = source.contextualSelection(for: index...index,
                                                    generation: contextReadingGeneration) else { return nil }
        if let expansion = verifiedOCRPhraseExpansion(page: page, index: index) {
            let rects = source.entries[expansion.range].map {
                OCRService.pageRect(from: $0.word, pageBounds: page.bounds(for: .mediaBox))
            }
            guard let first = rects.first else { return (nil, base, nil) }
            let union = rects.dropFirst().reduce(first) { $0.union($1) }
            return (SelectionGeometry.isValid(union) ? union : first,
                    expansion.contextual,
                    expansion.phrase.sourceSurface)
        }
        let rect = OCRService.pageRect(from: source.entries[index].word,
                                       pageBounds: page.bounds(for: .mediaBox))
        return (rect, base, nil)
    }

    private func cachedPhraseGroup(in context: SentenceContext,
                                   selectedSourceSpans: [UTF16Span],
                                   sourceText: String) -> VerifiedPhraseGroup? {
        if verifiedPhraseLookup == nil {
            verifiedPhraseLookup = VerifiedPhraseGroupLookup(
                dictionaryRevision: { DictionaryStore.shared.exactPhraseLookupRevision },
                exactPhraseExists: { DictionaryStore.shared.hasEnabledExactPhrase($0) }
            )
        }
        return verifiedPhraseLookup?.resolve(in: context,
                                             selectedSourceSpans: selectedSourceSpans,
                                             sourceText: sourceText)
    }

    private func verifiedNativePhraseExpansion(seed: PDFSelection,
                                               page: PDFPage,
                                               geometryQuality: SourceGeometryQuality = .word,
                                               baseContextual: ContextualSelection? = nil)
        -> (selection: PDFSelection, phrase: VerifiedPhraseGroup, contextual: ContextualSelection)? {
        guard let pageIndex = pdfView?.document?.index(for: page), pageIndex >= 0,
              let sourceText = page.string,
              let contextual = baseContextual
                ?? ContextSelectionRouter.route(selection: seed,
                                                page: page,
                                                documentSHA256: docSha,
                                                pageIndex: pageIndex,
                                                displaySurface: SelectionGeometry.lookupText(for: seed),
                                                geometryQuality: geometryQuality,
                                                generation: contextReadingGeneration),
              let sentenceContext = contextual.sentenceContext,
              contextual.sourceSpans.count == 1,
              let selectedSpan = contextual.sourceSpans.first,
              let phrase = cachedPhraseGroup(in: sentenceContext,
                                             selectedSourceSpans: [selectedSpan],
                                             sourceText: sourceText),
              let phraseRange = phrase.sourceSpan.nsRange(in: sourceText),
              let phraseSelection = page.selection(for: phraseRange),
              phraseSelection.pages.count == 1,
              phraseSelection.pages.first === page,
              SelectionGeometry.isSane(phraseSelection, maxPages: 1, maxChars: 80),
              SelectionGeometry.sourceRanges(of: phraseSelection, on: page) == [phraseRange],
              phraseSelection.selectionsByLine().count == 1,
              SelectionGeometry.isValid(SelectionGeometry.placedBounds(of: phraseSelection, on: page)),
              let expanded = ContextSelectionRouter.route(selection: phraseSelection,
                                                          page: page,
                                                          documentSHA256: docSha,
                                                          pageIndex: pageIndex,
                                                          displaySurface: phrase.sourceSurface,
                                                          geometryQuality: .word,
                                                          generation: contextReadingGeneration,
                                                          verifiedPhraseGroupSpan: phrase.sourceSpan),
              expanded.verifiedPhraseGroupSpan == phrase.sourceSpan,
              hasAdjacentNativeTokenGeometry(expanded.tokens, on: page) else { return nil }
        return (phraseSelection, phrase, expanded)
    }

    private func hasAdjacentNativeTokenGeometry(_ tokens: [SourceToken], on page: PDFPage) -> Bool {
        let ordered = tokens.sorted { $0.span.location < $1.span.location }
        guard ordered.count >= 2, ordered.allSatisfy({ $0.kind == .word }) else { return false }
        let rects: [CGRect] = ordered.compactMap { token in
            guard let range = token.span.nsRange(in: page.string ?? ""),
                  let selection = page.selection(for: range),
                  selection.pages.count == 1,
                  selection.pages.first === page,
                  selection.selectionsByLine().count == 1 else { return nil }
            let rect = SelectionGeometry.placedBounds(of: selection, on: page)
            return SelectionGeometry.isValid(rect) ? rect : nil
        }
        guard rects.count == ordered.count else { return false }
        for pair in zip(rects, rects.dropFirst()) {
            let maximumHeight = max(pair.0.height, pair.1.height)
            let horizontalGap = pair.1.minX - pair.0.maxX
            guard pair.1.midX > pair.0.midX,
                  abs(pair.0.midY - pair.1.midY) <= maximumHeight * 0.6,
                  horizontalGap >= -maximumHeight * 0.35,
                  horizontalGap <= maximumHeight * 1.5 else { return false }
        }
        return true
    }

    private func verifiedOCRPhraseExpansion(page: PDFPage, index: Int)
        -> (range: ClosedRange<Int>, phrase: VerifiedPhraseGroup, contextual: ContextualSelection)? {
        guard contextReadingEnabled,
              let pageIndex = pdfView?.document?.index(for: page), pageIndex >= 0,
              let source = pinnedSnapshot(for: page)?.contextSource
                ?? cachedContextOCRSource(for: page, pageIndex: pageIndex),
              source.entries.indices.contains(index),
              source.page.lines.indices.contains(source.entries[index].lineIndex),
              let base = source.contextualSelection(for: index...index,
                                                    generation: contextReadingGeneration),
              let sentenceContext = base.phraseLookupContext ?? base.sentenceContext,
              let selectedSpan = base.sourceSpans.first,
              let phrase = cachedPhraseGroup(in: sentenceContext,
                                             selectedSourceSpans: [selectedSpan],
                                             sourceText: source.page.lines[source.entries[index].lineIndex].sourceText),
              let range = source.entryRange(for: phrase.sourceSpan, containing: index),
              let contextual = source.contextualSelection(for: range,
                                                         generation: contextReadingGeneration,
                                                         verifiedPhraseGroupSpan: phrase.sourceSpan) else { return nil }
        return (range, phrase, contextual)
    }

    private func hoverOccurrenceKey(term: String,
                                    page: PDFPage,
                                    rect: CGRect,
                                    contextual: ContextualSelection?) -> String {
        let location: String
        if let contextual {
            let spans = contextual.sourceSpans.map { "\($0.location):\($0.length)" }.joined(separator: ",")
            location = "\(contextual.documentSHA256)|\(contextual.pageIndex)|\(contextual.generation)|\(spans)"
        } else {
            location = "\(ObjectIdentifier(page))|\(NSCoder.string(for: rect))"
        }
        return "\(term)|\(location)"
    }

    private func hoverPageRect(for page: PDFPage,
                               selection: PDFSelection? = nil,
                               ocrWord: OCRWord? = nil) -> CGRect? {
        let candidate: CGRect
        if let selection {
            candidate = SelectionGeometry.placedBounds(of: selection, on: page)
        } else if let ocrWord {
            candidate = OCRService.pageRect(from: ocrWord, pageBounds: page.bounds(for: .mediaBox))
        } else {
            return nil
        }
        let pageBounds = page.bounds(for: .mediaBox)
        guard SelectionGeometry.isValid(candidate),
              SelectionGeometry.isValid(pageBounds) else { return nil }
        let clipped = candidate.intersection(pageBounds)
        return SelectionGeometry.isValid(clipped) ? clipped : nil
    }

    @discardableResult
    private func setHoverAnnotation(page: PDFPage, rect: CGRect) -> Bool {
        if let entry = hoverEntry,
           entry.page === page,
           Self.hoverRectsMatch(entry.rect, rect) {
            return false
        }
        removeHoverAnnotation()
        guard SelectionGeometry.isValid(rect) else { return false }
        let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
        annotation.color = UIColor.systemYellow.withAlphaComponent(0.28)
        page.addAnnotation(annotation)
        hoverEntry = (page, rect, annotation)
        return true
    }

    private static func hoverRectsMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 0.5
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func removeHoverAnnotation() {
        if let entry = hoverEntry {
            entry.page.removeAnnotation(entry.annotation)
            hoverEntry = nil
        }
    }

    func clearHover() {
        verifiedPhraseLookup?.clear()
        guard hoverKey != "" || hoverEntry != nil else { return }
        hoverKey = ""
        removeHoverAnnotation()
        onHoverEnd?()
    }

    // MARK: - 扫描版 OCR 取词(v0.11.0,M6)

    /// 页面 OCR 词框(缓存 + 懒加载);未识别或无词返回 nil。
    private func ocrWords(for page: PDFPage) -> [OCRWord]? {
        guard !docSha.isEmpty,
              let idx = pdfView?.document?.index(for: page), idx >= 0 else { return nil }
        if contextReadingEnabled {
            if let pinned = pinnedSnapshot(for: page) {
                return pinned.words.isEmpty ? nil : pinned.words
            }
            if let source = cachedContextOCRSource(for: page, pageIndex: idx) {
                return source.words.isEmpty ? nil : source.words
            }
        }
        return legacyOCRWords(pageIndex: idx)
    }

    /// Installs only immutable OCR values for the current document/page/mode
    /// generation. This is cache-only: it does not redraw or emit a selection.
    @discardableResult
    func installContextOCRPage(_ page: ContextOCRPage, generation: Int) -> Bool {
        guard contextReadingEnabled,
              generation == contextReadingGeneration,
              !docSha.isEmpty,
              page.documentSHA256 == docSha,
              page.pageIndex >= 0,
              page.revision == ContextOCRPage.currentRevision,
              let document = pdfView?.document,
              page.pageIndex < document.pageCount,
              let pdfPage = document.page(at: page.pageIndex),
              let actualMediaBox = SourceRect(rect: pdfPage.bounds(for: .mediaBox)),
              mediaBoxesMatch(page.mediaBox, actualMediaBox) else { return false }
        var pageToInstall = page
        if let cached = contextOCRSourceCache[page.pageIndex] {
            if cached.generation == generation {
                pageToInstall = OCRCharacterGeometryComposer.mergePreservingVerifiedGeometry(
                    existing: cached.source.page,
                    incoming: page)
            }
            if cached.generation == generation, cached.source.page == pageToInstall {
                touchContextOCRCache(page.pageIndex)
                return true
            }
            if cached.source.page.revision > pageToInstall.revision { return false }
        }
        guard let source = ContextOCRSelectionSource(page: pageToInstall) else { return false }
        contextOCRSourceCache[page.pageIndex] = CachedContextOCRSource(source: source, generation: generation)
        touchContextOCRCache(page.pageIndex)
        return true
    }

    private func legacyOCRWords(pageIndex: Int) -> [OCRWord]? {
        guard let ocrStore, !docSha.isEmpty else { return nil }
        if let cached = ocrWordsCache[pageIndex] { return cached.isEmpty ? nil : cached }
        let words = ocrStore.words(docSha: docSha, page: pageIndex)
        ocrWordsCache[pageIndex] = words
        return words.isEmpty ? nil : words
    }

    private func cachedContextOCRSource(for page: PDFPage, pageIndex: Int) -> ContextOCRSelectionSource? {
        guard contextReadingEnabled,
              let cached = contextOCRSourceCache[pageIndex],
              cached.generation == contextReadingGeneration,
              cached.source.page.documentSHA256 == docSha,
              cached.source.page.pageIndex == pageIndex,
              pdfView?.document?.page(at: pageIndex) === page else { return nil }
        touchContextOCRCache(pageIndex)
        return cached.source
    }

    private func touchContextOCRCache(_ pageIndex: Int) {
        contextOCRCacheOrder.removeAll { $0 == pageIndex }
        contextOCRCacheOrder.append(pageIndex)
        while contextOCRCacheOrder.count > 8 {
            let evicted = contextOCRCacheOrder.removeFirst()
            contextOCRSourceCache.removeValue(forKey: evicted)
        }
    }

    private func clearContextOCRSourceCache() {
        contextOCRSourceCache.removeAll()
        contextOCRCacheOrder.removeAll()
        ocrCharacterRefinementInFlight.removeAll()
        completedOCRCharacterRefinements.removeAll()
        completedOCRCharacterRefinementOrder.removeAll()
        failedOCRCharacterRefinementsUntil.removeAll()
    }

    private func requestOCRCharacterRefinement(page: PDFPage, at pagePoint: CGPoint) {
        guard contextReadingEnabled,
              !markMode,
              onOCRCharacterRefinementRequested != nil,
              !docSha.isEmpty,
              let pageIndex = pdfView?.document?.index(for: page), pageIndex >= 0 else { return }

        let source: ContextOCRSelectionSource
        if let pinned = pinnedSnapshot(for: page) {
            guard let pinnedSource = pinned.contextSource else { return }
            source = pinnedSource
        } else if let cached = cachedContextOCRSource(for: page, pageIndex: pageIndex) {
            source = cached
        } else {
            return
        }
        guard source.page.documentSHA256 == docSha,
              source.page.pageIndex == pageIndex else { return }
        guard let index = ocrWordIndex(at: pagePoint, on: page) else { return }
        requestOCRCharacterRefinement(page: page, entryIndex: index)
    }

    private func requestOCRCharacterRefinement(page: PDFPage, entryIndex: Int) {
        guard contextReadingEnabled,
              !markMode,
              let callback = onOCRCharacterRefinementRequested,
              !docSha.isEmpty,
              let pageIndex = pdfView?.document?.index(for: page), pageIndex >= 0 else { return }

        let source: ContextOCRSelectionSource
        if let pinned = pinnedSnapshot(for: page) {
            guard let pinnedSource = pinned.contextSource else { return }
            source = pinnedSource
        } else if let cached = cachedContextOCRSource(for: page, pageIndex: pageIndex) {
            source = cached
        } else {
            return
        }
        guard source.page.documentSHA256 == docSha,
              source.page.pageIndex == pageIndex,
              source.entries.indices.contains(entryIndex) else { return }
        let entry = source.entries[entryIndex]
        guard source.page.lines.indices.contains(entry.lineIndex),
              source.page.lines[entry.lineIndex].tokens.contains(where: { $0.geometryQuality != .verifiedCharacter }) else { return }

        let request = ContextOCRRefinementRequest(documentSHA256: source.page.documentSHA256,
                                                  pageIndex: pageIndex,
                                                  blockID: entry.blockID,
                                                  generation: contextReadingGeneration)
        let target = OCRCharacterRefinementTarget(request)
        guard ocrCharacterRefinementInFlight[target] == nil,
              !completedOCRCharacterRefinements.contains(target) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        failedOCRCharacterRefinementsUntil = failedOCRCharacterRefinementsUntil.filter { $0.value > now }
        if let retryAt = failedOCRCharacterRefinementsUntil[target] {
            guard retryAt <= now else { return }
            failedOCRCharacterRefinementsUntil.removeValue(forKey: target)
        }

        ocrCharacterRefinementInFlight[target] = request.id
        callback(request)
    }

    func finishOCRCharacterRefinement(_ request: ContextOCRRefinementRequest,
                                      outcome: ContextOCRRefinementOutcome) {
        let target = OCRCharacterRefinementTarget(request)
        guard request.documentSHA256 == docSha,
              request.generation == contextReadingGeneration,
              contextReadingEnabled,
              ocrCharacterRefinementInFlight[target] == request.id else { return }
        ocrCharacterRefinementInFlight.removeValue(forKey: target)

        switch outcome {
        case .completed:
            failedOCRCharacterRefinementsUntil.removeValue(forKey: target)
            completedOCRCharacterRefinements.insert(target)
            completedOCRCharacterRefinementOrder.removeAll { $0 == target }
            completedOCRCharacterRefinementOrder.append(target)
            while completedOCRCharacterRefinementOrder.count > 128 {
                let expired = completedOCRCharacterRefinementOrder.removeFirst()
                completedOCRCharacterRefinements.remove(expired)
            }
        case .cancelled:
            failedOCRCharacterRefinementsUntil.removeValue(forKey: target)
        case .failed:
            failedOCRCharacterRefinementsUntil[target] = CFAbsoluteTimeGetCurrent() + 1.0
        }
    }

    private func mediaBoxesMatch(_ expected: SourceRect, _ actual: SourceRect) -> Bool {
        let tolerance = 0.01
        return abs(expected.x - actual.x) <= tolerance
            && abs(expected.y - actual.y) <= tolerance
            && abs(expected.width - actual.width) <= tolerance
            && abs(expected.height - actual.height) <= tolerance
    }

    private func pinnedSnapshot(for page: PDFPage) -> PinnedOCRSelectionSnapshot? {
        guard contextReadingEnabled,
              let index = pdfView?.document?.index(for: page), index >= 0,
              let snapshot = pinnedOCRSelection,
              snapshot.generation == contextReadingGeneration,
              snapshot.matches(page: page, pageIndex: index, documentSHA256: docSha) else { return nil }
        return snapshot
    }

    private func pinOCRSelectionSnapshot(page: PDFPage,
                                         range: ClosedRange<Int>) -> PinnedOCRSelectionSnapshot? {
        guard contextReadingEnabled,
              !docSha.isEmpty,
              let pageIndex = pdfView?.document?.index(for: page), pageIndex >= 0 else { return nil }
        var snapshot: PinnedOCRSelectionSnapshot
        if let current = pinnedOCRSelection,
           current.generation == contextReadingGeneration,
           current.matches(page: page, pageIndex: pageIndex, documentSHA256: docSha) {
            snapshot = current
        } else {
            let source = contextReadingEnabled ? cachedContextOCRSource(for: page, pageIndex: pageIndex) : nil
            guard let words = source?.words ?? legacyOCRWords(pageIndex: pageIndex), !words.isEmpty else { return nil }
            snapshot = PinnedOCRSelectionSnapshot(page: page,
                                                  pageIndex: pageIndex,
                                                  documentSHA256: docSha,
                                                  words: words,
                                                  contextSource: source,
                                                  generation: contextReadingGeneration,
                                                  selectedRange: range)
        }
        guard range.lowerBound >= 0, range.upperBound < snapshot.words.count else { return nil }
        snapshot.selectedRange = range
        pinnedOCRSelection = snapshot
        return snapshot
    }

    /// 页坐标点 → 当前页 OCR 词索引。
    private func ocrWordIndex(at pagePoint: CGPoint, on page: PDFPage) -> Int? {
        guard let words = ocrWords(for: page), !words.isEmpty else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        return OCRService.wordIndex(at: pagePoint, in: words, pageBounds: bounds)
    }

    private func currentPageIndexFor(page: PDFPage) -> Int {
        pdfView?.document?.index(for: page) ?? -1
    }

    #if DEBUG
    /// Read-only geometry snapshot for the DEBUG-only human-reading UI fixture.
    /// It reports PDF text/OCR data already owned by this reader and never selects text.
    func humanReadingAuditSnapshotJSON() -> String {
        guard let pdfView, let page = pdfView.currentPage else { return "{}" }
        let pageIndex = currentPageIndexFor(page: page)
        guard pageIndex >= 0 else { return "{}" }
        let pageBounds = page.bounds(for: .mediaBox)
        var wordPoints: [[String: Any]] = []
        var nativeWordRects: [(text: String, rect: CGRect)] = []
        var linePoints: [[String: Any]] = []
        let source = page.string ?? ""
        let sourceNSString = source as NSString

        func screenPoint(_ pagePoint: CGPoint) -> CGPoint? {
            let viewPoint = pdfView.convert(pagePoint, from: page)
            guard let window = pdfView.window else { return nil }
            return pdfView.convert(viewPoint, to: window)
        }

        func pointEntry(text: String, point: CGPoint, source: String) -> [String: Any] {
            ["text": text,
             "x": Double(point.x),
             "y": Double(point.y),
             "source": source]
        }

        func handleEntry(_ handle: SelectionHandleView?) -> [String: Any]? {
            guard let handle, !handle.isHidden, handle.alpha > 0.01,
                  let window = pdfView.window, handle.window === window else { return nil }
            let radius = HandleMetrics.dotDiameter / 2
            let dotCenter = CGPoint(
                x: handle.bounds.midX,
                y: handle.isStart ? handle.bounds.minY + radius : handle.bounds.maxY - radius
            )
            let point = handle.convert(dotCenter, to: window)
            return pointEntry(text: handle.isStart ? "start" : "end", point: point, source: "handle-dot")
        }

        func characterScreenPoint(at utf16Index: Int) -> CGPoint? {
            guard utf16Index >= 0, utf16Index < sourceNSString.length else { return nil }
            let characterRange = sourceNSString.rangeOfComposedCharacterSequence(at: utf16Index)
            guard let selection = page.selection(for: characterRange) else { return nil }
            let rect = selection.bounds(for: page)
            guard SelectionGeometry.isValid(rect) else { return nil }
            return screenPoint(CGPoint(x: rect.midX, y: rect.midY))
        }

        let wordPattern = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}αΑ²]+(?:[=^][\\p{L}\\p{N}αΑ²]+)*")
        for match in (wordPattern?.matches(in: source, range: NSRange(location: 0, length: sourceNSString.length)) ?? []).prefix(240) {
            guard match.range.length > 0,
                  let selection = page.selection(for: match.range) else { continue }
            let rect = selection.bounds(for: page)
            guard SelectionGeometry.isValid(rect), let point = screenPoint(CGPoint(x: rect.midX, y: rect.midY)) else { continue }
            let lastCharacterIndex = NSMaxRange(match.range) - 1
            guard let startPoint = characterScreenPoint(at: match.range.location),
                  let endPoint = characterScreenPoint(at: lastCharacterIndex) else { continue }
            let text = sourceNSString.substring(with: match.range)
            nativeWordRects.append((text, rect))
            var entry = pointEntry(text: text, point: point, source: "text")
            entry["startX"] = Double(startPoint.x)
            entry["startY"] = Double(startPoint.y)
            entry["endX"] = Double(endPoint.x)
            entry["endY"] = Double(endPoint.y)
            wordPoints.append(entry)
        }

        var lineStart = 0
        while lineStart < sourceNSString.length {
            let lineRange = sourceNSString.lineRange(for: NSRange(location: lineStart, length: 0))
            lineStart = NSMaxRange(lineRange)
            let trimmedLine = sourceNSString.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }
            let contentRange = sourceNSString.range(of: trimmedLine, options: [], range: lineRange)
            guard contentRange.location != NSNotFound,
                  let selection = page.selection(for: contentRange) else { continue }
            let rect = selection.bounds(for: page)
            guard SelectionGeometry.isValid(rect), let point = screenPoint(CGPoint(x: rect.midX, y: rect.midY)) else { continue }
            let text = sourceNSString.substring(with: contentRange)
            linePoints.append(pointEntry(text: text, point: point, source: "text"))
        }

        if let words = ocrWords(for: page) {
            for word in words.prefix(240) {
                let rect = OCRService.pageRect(from: word, pageBounds: pageBounds)
                guard SelectionGeometry.isValid(rect), let point = screenPoint(CGPoint(x: rect.midX, y: rect.midY)) else { continue }
                wordPoints.append(pointEntry(text: word.text, point: point, source: "ocr"))
            }
        }

        let linkPoints: [[String: Any]] = page.annotations.compactMap { annotation in
            guard annotation.type == "Link", SelectionGeometry.isValid(annotation.bounds),
                  let point = screenPoint(CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY)) else { return nil }
            let nearest = nativeWordRects.min {
                hypot($0.rect.midX - annotation.bounds.midX, $0.rect.midY - annotation.bounds.midY)
                    < hypot($1.rect.midX - annotation.bounds.midX, $1.rect.midY - annotation.bounds.midY)
            }
            return pointEntry(text: nearest?.text ?? "", point: point, source: "link")
        }

        let snapshot: [String: Any] = [
            "page": pageIndex,
            "scale": Double(pdfView.scaleFactor),
            "selectedText": selectionText,
            "wordPoints": wordPoints,
            "linePoints": linePoints,
            "linkPoints": linkPoints,
            "handlePoints": [handleEntry(startHandle), handleEntry(endHandle)].compactMap { $0 }
        ]
        guard JSONSerialization.isValidJSONObject(snapshot),
              let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
    #endif

    /// 识别全部完成后清缓存(宿主在 OCR 结束时调用,让下一页读取新数据)。
    func ocrDidFinish() {
        ocrWordsCache.removeAll()
        DiagLog.log("ocr: cache cleared")
    }

    /// OCR 词框选区(词粒度,范围 = 锚词…拖动词);与文字层路径共用高亮 / 拖柄 / 菜单。
    private func applyOCRSelection(page: PDFPage,
                                   range: ClosedRange<Int>,
                                   src: String,
                                   verifiedPhraseGroupSpan: UTF16Span? = nil) {
        guard let pdfView else { return }
        let snapshot: PinnedOCRSelectionSnapshot?
        let words: [OCRWord]
        if contextReadingEnabled {
            guard let pinned = pinOCRSelectionSnapshot(page: page, range: range) else { return }
            snapshot = pinned
            words = pinned.words
        } else {
            guard let legacyWords = ocrWords(for: page) else { return }
            snapshot = nil
            words = legacyWords
        }
        guard range.lowerBound >= 0, range.upperBound < words.count else { return }
        let sub = Array(words[range])
        let contextual: ContextualSelection?
        let text: String
        if contextReadingEnabled, let snapshot,
           snapshot.generation == contextReadingGeneration,
           let source = snapshot.contextSource {
            guard let selection = source.contextualSelection(for: range,
                                                             generation: snapshot.generation,
                                                             verifiedPhraseGroupSpan: verifiedPhraseGroupSpan) else { return }
            contextual = selection
            text = selection.displaySurface
        } else {
            contextual = nil
            text = sub.map { $0.text.components(separatedBy:.whitespacesAndNewlines).joined() }.joined(separator: " ")
        }
        guard !text.isEmpty else { return }
        lastAnySelectionChangeTime = CFAbsoluteTimeGetCurrent()
        let bounds = page.bounds(for: .mediaBox)
        var desired: [String: (page: PDFPage, rect: CGRect)] = [:]
        var rejected = 0
        for wz in sub {
            let rect = OCRService.pageRect(from: wz, pageBounds: bounds)
            guard SelectionGeometry.isValid(rect), rect.intersects(bounds.insetBy(dx: -24, dy: -24)) else {
                rejected += 1
                continue
            }
            desired[annotationKey(page, rect)] = (page, rect)
        }
        let revision = snapshot?.contextSource?.page.revision ?? 0
        appliedKey = "ocr|\(docSha)|\(currentPageIndexFor(page: page))|\(revision)|\(range.lowerBound)-\(range.upperBound)|\(text)"
        appliedCharCount = text.count
        selectionText = text
        ocrSelectionActive = true
        if contextReadingEnabled, let source = snapshot?.contextSource {
            ocrContextOverride = source.fullLineContext(for: range)
        } else {
            let lineIdx = sub.first?.line ?? -1
            ocrContextOverride = words.filter { $0.line == lineIdx }.map { $0.text }.joined(separator: " ")
        }
        applyHighlightDesired(desired, rejected: rejected, t0: CFAbsoluteTimeGetCurrent())
        refreshHandles()
        let display = text.count > 400 ? String(text.prefix(400)) + "…" : text
        let wordCount = SelectionGeometry.isSingleWordText(text) ? 1:WordPicker.countWords(in:text)
        let primaryTerm = WordPicker.firstLexicalWord(in: text) ?? ""
        onSelectionInfo(SelectionInfo(text: display, wordCount: wordCount, primaryTerm: primaryTerm,
                                      contextual: contextual))
        if wordCount <= 1, !primaryTerm.isEmpty {
            vocabDidSelectWord(term: primaryTerm)
        }
        DiagLog.log("ocr.select(\(src)): 「\(SelectionGeometry.logSnippet(text))」")
        resuppressSoon()
    }

    /// OCR 拖动扩选(词粒度;跨行自动并集)。
    private func extendOCRDrag(to viewPoint: CGPoint) {
        guard let od = ocrDrag, let pdfView,
              let hit = pageHit(viewPoint), hit.page === od.page,
              let curIdx = ocrWordIndex(at: hit.point, on: od.page) else { return }
        lastTouchViewPoint = viewPoint
        guard curIdx != od.anchorIdx else { return }
        ocrDrag?.didMove = true
        holdMenuWork?.cancel()
        holdMenuWork = nil
        menu.dismiss()
        let range = min(od.anchorIdx, curIdx)...max(od.anchorIdx, curIdx)
        applyOCRSelection(page: od.page, range: range, src: "drag")
        loupe.move(to: viewPoint)
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
            if contextReadingEnabled,
               ocrSelectionActive,
               let existing = pinnedOCRSelection,
               let snapshot = pinnedSnapshot(for: existing.page) {
                let anchorIndex = isStart ? snapshot.selectedRange.upperBound : snapshot.selectedRange.lowerBound
                ocrDrag = (snapshot.page, snapshot.pageIndex, anchorIndex, false)
                lastTouchViewPoint = viewPoint
                freezeScrolling(true)
                let pencil = (gesture as? PencilAwarePanGestureRecognizer)?.isPencilDriven ?? false
                if !pencil {
                    loupe.begin(at: viewPoint, widget: isStart ? startHandle : endHandle, in: pdfView)
                }
                DiagLog.log("handle.drag began context OCR isStart=\(isStart) pencil=\(pencil)")
                return
            }
            guard let (page, lineRects) = orderedSelectionRects(),
                  let firstLine = lineRects.first, let lastLine = lineRects.last else { return }
            // v0.8.3:lineRects 为显示矩形;锚点仍取"原始文字边缘"内侧 0.6pt(与扩边前行为一致)
            let fixedPoint = isStart
                ? CGPoint(x: HandleMetrics.lineRect(fromDisplay: lastLine).maxX - 0.6, y: lastLine.midY)
                : CGPoint(x: HandleMetrics.lineRect(fromDisplay: firstLine).minX + 0.6, y: firstLine.midY)
            guard let anchor = SelectionGeometry.initialCharacter(on:page,at:fixedPoint) else { return }
            drag = DragState(kind: isStart ? .handleStart : .handleEnd,
                             page: page, anchorPoint: fixedPoint, anchorWord: anchor, lastPoint: fixedPoint,
                             contextRoute: contextReadingEnabled, didMove: true)
            lastTouchViewPoint = viewPoint
            freezeScrolling(true)
            let pencil = (gesture as? PencilAwarePanGestureRecognizer)?.isPencilDriven ?? false
            if !pencil {
                loupe.begin(at: viewPoint, widget: isStart ? startHandle : endHandle, in: pdfView)
            }
            DiagLog.log("handle.drag began isStart=\(isStart) pencil=\(pencil)")

        case .changed:
            if contextReadingEnabled, ocrDrag != nil {
                extendOCRDrag(to: viewPoint)
                updateAutoscroll(for: viewPoint)
                return
            }
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
            if contextReadingEnabled, ocrDrag != nil {
                let isEnded = gesture.state == .ended
                ocrDrag = nil
                holdMenuWork?.cancel()
                holdMenuWork = nil
                stopAutoscroll()
                loupe.end()
                freezeScrolling(false)
                DiagLog.log("handle.drag end context OCR ended=\(isEnded)")
                refreshHandles()
                if isEnded, !selectionText.isEmpty, !menu.isPresented { presentMenu() }
                if isEnded, !selectionText.isEmpty, hapticsEnabled {
                    PencilHaptics.selectionCompleted(at: viewPoint)
                }
                return
            }
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
            if gesture.state == .ended, !selectionText.isEmpty, hapticsEnabled {
                PencilHaptics.selectionCompleted(at: viewPoint)
            }

        default:
            break
        }
    }

    /// 把拖动的活动端延伸到指定落点(供手势 .changed 与贴边自动滚动共用)。
    private func extendDrag(to hit: (page: PDFPage, point: CGPoint), viewPoint: CGPoint) {
        guard let d = drag, hit.page === d.page else { return }
        if let selection = selectionBetween(d, and: hit.point) {
            applySelection(selection, src: "own", contextRoute: d.contextRoute, geometryQuality: .approximate)
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
            if let link = page.annotations.first(where: { VocabPDFView.hasTapAction($0) && $0.type != "Widget" && $0.bounds.contains(pagePoint) }),
               let view = pdfView as? VocabPDFView {
                jumpGuardUntil = CFAbsoluteTimeGetCurrent() + 2
                clearSelection()
                view.openLink(link)
                return
            }
            // 命中判定留宽容差(行间隙/选区边缘的点击都算"点选区")
            let onSelection = rects.contains { $0.page === page && $0.rect.contains(pagePoint) }
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
        _ = selectText(at: viewPoint, source: "doubleTap")
    }

    @discardableResult
    private func selectText(at viewPoint: CGPoint, source: String) -> Bool {
        guard let pdfView, let hit = pageHit(viewPoint) else { return false }
        let tolerance = min(8, 6 / max(pdfView.scaleFactor, 0.1))
        let link = hit.page.annotations.contains { VocabPDFView.hasTapAction($0) && $0.bounds.contains(hit.point) }
        let roundTrip = pdfView.convert(hit.point, from: hit.page)
        DiagLog.log(String(format: "selection.hit: source=%@ page=%d view=(%.1f,%.1f) pdf=(%.1f,%.1f) scale=%.3f roundTrip=%.3f link=%d",
            source, currentPageIndexFor(page: hit.page), viewPoint.x, viewPoint.y,
            hit.point.x, hit.point.y, pdfView.scaleFactor, hypot(roundTrip.x-viewPoint.x,roundTrip.y-viewPoint.y), link ? 1 : 0))
        let wordSeed = SelectionGeometry.initialWord(on: hit.page, at: hit.point, tolerance: tolerance)
        let characterSeed = wordSeed == nil
            ? SelectionGeometry.initialCharacter(on: hit.page, at: hit.point, tolerance: tolerance)
            : nil
        if let selection = wordSeed ?? characterSeed {
            DiagLog.log("selection.result: source=\(source) text=「\(SelectionGeometry.logSnippet(selection.string ?? ""))」")
            let geometryQuality: SourceGeometryQuality = wordSeed != nil ? .word : .approximate
            let phraseExpansion = source == "doubleTap" && contextReadingEnabled
                ? verifiedNativePhraseExpansion(seed: selection,
                                                page: hit.page,
                                                geometryQuality: geometryQuality)
                : nil
            if let phraseExpansion {
                DiagLog.log("context.phrase.expand=pdf")
                applySelection(phraseExpansion.selection,
                               src: source,
                               contextRoute: true,
                               geometryQuality: .word,
                               verifiedPhraseGroupSpan: phraseExpansion.phrase.sourceSpan)
            } else {
                applySelection(selection,
                               src: source,
                               contextRoute: contextReadingEnabled,
                               geometryQuality: geometryQuality)
            }
            refreshHandles()
            presentMenu()
            if hapticsEnabled { PencilHaptics.selectionCompleted(at: viewPoint) }
            return true
        }
        if let idx = ocrWordIndex(at: hit.point, on: hit.page) {
            if source == "doubleTap", contextReadingEnabled,
               let expansion = verifiedOCRPhraseExpansion(page: hit.page, index: idx) {
                DiagLog.log("context.phrase.expand=ocr")
                applyOCRSelection(page: hit.page,
                                  range: expansion.range,
                                  src: source,
                                  verifiedPhraseGroupSpan: expansion.phrase.sourceSpan)
            } else {
                applyOCRSelection(page: hit.page, range: idx...idx, src: source)
            }
            refreshHandles()
            presentMenu()
            return true
        }
        DiagLog.log("selection.miss: source=\(source) page=\(currentPageIndexFor(page: hit.page))")
        return false
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
        if hapticsEnabled { PencilHaptics.selectionCompleted(at: viewPoint) }
    }

    // MARK: - 选区应用 / 高亮

    private func applySelection(_ selection: PDFSelection,
                                src: String,
                                contextRoute: Bool = false,
                                geometryQuality: SourceGeometryQuality = .approximate,
                                verifiedPhraseGroupSpan: UTF16Span? = nil) {
        let text = SelectionGeometry.lookupText(for:selection)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastAnySelectionChangeTime = CFAbsoluteTimeGetCurrent()
        if !contextReadingEnabled {
            ocrSelectionActive = false
            ocrContextOverride = nil
        }
        guard SelectionGeometry.isSane(selection, maxPages: 1, maxChars: 6_000) else {
            // v0.6.6:坏帧只记录、**不清空现有选区**(拖动中偶发解析异常时保留上一个好状态)
            DiagLog.log("applySelection rejected(\(src)): pages=\(selection.pages.count) len=\(text.count)")
            return
        }
        if contextReadingEnabled {
            pinnedOCRSelection = nil
            ocrDrag = nil
            ocrSelectionActive = false
            ocrContextOverride = nil
        }
        let pageIndex = selection.pages.first.flatMap { pdfView?.document?.index(for: $0) } ?? -1
        let key = "\(pageIndex)|\(SelectionGeometry.identity(for: selection))|\(text)"
        guard key != appliedKey else { return }
        appliedKey = key
        appliedCharCount = text.count
        selectionText = text
        updateHighlight(for: selection)
        refreshHandles()
        let display = text.count > 400 ? String(text.prefix(400)) + "…" : text
        let wordCount = SelectionGeometry.isSingleWordText(text) ? 1:WordPicker.countWords(in:text)
        let primaryTerm = WordPicker.firstLexicalWord(in: text) ?? ""
        let contextual: ContextualSelection? = {
            guard contextRoute, contextReadingEnabled, pageIndex >= 0,
                  let page = selection.pages.first else { return nil }
            return ContextSelectionRouter.route(selection: selection,
                                                page: page,
                                                documentSHA256: docSha,
                                                pageIndex: pageIndex,
                                                displaySurface: text,
                                                geometryQuality: geometryQuality,
                                                generation: contextReadingGeneration,
                                                verifiedPhraseGroupSpan: verifiedPhraseGroupSpan)
        }()
        onSelectionInfo(SelectionInfo(
            text: display,
            wordCount: wordCount,
            primaryTerm: primaryTerm,
            contextual: contextual
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
            var lineRects = lineSelections.map { SelectionGeometry.placedBounds(of:$0,on:page) }
            if lineRects.isEmpty { lineRects = [selection.bounds(for: page)] }
            for rect in lineRects {
                guard SelectionGeometry.isValid(rect) else { rejected += 1; continue }
                guard rect.intersects(pageBounds.insetBy(dx: -24, dy: -24)) else { rejected += 1; continue }
                desired[annotationKey(page, rect)] = (page, rect)
            }
        }
        applyHighlightDesired(desired, rejected: rejected, t0: t0)
    }

    /// 差量应用高亮(v0.11.0 抽出:文字层选区与 OCR 词框共用)。
    private func applyHighlightDesired(_ desired: [String: (page: PDFPage, rect: CGRect)], rejected: Int, t0: CFAbsoluteTime) {
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

    private func clearSelection(notifySelection: Bool = true) {
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
        ocrDrag = nil
        pinnedOCRSelection = nil
        ocrSelectionActive = false
        ocrContextOverride = nil
        clearHover()
        clearTempHighlight()
        refreshHandles()
        if notifySelection { onSelectionInfo(nil) }
        resuppressSoon()
    }

    /// Explicitly coordinated by ReaderView.onChange, outside updateUIView.
    /// Clearing only transient selection layers leaves saved vocabulary
    /// highlights and Pencil ink untouched.
    func setContextReadingMode(_ enabled: Bool, generation: Int) {
        guard generation > contextReadingGeneration else { return }
        contextReadingEnabled = enabled
        contextReadingGeneration = generation
        drag = nil
        clearContextOCRSourceCache()
        clearSelection(notifySelection: false)
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
        ocrDrag = nil
        pinnedOCRSelection = nil
        ocrSelectionActive = false
        ocrContextOverride = nil
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
    @discardableResult
    func collectWord(key: String, surface: String) -> Bool {
        guard let vocabStore, !docSha.isEmpty else { return false }
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
            return false
        }
        reloadPermanentHighlights()
        if hapticsEnabled { PencilHaptics.collected(at: lastTouchViewPoint) }
        DiagLog.log("vocab: collect 「\(surface)」(\(key)) rects=\(useRects.count) page=\(page)")
        return true
    }

    // MARK: - 编辑栏「生词本」(v0.10.0,Task 2.1)

    /// 当前选区的首个词(键 + 原形);无词返回 nil。
    private func menuWord() -> (key: String, surface: String)? {
        guard let term = WordPicker.firstLexicalWord(in: selectionText), !term.isEmpty else { return nil }
        return (VocabStore.normalizedKey(term), term)
    }

    private func currentSelectionVocabState() -> (collected: Bool, colorName: String?) {
        guard let vocabStore, let word = menuWord() else { return (collected: false, colorName: nil) }
        return (collected: vocabStore.entryId(forLemma: word.key) != nil,
                colorName: vocabStore.highlightColorName(forLemma: word.key))
    }

    private func collectFromMenu() {
        guard let word = menuWord() else { return }
        collectWord(key: word.key, surface: word.surface)
    }

    /// 高亮隐含收录(高亮数据挂在词条上);已收录则直接换色。
    private func highlightFromMenu(colorName: String) {
        guard let word = menuWord(), let vocabStore else { return }
        if vocabStore.entryId(forLemma: word.key) == nil {
            collectWord(key: word.key, surface: word.surface)
        }
        setHighlightColor(key: word.key, colorName: colorName)
    }

    private func removeHighlightFromMenu() {
        guard let word = menuWord() else { return }
        removeWordHighlights(key: word.key)
    }

    /// v0.13.2(紧急修复):标记模式下把**滚动视图自己的 pan** 触型收紧为「仅手指」,
    /// Pencil 触摸不再被滚动接管,全部落到页叠层画布;同时关闭滚动视图的触摸延迟,
    /// 让画布立即收到 Pencil(不吞笔画起手)。
    ///
    /// ⚠️ v0.13.1 崩溃复盘(严禁重蹈):此前给 PDFView 内部手势**替换 delegate** 触发真机闪退——
    /// UIScrollView / PDFKit 的内部手势由 UIKit 私有机制管理,delegate 被换成自定义对象后,
    /// 内部代码向"假定的私有类型"发消息 → EXC_BAD_ACCESS / unrecognized selector → 闪退。
    /// 现在只用两个**公开安全属性**,绝不触碰任何 delegate:
    /// ① `scroll.panGestureRecognizer.allowedTouchTypes = [.direct]`(禁 Pencil 滚动);
    /// ② `scroll.delaysContentTouches = false`(画布立即收笔,不被 150ms 滚动判定吞掉起手)。
    /// 收集**全部** UIScrollView(不只第一个)、跳过页叠层画布子树;逐条记账、退出还原;
    /// 幂等重臂(setMarkMode 冗余调用 / documentDidLoad / documentDidChange / pageDidChange)。
    private func setScrollPanPencilExcluded(_ excluded: Bool) {
        guard let pdfView else { return }
        if excluded {
            var newlyArmed = 0
            for scroll in PencilTouchIsolation.scrollViews(in: pdfView) {
                scroll.isDirectionalLockEnabled = false
                let pan = scroll.panGestureRecognizer
                let id = ObjectIdentifier(pan)
                guard armedScrollPans[id] == nil else { continue }
                guard pan.state == .possible else { continue }   // 正在跟踪中的手势别动,等下一轮重臂
                armedScrollPans[id] = (pan, scroll, pan.allowedTouchTypes, scroll.delaysContentTouches)
                pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                scroll.delaysContentTouches = false
                newlyArmed += 1
            }
            if newlyArmed > 0 {
                DiagLog.log("pencil: isolation armed +\(newlyArmed) (total \(armedScrollPans.count))")
                NSLog("[yuewen/pencil] isolation armed +%d (total %d)", newlyArmed, armedScrollPans.count)
            }
        } else if !armedScrollPans.isEmpty {
            let count = armedScrollPans.count
            for (_, armed) in armedScrollPans {
                armed.pan.allowedTouchTypes = armed.originalTouchTypes
                armed.scroll.delaysContentTouches = armed.originalDelays
            }
            armedScrollPans.removeAll()
            DiagLog.log("pencil: isolation restored (\(count))")
            NSLog("[yuewen/pencil] isolation restored (%d)", count)
        }
    }

    /// v0.8.2:原句提取(整句语境;无文本层/失败时回退选中文本,再回退词面)。
    private func sentenceContextOrSelection(surface: String) -> String {
        if ocrSelectionActive, let ocrLine = ocrContextOverride, !ocrLine.isEmpty {
            DiagLog.log("context: ocr line len=\(ocrLine.count)")
            return ocrLine
        }
        if let (page, lineRects) = orderedSelectionRects(),
           let first = lineRects.first, let last = lineRects.last,
           let sentence = SentenceExtractor.sentenceContext(firstLine: first, lastLine: last, on: page) {
            DiagLog.log("context: sentence len=\(sentence.count)")
            return sentence
        }
        let fallback = selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? surface : fallback
    }

    /// (v0.10.0 起「已掌握」概念整体移除;取消高亮改由编辑栏「生词本 → 取消高亮」承担)
    /// 删除某词的全部高亮(v0.8.0;保留词条与语境)。

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

    /// v0.9.0(M4):标记 / 阅读模式切换——标记模式下 Pencil 交给画布(Pencil 专属选区手势让位),
    /// 手指的滚动/缩放/长按选词两种模式都保留;切到标记模式时清掉当前选区。
    func setMarkMode(_ on: Bool) {
        // v0.28.0:PDFView 会在加载/翻页/重排时重建内部层级,湿墨层每次都要重新置顶;
        // 若它被移出层级(极端情况)也补挂回去。
        if let wetHost, let pdfView {
            if wetHost.superview == nil { pdfView.addSubview(wetHost) }
            pdfView.bringSubviewToFront(wetHost)
        }
        // v0.35.0:尺子层也要每次重新置顶(它必须盖在墨迹之上,否则被墨盖住)
        if let rulerOverlay, let pdfView {
            if rulerOverlay.superview == nil { pdfView.addSubview(rulerOverlay) }
            pdfView.bringSubviewToFront(rulerOverlay)
        }
        // v0.40.1:单画布只在书写模式接管触摸;阅读模式整层穿透,
        // 否则会挡住长按选词、拖柄拖动与 Pencil 悬停查词。
        inkSurface?.setDrawingEnabled(on)
        metalHost?.isDrawingEnabled = on
        let changed = markMode != on
        markMode = on
        (pdfView as? VocabPDFView)?.handwritingMode = on
        // v0.13.1(紧急修复):值未变也要幂等重臂 —— PDFView 加载文档/翻页/重排会重建内部
        // 手势层级,一次性设置会被顶掉;SwiftUI 每次 updateUIView 都走这里,天然成为重臂时机。
        pencilPressRef?.isEnabled = !on
        guard changed else {
            if on { setScrollPanPencilExcluded(true) }
            return
        }
        clearHover()
        if !on {
            stopAutoScroll()
            clearWetInk()
            inkSurface?.setRulerActive(false)
            overlayProvider?.setRulerActive(false)
            setRulerOverlayVisible(false)   // v0.35.0:退出书写时收起尺子
        }
        overlayProvider?.setMarkMode(on)
        // v0.25.1:进入书写时**强制**套用一次工具 —— 只靠签名去重的话,重进文档时
        // 笔具 kind 与上次相同(比如橡皮/形状)→ 一次都不 apply → 画布根本没被"装上"
        // 那种工具(日志里重进后 eraser=0、且再无 apply tool= 行),表现就是"工具没记忆"。
        if on { applyToolSession(force: true) }
        pencilPressRef?.isEnabled = !on
        let types: [NSNumber] = on
            ? [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            : [NSNumber(value: UITouch.TouchType.direct.rawValue),
               NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        tapRef?.allowedTouchTypes = types
        doubleTapRef?.allowedTouchTypes = types
        tripleTapRef?.allowedTouchTypes = types
        setScrollPanPencilExcluded(on)   // v0.13.2:标记模式下 Pencil 滚动隔离(仅公开属性,见函数注释)
        NSLog("[yuewen/pencil] setMarkMode -> %@", on ? "mark" : "select")
        if on, !selectionText.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.clearSelection() }
        }
        DiagLog.log("pencil: markMode=\(on)")
    }

    // MARK: - v0.14.0:手写工具 / 撤销重做

    /// 把工具会话当前笔具套到所有页画布(调色盘 / 笔宽变化时由 SwiftUI onChange 调用;幂等)。
    /// v0.16.1(卡死修复):
    /// ① **签名去重**——工具没变就完全不碰 PencilKit(此前 `updateUIView` 每帧都重建工具);
    /// ② **延迟到下一个 runloop**——绝不在 SwiftUI 更新/手势回调里同步改 `PKCanvasView.tool`
    ///    (在 PencilKit 自己的回调里改工具、或在布局过程中改,都可能把主线程锁死)。
    private var surfaceDocSha: String?
    private var surfaceInkLoaded = false

    /// v0.40.2:文档装载后再补一次旧墨迹迁移 —— install 阶段 `view.document` 还是 nil,
    /// 逐页迁移循环会被整体跳过(用户的老笔记会看起来「全丢了」)。
    private func loadSurfaceInkIfNeeded(docSha: String) {
        // v0.44.0:墨迹按页存(页面坐标),由 surface.pageDrawingProvider 懒加载,
        // 这里只负责在文档就绪后重算一次窗口。
        guard !surfaceInkLoaded else { return }
        surfaceInkLoaded = true
        inkSurface?.refreshWindow()
    }

    private var inkSurface: DocumentInkSurface?
    /// v0.46.0:自研 Metal 墨迹宿主(设置开关 metalInk)
    private var metalHost: MetalInkHost?
    private var engineSession: DocumentInkEngineSession?
    private let nativeEditorID = UUID()
    private var nativeInkObserver: NSObjectProtocol?

    /// v0.40.0:装上文档级单画布,并把历史"每页一画布"的墨迹合并进文档坐标系。
    private func installInkSurface(on view: PDFView, docSha: String) {
        view.pageOverlayViewProvider = nil
        if surfaceDocSha != docSha { engineSession = nil }
        // v0.46.0:自研 Metal 墨迹(默认关,设置里可开)
        let engine = engineSession ?? DocumentInkEngineSession.acquire(docSha:docSha,prefersMetal:UserDefaults.standard.bool(forKey:"metalInk"),containsMetal:{ self.inkStore?.containsMetalPages(docSha:docSha) ?? false })
        engineSession = engine
        if engine.metal {
            // v0.47.0:复用同一个宿主 —— 重进文档/重装时若每次 new 一个,
            // pdfView 上会叠出第二块画布(两套墨迹、两份落库)。
            let host = metalHost ?? MetalInkHost()
            metalHost = host
            // 自研引擎接管墨迹时,旧 PencilKit 逐页叠层必须摘掉:
            // 留着它 = 两个引擎同时吃笔、同时落库,墨迹重影且撤销/擦除互相打架。
            view.pageOverlayViewProvider = nil
            host.attach(to: view, store: inkStore, docSha: docSha)
            host.isDrawingEnabled = markMode
            surfaceDocSha = docSha
            surfaceInkLoaded = true
            DiagLog.log("surface: metal engine enabled")
            return
        }
        let surface = DocumentInkSurface()
        inkSurface = surface
        surfaceDocSha = docSha
        surface.attach(to: view)
        surface.setDrawingEnabled(markMode)

        // 每页墨迹(页面坐标)懒加载
        surface.pageDrawingProvider = { [weak self] page in
            guard let self, let store = self.inkStore,
                  let record = store.drawing(docSha: docSha, page: page),
                  let saved = try? PKDrawing(data: record.data) else { return nil }
            var result = saved
            if record.scale != 1 { result.transform(using:CGAffineTransform(scaleX:1/max(1,record.scale),y:1/max(1,record.scale))) }
            return result
        }
        // 抬笔切割后按页落库
        surface.onPageInkDelta = { [weak self] page, before, after in
            guard let self else { return false }
            return self.inkStore?.mergeNative(docSha:docSha,page:page,before:before,after:after,source:self.nativeEditorID) ?? false
        }
        if let nativeInkObserver { NotificationCenter.default.removeObserver(nativeInkObserver) }
        nativeInkObserver = NotificationCenter.default.addObserver(forName:PencilInkStore.didChange,object:nil,queue:.main) { [weak self,weak surface] note in
            guard let self,note.object as? String == docSha,note.userInfo?["source"] as? String != self.nativeEditorID.uuidString else { return }
            surface?.reloadStoredInk()
        }
        surface.refreshWindow()
        DiagLog.log("surface: enabled (per-page ink)")
    }

    func applyToolSession(force: Bool = false) {
        guard let session = toolSession else { return }
        let revision = session.stateRevision
        if !force, revision == appliedToolRevision { return }
        // v0.40.0:单画布模式先套工具(它不经过 provider 的逐页画布)
        inkSurface?.applyTool(session.makeTool(scale: DocumentInkSurface.scale))
        // v0.47.0:自研 Metal 引擎也要吃工具颜色/笔宽(否则调色盘与笔宽档对它无效)
        metalHost?.applyTool(kind: session.kind, color: session.currentUIColor,
                             baseWidth: session.width, eraserRadius: session.eraserRadius,
                             whole: session.eraserWhole, shape: session.shapeKind)
        if !wetToolIsRegular { clearWetInk() }
        // provider 未就绪时**不记版本**,留给建好之后的下一次调用
        guard let provider = overlayProvider else { return }
        appliedToolRevision = revision
        let start = CFAbsoluteTimeGetCurrent()

        // v0.32.0:**全部同步执行**。v0.28–v0.30 把 `canvas.tool` 的赋值丢进
        // `DispatchQueue.main.async`,并且在排队前就记下"已套用版本";那一刻 provider
        // 还没建好时任务直接 return,此后无人重套 —— 画布永久停在初始化保底黑笔,
        // 真机表现就是"除橡皮和直尺外所有工具都只有黑笔效果"。
        // ① 模式标志/手势开关/形状参数(立即生效)
        provider.applyModeState(session.state)
        // ② 笔具本身(同步赋值;签名/版本去重已在上面,不会每帧重设)
        let tool = session.makeTool(scale: InkGeometry.scale)
        provider.setTool(tool)
        // ③ 直尺:自绘、固定在视口中线(v0.35.0)。PencilKit 自带直尺没有定位 API、
        //    只会跟着页面一起滚,所以永久关掉它,改用我们自己的尺子层。
        let rulerOn = session.rulerActive && markMode
        inkSurface?.setRulerActive(rulerOn)
        provider.setRulerActive(rulerOn && inkSurface == nil && metalHost == nil)
        setRulerOverlayVisible(rulerOn && metalHost != nil)
        metalHost?.strokeProjector = { [weak self] point in
            self?.rulerOverlay?.projector(startingAt: point)
        }

        metalHost?.strokeProjectionDidEnd = { [weak self] in self?.rulerOverlay?.finishMeasurement() }
        let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        DiagLog.log("pencil: apply ink=\(Self.inkSummary(tool)) kind=\(session.kind.rawValue) w=\(String(format: "%.1f", session.width)) ruler=\(session.rulerActive ? 1 : 0) err=\(session.eraserWhole ? 1 : 0) took=\(ms)ms")
    }

    /// 只在书写模式显示；开启时居中，之后保持文档坐标中的位置与角度。
    private func setRulerOverlayVisible(_ on: Bool) {
        guard let ruler = rulerOverlay else { return }
        ruler.bindDocument(pdfView?.documentView)
        // v0.38.0:关闭→开启时回到屏幕正中、角度归零(需求:只有重开才重置位置)
        if on, !ruler.isOn { ruler.resetInHost() }
        ruler.isOn = on
        if on { pdfView?.bringSubviewToFront(ruler) }
    }

    /// 诊断用:把真正赋给画布的笔具打印出来(墨型 + 颜色 + 宽度),
    /// 真机上"工具没生效"和"生效了但没渲染"靠这一行区分。
    private static func inkSummary(_ tool: PKTool) -> String {
        if let inking = tool as? PKInkingTool {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            inking.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let hex = String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
            return "\(inking.inkType.rawValue):\(hex):\(String(format: "%.1f", inking.width))"
        }
        return String(describing: type(of: tool))
    }

    // MARK: - v0.18.0 书写贴边自动滚动(连续书写第一步)

    /// Pencil 在屏幕上移动 → 靠近上下边缘时滚动 PDF,写到底不必抬手去滑。
    /// 只读取 Pencil 位置(PencilTouchObserver 永不识别手势),不干扰 PencilKit 绘制。
    private func pencilMoved(to point: CGPoint) {
        guard markMode, let pdfView else { return }
        let enabled = (UserDefaults.standard.object(forKey: "writingAutoScroll") as? Bool) ?? true
        guard enabled else { return }
        let height = pdfView.bounds.height
        guard height > 100 else { return }
        let edge: CGFloat = 90
        if point.y > height - edge {
            let t = min((point.y - (height - edge)) / edge, 1)
            autoScrollSpeed = 700 * t
        } else if point.y < edge {
            let t = min((edge - point.y) / edge, 1)
            autoScrollSpeed = -700 * t
        } else {
            stopAutoScroll()
            return
        }
        startAutoScroll()
    }

    private func startAutoScroll() {
        guard autoScrollLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(stepAutoScroll(_:)))
        link.add(to: .main, forMode: .common)
        autoScrollLink = link
    }

    private func stopAutoScroll() {
        autoScrollLink?.invalidate()
        autoScrollLink = nil
        autoScrollSpeed = 0
    }

    @objc private func stepAutoScroll(_ link: CADisplayLink) {
        guard markMode, autoScrollSpeed != 0, let pdfView else {
            stopAutoScroll()
            return
        }
        if autoScrollView == nil {
            autoScrollView = PencilTouchIsolation.scrollViews(in: pdfView).first
        }
        guard let scroll = autoScrollView else { return }
        let minY = -scroll.adjustedContentInset.top
        let maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        guard maxY > minY else { return }
        let dt = max(link.targetTimestamp - link.timestamp, 1.0 / 120.0)
        let next = min(max(scroll.contentOffset.y + autoScrollSpeed * CGFloat(dt), minY), maxY)
        guard abs(next - scroll.contentOffset.y) > 0.1 else { return }
        scroll.contentOffset = CGPoint(x: scroll.contentOffset.x, y: next)
    }

    // MARK: - v0.18.0 缩放

        /// v0.23.2:PDFKit 在设置 document / 切换 displayMode 之后会把 `maxScaleFactor` 重置回
        /// 内部默认值(真机反馈「800% 以上无区别」就是被夹回上限)。任何改缩放前先重设上下限。
        private func applyZoomLimits(_ view: PDFView) {
            // v0.35.0:用户要求「缩进最低只有 100%」—— 下限就是 1.0,不许再小。
            // 之前是 0.2;PDFKit 还会把下限悄悄恢复成 1.0,所以每次缩放都要重新钉一遍。
            if abs(view.minScaleFactor - 1.0) > 0.001 { view.minScaleFactor = 1.0 }
            if abs(view.maxScaleFactor - 40) > 0.001 { view.maxScaleFactor = 40 }
        }

        /// 设置缩放;若仍被 PDFKit 夹回(上限被内部重置),把上限提到目标值再试一次并记日志。
        private func setScale(_ target: CGFloat, on view: PDFView, tag: String) {
            applyZoomLimits(view)
            let clamped = min(max(target, view.minScaleFactor), view.maxScaleFactor)
            view.scaleFactor = clamped
            if view.scaleFactor < clamped - 0.05 {
                view.maxScaleFactor = max(view.maxScaleFactor, target)
                view.scaleFactor = target
            }
            DiagLog.log("zoom[\(tag)]: want=\(String(format: "%.2f", target)) got=\(String(format: "%.2f", view.scaleFactor)) max=\(String(format: "%.2f", view.maxScaleFactor))")
        }

        /// 适应宽度(PDFView 的 autoScales 是整页适应,这里按当前页宽度算)
        func zoomToFitWidth() {
            guard let pdfView, let page = pdfView.currentPage else { return }
            let pageWidth = page.bounds(for: pdfView.displayBox).width
            guard pageWidth > 1, pdfView.bounds.width > 1 else { return }
            pdfView.autoScales = false
            setScale((pdfView.bounds.width - 24) / pageWidth, on: pdfView, tag: "fit")
        }

        /// 100% = 1 PDF 点对 1 屏幕点
        func zoomToPercent(_ percent: CGFloat) {
            guard let pdfView else { return }
            pdfView.autoScales = false
            setScale(percent / 100, on: pdfView, tag: "\(Int(percent))%")
        }

    var canUndoInk: Bool { metalHost?.canUndo ?? inkSurface?.canUndo ?? false }
    var canRedoInk: Bool { metalHost?.canRedo ?? inkSurface?.canRedo ?? false }
    func undoInk() {
        // v0.47.0:自研 Metal 引擎有自己的撤销栈(它不经过 PencilKit 的 undoManager)
        if let host = metalHost { host.undo(); return }
        // v0.40.0:单画布有自己的 undoManager(一笔一步),优先用它
        if let surface = inkSurface { surface.undo(); return }
        clearWetInk()
        overlayProvider?.undo()
    }
    func redoInk() {
        if let host = metalHost { host.redo(); return }
        if let surface = inkSurface { surface.redo(); return }
        clearWetInk()
        overlayProvider?.redo()
    }

    // v0.15.0:双指轻点 = 撤销、三指轻点 = 重做(Notability 手势;仅标记模式生效)
    // v0.16.2:手掌误触防护 —— 刚落笔/擦除后的 0.35s 内忽略(真机日志出现过「30 笔一次变 10 笔」,
    // 怀疑是手掌/双指误触把大批笔迹一起撤销)。
    @objc private func handleInkUndoTap(_ gesture: UITapGestureRecognizer) {
        guard markMode else { return }
        let idle = CFAbsoluteTimeGetCurrent() - lastInkActivityAt
        guard idle > 0.35 else {
            DiagLog.log("pencil: undo tap ignored (last stroke \(Int(idle * 1000))ms ago)")
            return
        }
        DiagLog.log("pencil: undo tap (2-finger)")
        undoInk()
        PencilHaptics.selectionCompleted(at: lastTouchViewPoint)
    }

    // v0.16.0:四指轻点 = 专注模式(也用于退出;手势只收手指,不影响 Pencil 书写)
    @objc private func handleFocusTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onFocusToggle?()
        DiagLog.log("reader: focus toggle (4-finger tap)")
    }

    @objc private func handleInkRedoTap(_ gesture: UITapGestureRecognizer) {
        guard markMode else { return }
        DiagLog.log("pencil: redo tap (3-finger)")
        redoInk()
        PencilHaptics.selectionCompleted(at: lastTouchViewPoint)
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
                // v0.13.0:已收录词再次选中 → 在新位置补永久高亮(重复位置自动去重)
                let colorName = vocabStore.highlightColorName(forLemma: key) ?? "blue"
                vocabStore.addHighlight(wordId: wordId, docSha: docSha, page: page, rectsJSON: rectsJSON, colorName: colorName)
                DispatchQueue.main.async {
                    self?.reloadPermanentHighlights()
                }
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

    // MARK: - 已收录词自动加亮(v0.13.0,P0;设置开关,按页扫描一次)

    /// 扫描当前页文本,把命中的「已收录词」补成永久高亮(页坐标;每页每会话一次)。
    func autoHighlightCurrentPage() {
        guard UserDefaults.standard.bool(forKey: "autoHighlightCollected"),
              let pdfView, let vocabStore, !docSha.isEmpty,
              let page = pdfView.currentPage,
              let pageIndex = pdfView.document?.index(for: page),
              !autoHighlightDonePages.contains(pageIndex) else { return }
        autoHighlightDonePages.insert(pageIndex)
        let now = CFAbsoluteTimeGetCurrent()
        if now - vocabLemmaCacheTime > 5 {
            vocabLemmaCache = vocabStore.allLemmas()
            vocabLemmaCacheTime = now
        }
        guard !vocabLemmaCache.isEmpty else { return }
        guard let text = page.string, !text.isEmpty else { return }
        let ns = text as NSString
        let regex = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z'’-]*")
        let matches = regex?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
        var hits: [(lemma: String, range: NSRange)] = []
        var seen = Set<String>()
        for match in matches {
            let token = ns.substring(with: match.range).lowercased()
            guard vocabLemmaCache.contains(token), !seen.contains(token) else { continue }
            seen.insert(token)
            hits.append((token, match.range))
            if hits.count >= 40 { break }
        }
        guard !hits.isEmpty else { return }
        let pageBounds = page.bounds(for: pdfView.displayBox)
        var added = 0
        for hit in hits {
            guard let wordId = vocabStore.entryId(forLemma: hit.lemma),
                  let selection = page.selection(for: hit.range) else { continue }
            let rawRects = selection.selectionsByLine().prefix(4).map { $0.bounds(for: page) }
            let rects = rawRects.filter {
                SelectionGeometry.isValid($0) && $0.intersects(pageBounds.insetBy(dx: -24, dy: -24))
            }
            guard !rects.isEmpty else { continue }
            // 圆整到 0.01pt,保证重复扫描时 JSON 完全一致(去重命中)
            let rounded = rects.map { rect in
                CGRect(
                    x: (rect.minX * 100).rounded() / 100,
                    y: (rect.minY * 100).rounded() / 100,
                    width: (rect.width * 100).rounded() / 100,
                    height: (rect.height * 100).rounded() / 100
                )
            }
            let colorName = vocabStore.highlightColorName(forLemma: hit.lemma) ?? "blue"
            vocabStore.addHighlight(
                wordId: wordId, docSha: docSha, page: pageIndex,
                rectsJSON: VocabStore.rectsToJSON(rounded), colorName: colorName
            )
            added += 1
        }
        if added > 0 {
            reloadPermanentHighlights()
            DiagLog.log("autohl: page \(pageIndex) +\(added) words")
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
        (pdfView as? VocabPDFView)?.refreshLinkOutlines()
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
        sv.isDirectionalLockEnabled = false
        sv.panGestureRecognizer.minimumNumberOfTouches = 1
        for handle in [startHandle,endHandle].compactMap({ $0 }) {
            for pan in handle.gestureRecognizers ?? [] { sv.panGestureRecognizer.require(toFail:pan) }
        }
        scrollObservers.append(sv.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            sv.isDirectionalLockEnabled = false
            self.rulerOverlay?.bindDocument(self.pdfView?.documentView)
            self.rulerOverlay?.syncDocumentPose()
            self.refreshHandles()
            self.menu.updatePosition(animated: false)   // v0.6.10:滚动后菜单随选区同步
            self.dryHost?.refresh()                      // v0.30.0:跨页干墨跟随滚动
            if let ruler = self.rulerOverlay, ruler.isOn, let pdfView = self.pdfView {
                pdfView.bringSubviewToFront(ruler)       // v0.35.0:尺子永远在最上层
            }
            self.overlayProvider?.refreshRulerFocus()    // v0.32.0:直尺跟随焦点页
            if sv.isDragging || sv.isDecelerating {
                self.hasUserInteracted = true
            }
            self.fireReadingTick()
        })
        scrollObservers.append(sv.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in
            self?.rulerOverlay?.bindDocument(self?.pdfView?.documentView)
            self?.rulerOverlay?.syncDocumentPose()
            self?.refreshHandles()
            self?.menu.updatePosition(animated: false)  // v0.6.10:缩放后菜单随选区同步
            self?.dryHost?.refresh()                    // v0.30.0:跨页干墨跟随缩放
            self?.overlayProvider?.refreshRulerFocus()  // v0.32.0:直尺跟随焦点页
            // v0.34.0:真机反馈「缩到 100% 就下不去」——PDFKit 会把 minScaleFactor 悄悄恢复成 1.0,
            // 而捏合缩放不触发 SwiftUI 更新,`updateUIView` 里那句重设永远等不到。
            // 这里每次缩放都重新放开上下限(只改限值、不动当前比例,不干扰手势)。
            if let view = self?.pdfView {
                if !sv.isZooming && !sv.isZoomBouncing { self?.applyZoomLimits(view) }
                if view.scaleFactor < 1.2 {
                    DiagLog.log("zoom[pinch]: s=\(String(format: "%.2f", view.scaleFactor)) min=\(String(format: "%.2f", view.minScaleFactor)) max=\(String(format: "%.2f", view.maxScaleFactor)) auto=\(view.autoScales ? 1 : 0)")
                }
            }
            self?.fireReadingTick()
        })
        scrollObservers.append(pdfView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            self?.rulerOverlay?.updateHostBounds()
            self?.rulerOverlay?.bindDocument(self?.pdfView?.documentView)
            self?.rulerOverlay?.syncDocumentPose()
            self?.refreshHandles()
            self?.menu.updatePosition(animated: false)  // v0.6.10:旋转/布局变化后菜单随选区同步
            self?.dryHost?.refresh()                    // v0.30.0:旋转/分屏后页矩形变化
            self?.overlayProvider?.refreshRulerFocus()  // v0.32.0:直尺跟随焦点页
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
            setScale(CGFloat(state.zoom), on: pdfView, tag: "restore")
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

    // MARK: - v0.23.0 缩略图 / 双页 / 清空本页

    /// 供缩略图面板读取(面板只需要页数与页面,不持有 PDFView)
    var document: PDFDocument? { pdfView?.document }

    /// v0.23.2:页面排布 —— 纵向连续 / 横向连续。
    /// v0.30.0:**取消双页并排**(`twoUp`):所有页始终以一张连续长纸显示,
    /// 旧设置里的 "twoUp" 一律回落到纵向连续。
    /// 切换 displayMode 会重置缩放上限,所以切完重新放开并恢复原缩放。
    func setLayoutMode(_ raw: String) {
        guard let pdfView else { return }
        let scale = pdfView.scaleFactor
        let auto = pdfView.autoScales
        switch raw {
        case "horizontal":
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .horizontal
        default:
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
        }
        // v0.26.0:切 displayMode 后 PDFKit 会把页影/分隔线/边距恢复默认 —— 每次切完都重新钉住,
        // 保证「所有页 = 一张长纸」这件事在任何排布下都成立。
        pdfView.pageShadowsEnabled = false
        pdfView.displaysPageBreaks = false
        pdfView.pageBreakMargins = .zero
        applyZoomLimits(pdfView)
        if !auto { pdfView.scaleFactor = scale }
        // v0.33.0:排布方向变了,跨页搬页的方向跟着变
        overlayProvider?.flowAxis = pdfView.displayDirection == .horizontal ? .horizontal : .vertical
        dryHost?.refresh()   // v0.30.0:页矩形随排布变化,跨页干墨重算位置
        DiagLog.log("display: layout=\(raw)")
    }

    /// 清空当前页手写(程序化改画布,登记一条撤销)
    func clearCurrentPageInk() {
        guard let pdfView, let page = pdfView.currentPage,
              let index = pdfView.document?.index(for: page) else { return }
        let cleared: Bool
        if let metalHost { cleared = metalHost.clearPage(index) }
        else if let inkSurface { cleared = inkSurface.clearPage(index) }
        else { cleared = overlayProvider?.clearInk(pageIndex:index) ?? false }
        DiagLog.log("pencil: clear page \(index) -> \(cleared ? 1 : 0)")
    }
    func retrySavingInk() {
        metalHost?.retrySavingInk()
        inkSurface?.retrySavingInk()
    }

    // MARK: - 拖选计算(纯点坐标 + 词粒度)

    /// 拖动扩选:v0.6.6 起 **字符粒度优先、词粒度兜底**(用户要求"一个字母一个字母地拖动")——
    /// ① 先试字符粒度:终点直接取原始触点(`selection(from:to:)` 在最近的字符边界收口);
    /// ② 若解析异常(损坏文档上 point-pair 可能返回非法选区)→ 用词边界点重试;
    /// ③ 全部失败返回 nil(保持上一个好选区,不清空)。
    private func selectionBetween(_ dragState: DragState, and current: CGPoint) -> PDFSelection? {
        if dragState.contextRoute {
            if dragState.kind == .word && !dragState.didMove { return dragState.anchorWord }
            return contextualSelectionBetween(dragState, and: current)
        }
        if dragState.kind == .word && !dragState.didMove { return dragState.anchorWord }
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
        if let currentWord = SelectionGeometry.initialWord(on:page,at:current) ?? SelectionGeometry.initialCharacter(on:page,at:current) {
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

    /// Context mode routes a drag through complete source ranges from trusted
    /// visual seeds. It never treats point-pair geometry as a whole-token hit.
    private func contextualSelectionBetween(_ dragState: DragState, and current: CGPoint) -> PDFSelection? {
        let page = dragState.page
        guard let source = page.string,
              let anchor = contextualSeed(on: page, at: dragState.anchorPoint),
              let target = contextualSeed(on: page, at: current),
              let anchorStart = anchor.ranges.map(\.location).min(),
              let targetStart = target.ranges.map(\.location).min(),
              let anchorEnd = anchor.ranges.map({ $0.location + $0.length }).max(),
              let targetEnd = target.ranges.map({ $0.location + $0.length }).max() else { return nil }

        let location = min(anchorStart, targetStart)
        let end = max(anchorEnd, targetEnd)
        let completeRange = NSRange(location: location, length: end - location)
        guard UTF16Span(range: completeRange, in: source) != nil,
              let selection = page.selection(for: completeRange),
              SelectionGeometry.isSane(selection, maxPages: 1, maxChars: 6_000),
              let selectedText = selection.string, !selectedText.isEmpty else { return nil }
        let selectedRanges = SelectionGeometry.sourceRanges(of: selection, on: page)
        guard !selectedRanges.isEmpty,
              (anchor.ranges + target.ranges).allSatisfy({ rangeIsCovered($0, by: selectedRanges) }) else { return nil }
        return selection
    }

    /// Words are preferred; punctuation, symbols, and other glyphs can still
    /// be selected as a conservative character seed.
    private func contextualSeed(on page: PDFPage, at point: CGPoint) -> (selection: PDFSelection, ranges: [NSRange])? {
        func validatedSeed(_ candidate: PDFSelection?) -> (selection: PDFSelection, ranges: [NSRange])? {
            guard let candidate,
                  SelectionGeometry.isSane(candidate, maxPages: 1, maxChars: 300) else { return nil }
            let ranges = SelectionGeometry.sourceRanges(of: candidate, on: page)
            guard !ranges.isEmpty else { return nil }
            return (candidate, ranges)
        }
        if let word = validatedSeed(SelectionGeometry.initialWord(on: page, at: point)) { return word }
        return validatedSeed(SelectionGeometry.initialCharacter(on: page, at: point))
    }

    private func rangeIsCovered(_ target: NSRange, by ranges: [NSRange]) -> Bool {
        let targetEnd = target.location + target.length
        var cursor = target.location
        for range in ranges.sorted(by: { $0.location < $1.location }) where NSMaxRange(range) > cursor {
            guard range.location <= cursor else { return false }
            cursor = max(cursor, NSMaxRange(range))
            if cursor >= targetEnd { return true }
        }
        return false
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
        guard drag != nil || (contextReadingEnabled && ocrDrag != nil),
              let pdfView, let sv = pdfScrollView(pdfView) else { return }
        let height = pdfView.bounds.height
        guard height > 1 else { return }
        let edge: CGFloat = 64
        var speed: CGFloat = 0
        if touchViewPoint.y < edge {
            speed = -(edge - touchViewPoint.y) / edge * 7
        } else if touchViewPoint.y > height - edge {
            speed = (touchViewPoint.y - (height - edge)) / edge * 7
        }
        let availableContentHeight = sv.contentSize.height
            + sv.adjustedContentInset.top + sv.adjustedContentInset.bottom
        let canScroll = availableContentHeight > sv.bounds.height + 1
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
        guard drag != nil || (contextReadingEnabled && ocrDrag != nil),
              let pdfView, let sv = pdfScrollView(pdfView) else {
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
        if contextReadingEnabled, ocrDrag != nil {
            extendOCRDrag(to: lastTouchViewPoint)
        } else if let hit = pageHit(lastTouchViewPoint) {
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
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if menu.containsToolbar(touch.view) { return false }
        // A drawing Pencil (including laser) cannot enter any selection path.
        if markMode && touch.type == .pencil { return false }
        if markMode && toolSession?.kind == .laser { return false }
        if gestureRecognizer.view is SelectionHandleView { return true }
        if touch.view is InkEditingOverlay { return false }
        if gestureRecognizer === tapRef, let pdfView,
           let hit = pageHit(touch.location(in:pdfView)),
           hit.page.annotations.contains(where: { $0.type == "Widget" && $0.bounds.contains(hit.point) }) {
            return false // Preserve native form control activation on a short tap.
        }
        // A nearby handle's 44pt drag target must not swallow a new double/triple tap.
        let multiTap = (gestureRecognizer as? UITapGestureRecognizer).map { $0.numberOfTapsRequired >= 2 } ?? false
        if !multiTap, let pdfView, handleHitTest(touch.location(in:pdfView)) { return false }
        if gestureRecognizer === fingerPressRef || gestureRecognizer === pencilPressRef,
           let pdfView,
           let hit = pageHit(touch.location(in: pdfView)) {
            requestOCRCharacterRefinement(page: hit.page, at: hit.point)
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer.view is SelectionHandleView || otherGestureRecognizer.view is SelectionHandleView { return false }
        // A press selecting linked text and a tap activating it are mutually exclusive.
        if gestureRecognizer is UITapGestureRecognizer || otherGestureRecognizer is UITapGestureRecognizer { return false }
        return true
    }
}

// MARK: - v0.13.2(紧急修复):标记模式 Pencil 输入独占(只动公开安全开关)

/// 滚动视图收集:PDFView 整棵子树内全部 UIScrollView,
/// 但**跳过页叠层画布子树**(PKCanvasView 自己的滚动与手势绝不触碰)。
///
/// 为什么只动滚动视图、且绝不碰 delegate(v0.13.1 真机闪退根因):
/// 系统手势的 delegate 是 UIKit 私有对象,替换它会破坏内部契约(向假定类型发消息)直接闪退。
/// 这里只使用两个公开属性:`panGestureRecognizer.allowedTouchTypes` 与 `delaysContentTouches`。
enum PencilTouchIsolation {
    static func scrollViews(in root: UIView) -> [UIScrollView] {
        var result: [UIScrollView] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ view: UIView) {
            if view is InkOverlayView || view is PKCanvasView { return }
            if let scroll = view as? UIScrollView, seen.insert(ObjectIdentifier(scroll)).inserted {
                result.append(scroll)
            }
            for sub in view.subviews { visit(sub) }
        }
        visit(root)
        return result
    }
}

// MARK: - v0.14.0:Apple Pencil 系统手势映射

extension ReaderCoordinator: UIPencilInteractionDelegate {
    /// Pencil 轻点两下:可在设置里映射为「橡皮 ⇄ 上一支笔 / 撤销 / 关闭」
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard markMode, let session = toolSession else { return }
        let action = UserDefaults.standard.string(forKey: "pencilDoubleTapAction") ?? "eraser"
        switch action {
        case "undo":
            DiagLog.log("pencil: double-tap -> undo")
            undoInk()
        case "off":
            DiagLog.log("pencil: double-tap ignored (off)")
        default:
            session.toggleEraser()
            applyToolSession()
            DiagLog.log("pencil: double-tap tool=\(session.kind.rawValue)")
        }
    }

    /// Pencil Pro 挤压:一次打开弧形工具盘,再挤一次收起(设置里可改为橡皮/关闭)
    /// v0.16.2(真机日志证据):挤压是**持续事件** —— 按住会连续回调(0.7s 内 20 次)。
    /// v0.19.0:改为只响应 `.began`(每次挤压一次),再用 0.25s 去重;回调里不做重活。
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .began, ReaderSqueezeGate.shared.accept() else { return }
        let action = UserDefaults.standard.string(forKey: "pencilSqueezeAction") ?? "arc"
        guard action != "off" else {
            DiagLog.log("pencil: squeeze ignored (off)")
            return
        }
        if action == "eraser", markMode, let session = toolSession {
            session.toggleEraser()
            applyToolSession()
            PencilHaptics.selectionCompleted(at: lastTouchViewPoint)
            DiagLog.log("pencil: squeeze -> eraser")
            return
        }
        // v0.23.0:优先用 Pencil Pro 悬停位置(3 秒内),把工具盘开在笔尖处;否则退回最近触摸点
        let hoverFresh = CFAbsoluteTimeGetCurrent() - lastHoverAt < 3.0 && lastHoverViewPoint != .zero
        let point: CGPoint
        if let location = squeeze.hoverPose?.location {
            point = location
        } else if hoverFresh {
            point = lastHoverViewPoint
        } else {
            point = CGPoint(x: pdfView?.bounds.midX ?? 0, y: pdfView?.bounds.midY ?? 0)
        }
        PencilHaptics.selectionCompleted(at: point)
        DiagLog.log("pencil: squeeze -> arc menu at \(Int(point.x)),\(Int(point.y)) \(hoverFresh ? "hover" : "touch")")
        onPencilSqueeze?(point)
    }
}
