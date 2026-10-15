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
        coordinator.onVocabWordTap = onVocabWordTap
        return coordinator
    }

    func makeUIView(context: Context) -> PDFView {
        let view = VocabPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = false
        view.backgroundColor = .systemGroupedBackground

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
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onSelectionInfo = onSelectionInfo
        context.coordinator.onTranslate = onTranslate
        context.coordinator.onReadingTick = onReadingTick
        context.coordinator.onTeardown = onTeardown
        context.coordinator.vocabStore = vocabStore
        context.coordinator.onVocabWordTap = onVocabWordTap
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: ReaderCoordinator) {
        coordinator.prepareForTeardown()
    }
}
