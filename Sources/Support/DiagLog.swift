import Foundation

/// 轻量诊断日志:追加写入 Documents/diagnostics.log。
/// 用户可在「文件」App → 我的 iPad → 读词 → diagnostics.log 中查看并反馈。
/// 超过 256KB 自动保留后半段。开销极小,正式版保留。
enum DiagLog {
    private static let maxBytes = 256 * 1024
    private static let queue = DispatchQueue(label: "diaglog.write")

    static func log(_ message: String) {
        queue.async {
            guard let url = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("diagnostics.log") else { return }

            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let line = "\(formatter.string(from: Date())) \(message)\n"

            // 超过上限:保留后半段,防止无限增长
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > maxBytes,
               let data = try? Data(contentsOf: url) {
                try? data.suffix(maxBytes / 2).write(to: url)
            }

            if let handle = try? FileHandle(forWritingTo: url) {
                _ = handle.seekToEndOfFile()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
