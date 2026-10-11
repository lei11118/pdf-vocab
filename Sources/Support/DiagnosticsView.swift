import SwiftUI
import UIKit

/// 诊断日志查看页:显示 Documents/diagnostics.log,可复制、分享、刷新、清空。
/// 入口:文档库左上角「诊断」按钮。
struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "(暂无日志——先去复现问题,再回到这里查看)" : text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("诊断日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let url = DiagLog.fileURL {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = text
                        } label: {
                            Label("复制全部", systemImage: "doc.on.doc")
                        }
                        Button {
                            text = DiagLog.readAll()
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) {
                            DiagLog.clear()
                            text = DiagLog.readAll()
                        } label: {
                            Label("清空日志", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear {
            text = DiagLog.readAll()
        }
    }
}
