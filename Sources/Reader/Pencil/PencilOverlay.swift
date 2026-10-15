import UIKit
import PencilKit
import PDFKit

/// Pencil 标记层(v0.9.0,M4):
/// - `PencilOverlayProvider` 经 `PDFView.pageOverlayViewProvider` 为**每一页**叠加一个画布容器;
/// - 画布为 `PKCanvasView`(`drawingPolicy = .pencilOnly`),只接受 Pencil;
/// - **选词模式**:容器 `hitTest` 一律返回 nil → 触摸(手指与 Pencil)全部穿透给 PDFView,选区逻辑原样;
/// - **标记模式**:容器只接 `touch.type == .pencil`(手指仍穿透,滚动/缩放/长按选词不受影响);
/// - 手写数据按 (docSha, page) 存 SQLite(`pencil_ink`),**不改动原 PDF**;停笔 0.8s 防抖落盘。
///
/// 坐标约定:画布尺寸 = 该页 PDF 尺寸(页坐标 pt)。PDFView 会把叠加层随缩放一起变换,
/// 因此手写笔迹在任意缩放档位应对齐(真机验证项:一档画、换档看是否贴合)。
final class PencilOverlayProvider: NSObject, PDFPageOverlayViewProvider {
    private weak var pdfView: PDFView?
    private let docSha: String
    private let inkStore: PencilInkStore?
    private(set) var markMode: Bool
    private var overlays: [Int: InkOverlayView] = [:]
    /// 自持工具面板(不共享:iOS 14 起 `PKToolPicker.shared(for:)` 已废弃)
    private let toolPicker = PKToolPicker()

    init(pdfView: PDFView?, docSha: String, inkStore: PencilInkStore?, markMode: Bool) {
        self.pdfView = pdfView
        self.docSha = docSha
        self.inkStore = inkStore
        self.markMode = markMode
        super.init()
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard !docSha.isEmpty else { return nil }
        let index = view.document?.index(for: page) ?? 0
        let overlay: InkOverlayView
        if let existing = overlays[index] {
            overlay = existing
        } else {
            overlay = InkOverlayView(pageIndex: index, docSha: docSha, inkStore: inkStore, markMode: markMode)
            overlay.toolPicker = toolPicker
            let size = page.bounds(for: view.displayBox).size
            overlay.frame = CGRect(origin: .zero, size: size)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlays[index] = overlay
            DiagLog.log("pencil: overlay created page=\(index)")
        }
        return overlay
    }

    func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        (overlayView as? InkOverlayView)?.flushSave()
    }

    func setMarkMode(_ on: Bool) {
        markMode = on
        for (_, overlay) in overlays {
            overlay.setMarking(on)
        }
    }

    func flushAll() {
        for (_, overlay) in overlays {
            overlay.flushSave()
        }
    }
}

/// 单页画布容器:透明,内含铺满的 PKCanvasView;触摸过滤规则见文件头注释。
final class InkOverlayView: UIView, PKCanvasViewDelegate {
    private let pageIndex: Int
    private let docSha: String
    private weak var inkStore: PencilInkStore?
    let canvas = PKCanvasView()
    weak var toolPicker: PKToolPicker?

    private var marking = false
    private var pickerObserved = false
    private var loaded = false
    private var saveWork: DispatchWorkItem?
    private var lastLoggedSize = CGSize.zero

    init(pageIndex: Int, docSha: String, inkStore: PencilInkStore?, markMode: Bool) {
        self.pageIndex = pageIndex
        self.docSha = docSha
        self.inkStore = inkStore
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false

        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = self
        canvas.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        loadInk()
        marking = markMode
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 触摸过滤(模式 + 只接 Pencil)

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 选词模式:整体穿透(手指与 Pencil 都交给 PDFView 的选区管线)
        guard marking else { return nil }
        // 标记模式:只接 Pencil(手指仍穿透,滚动/缩放/长按选词不受影响)
        guard let touch = event?.allTouches?.first, touch.type == .pencil else { return nil }
        return super.hitTest(point, with: event)
    }

    // MARK: - 模式切换

    func setMarking(_ on: Bool) {
        guard marking != on else { return }
        marking = on
        if on {
            activateMarking()
        } else {
            toolPicker?.setVisible(false, forFirstResponder: canvas)
            if canvas.isFirstResponder { canvas.resignFirstResponder() }
            flushSave()
        }
        DiagLog.log("pencil: page \(pageIndex) marking=\(on)")
    }

    private func activateMarking() {
        guard window != nil else { return }
        if let picker = toolPicker, !pickerObserved {
            picker.addObserver(canvas)
            pickerObserved = true
        }
        toolPicker?.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, marking {
            activateMarking()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 诊断:叠加层尺寸(真机核对"是否随缩放变换"的关键一行)
        if bounds.size != lastLoggedSize, bounds.width > 1 {
            lastLoggedSize = bounds.size
            DiagLog.log("pencil: page \(pageIndex) overlay \(Int(bounds.width))x\(Int(bounds.height))")
        }
    }

    // MARK: - 存取(防抖 0.8s;停笔/翻页/收尾落盘)

    private func loadInk() {
        defer { loaded = true }
        guard let data = inkStore?.drawing(docSha: docSha, page: pageIndex), !data.isEmpty else { return }
        if let drawing = try? PKDrawing(data: data) {
            canvas.drawing = drawing
            DiagLog.log("pencil: page \(pageIndex) ink loaded \(canvas.drawing.strokes.count) strokes")
        }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        saveNow()
    }

    private func saveNow() {
        guard loaded, let inkStore, !docSha.isEmpty else { return }
        let data = canvas.drawing.dataRepresentation()
        inkStore.save(docSha: docSha, page: pageIndex, data: data)
        DiagLog.log("pencil: page \(pageIndex) ink saved \(canvas.drawing.strokes.count) strokes")
    }
}
