import SwiftUI
import UniformTypeIdentifiers

/// 系统文档选择器的 UIKit 包装(替代 SwiftUI `.fileImporter`)。
/// 背景:iPadOS 26 上 SwiftUI fileImporter 返回的 URL 存在安全作用域失效问题
/// (社区已复现:iOS 17 正常、iOS 26 报 "you don't have permission")。
/// 这里用 `asCopy: true`,让系统把文件预先拷贝进 App 沙盒(tmp)再交付,
/// 彻底绕开安全作用域机制,且对 iCloud/网盘等文件提供商统一生效。
struct PDFDocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .pdf 之外放行 .data:部分来源(网盘导出/工具生成)的文件 UTI 不规范,
        // 只写 [.pdf] 时这些文件会在选择器里被置灰不可选。导入时再做内容校验。
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf, .data], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
