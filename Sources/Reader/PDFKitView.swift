import SwiftUI
import PDFKit

struct SelectionInfo: Equatable {
    var text: String
    var wordCount: Int
    /// 首个可查询词(侧边词卡用)
    var primaryTerm: String
}

/// 阅读会话句柄:让 SwiftUI 侧在任意时刻取到协调器(保存阅读位置等)。
final class ReaderHandle {
    weak var coordinator: ReaderCoordinator?
}

/// PDFView 的 SwiftUI 包装:渲染 + 取词交互(详见 ReaderCoordinator)+ 阅读位置恢复。
struct PDFKitView: UIViewRepresentable {
    let url: URL
    var restore: ReadingState?
    let handle: ReaderHandle
    var docSha: String = ""
    var vocabStore: VocabStore? = nil
    var inkStore: PencilInkStore? = nil
    /// v0.11.0(M6):OCR 数据层(扫描版取词)
    var ocrStore: OCRStore? = nil
    /// v0.11.0(M4-B):悬停预览 / 触觉(设置页开关)
    var hoverPreviewEnabled: Bool = false
    var hapticsEnabled: Bool = false
    var onHoverUpdate: ((String, String, CGPoint) -> Void)? = nil
    var onHoverEnd: (() -> Void)? = nil
    var markMode: Bool = false
    /// v0.14.0:手写工具会话(浮动工具带驱动各页画布)
    var toolSession: PencilToolSession? = nil
    /// v0.15.0:挤压 → 弧形工具盘(回调笔尖坐标)
    var onPencilSqueeze: ((CGPoint) -> Void)? = nil
    /// v0.16.0:四指轻点进入/退出专注模式(Notability 式低干扰手势)
    var onFocusToggle: (() -> Void)? = nil
    var jumpTarget: VocabJumpTarget? = nil
    var onVocabJumpPerformed: () -> Void = {}
    var onVocabWordTap: (String) -> Void = { _ in }
    var onPageChanged: (Int) -> Void
    var onSelectionInfo: (SelectionInfo?) -> Void
    var onReadingTick: () -> Void = {}
    var onTeardown: () -> Void = {}
    var onTranslate: (String) -> Void = { _ in }

    func makeCoordinator() -> ReaderCoordinator {
        let coordinator = ReaderCoordinator(onPageChanged: onPageChanged, onSelectionInfo: onSelectionInfo)
        coordinator.onTranslate = onTranslate
        coordinator.onReadingTick = onReadingTick
        coordinator.onTeardown = onTeardown
        coordinator.pendingRestore = restore
        coordinator.docSha = docSha
        coordinator.vocabStore = vocabStore
        coordinator.inkStore = inkStore
        coordinator.ocrStore = ocrStore
        coordinator.hoverPreviewEnabled = hoverPreviewEnabled
        coordinator.hapticsEnabled = hapticsEnabled
        coordinator.onHoverUpdate = onHoverUpdate
        coordinator.onHoverEnd = onHoverEnd
        coordinator.markMode = markMode
        coordinator.toolSession = toolSession
        coordinator.onPencilSqueeze = onPencilSqueeze
        coordinator.onFocusToggle = onFocusToggle
        coordinator.pendingVocabJump = jumpTarget
        coordinator.onVocabJumpPerformed = onVocabJumpPerformed
        coordinator.onVocabWordTap = onVocabWordTap
        return coordinator
    }

    func makeUIView(context: Context) -> PDFView {
        let view = VocabPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = true   // v0.14.0:纸页轻阴影(纸感叠层)
        // v0.19.0:大幅放大到 1500%(读小字/扫描书);PDFKit 默认上限只有 4 倍
        view.minScaleFactor = 0.2
        // v0.23.0:最大 4000%(看清扫描件的像素点);实际清晰度取决于 PDF 自身栅格
        view.maxScaleFactor = 40
        // v0.19.0:页面之间不留缝,视觉上连成一张长纸(配合书写贴边滚动)
        view.pageBreakMargins = .zero
        view.backgroundColor = DS.uiBackground1

        context.coordinator.pdfView = view
        context.coordinator.docLabel = url.deletingPathExtension().lastPathComponent
        handle.coordinator = context.coordinator
        context.coordinator.installGestures(on: view)
        context.coordinator.installObservers()

        if let document = PDFDocument(url: url) {
            view.document = document
            context.coordinator.documentDidLoad(document)
        }
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        // v0.23.2:PDFKit 会在文档/布局变化后重置缩放上下限 —— 每次更新都重新放开
        if abs(uiView.maxScaleFactor - 40) > 0.001 { uiView.maxScaleFactor = 40 }
        if abs(uiView.minScaleFactor - 0.2) > 0.001 { uiView.minScaleFactor = 0.2 }
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onSelectionInfo = onSelectionInfo
        context.coordinator.onTranslate = onTranslate
        context.coordinator.onReadingTick = onReadingTick
        context.coordinator.onTeardown = onTeardown
        context.coordinator.vocabStore = vocabStore
        context.coordinator.ocrStore = ocrStore
        context.coordinator.hoverPreviewEnabled = hoverPreviewEnabled
        context.coordinator.hapticsEnabled = hapticsEnabled
        context.coordinator.onHoverUpdate = onHoverUpdate
        context.coordinator.onHoverEnd = onHoverEnd
        context.coordinator.onVocabJumpPerformed = onVocabJumpPerformed
        context.coordinator.setMarkMode(markMode)
        context.coordinator.toolSession = toolSession
        context.coordinator.onPencilSqueeze = onPencilSqueeze
        context.coordinator.onFocusToggle = onFocusToggle
        // v0.16.1:不在每次 updateUIView 里套用工具 —— SwiftUI 每帧更新都重建
        // PKCanvasView.tool 会让 PencilKit 反复重建状态(选工具卡死的根因)。
        // 工具变化由 ReaderView 的 onChange → applyToolSession(带签名去重)驱动。
        context.coordinator.onVocabWordTap = onVocabWordTap
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: ReaderCoordinator) {
        coordinator.prepareForTeardown()
    }
}
