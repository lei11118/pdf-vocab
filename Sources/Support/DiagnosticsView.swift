import SwiftUI
import UIKit

/// 诊断日志查看页:显示 Documents/diagnostics.log,可复制、分享、刷新、清空、测试写入。
/// 入口:文档库左上角「诊断」按钮。
struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                statusHeader
                Divider()
                ScrollView {
                    Text(text.isEmpty ? "(暂无日志——点上方「写入测试日志」验证写入链路;或先去复现问题再回来刷新)" : text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
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

    // MARK: - 状态头

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let url = DiagLog.fileURL {
                Text(url.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Button {
                DiagLog.log("手动测试写入 \(Int(Date().timeIntervalSince1970))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    text = DiagLog.readAll()
                }
            } label: {
                Label("写入测试日志", systemImage: "square.and.pencil")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var statusLine: String {
        var parts: [String] = []
        let lineCount = text.isEmpty ? 0 : text.split(separator: "\n").count
        parts.append("行数 \(lineCount)")
        if let url = DiagLog.fileURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            if let size = attrs[.size] as? Int { parts.append("\(size) 字节") }
            if let date = attrs[.modificationDate] as? Date {
                let f = DateFormatter()
                f.dateFormat = "HH:mm:ss"
                parts.append("更新于 \(f.string(from: date))")
            }
        } else {
            parts.append("文件尚未创建")
        }
        return parts.joined(separator: " · ")
    }
}
