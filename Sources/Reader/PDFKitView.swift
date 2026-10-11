import SwiftUI
import PDFKit

struct SelectionInfo: Equatable {
    var text: String
    var wordCount: Int
}

/// PDFView 的 SwiftUI 包装:渲染 + 取词交互(详见 ReaderCoordinator)。
struct PDFKitView: UIViewRepresentable {
    let url: URL
    let initialPage: Int
    var onPageChanged: (Int) -> Void
    var onSelectionInfo: (SelectionInfo?) -> Void

    func makeCoordinator() -> ReaderCoordinator {
        ReaderCoordinator(onPageChanged: onPageChanged, onSelectionInfo: onSelectionInfo)
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
        context.coordinator.installGestures(on: view)
        context.coordinator.installObservers()

        if let document = PDFDocument(url: url) {
            view.document = document
            if initialPage > 0, let page = document.page(at: min(initialPage, document.pageCount - 1)) {
                view.go(to: page)
            }
            context.coordinator.documentDidLoad(document)
        }
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onSelectionInfo = onSelectionInfo
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: ReaderCoordinator) {
        coordinator.removeObservers()
        coordinator.clearTempHighlight()
    }
}
