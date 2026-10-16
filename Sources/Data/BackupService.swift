import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation

/// P2(v0.12.0,M7):数据备份 / 恢复(纯本地,无云端 → 手动备份是最后防线)。
/// 备份 = 整库一致性快照(VACUUM INTO)+ manifest → zip;恢复 = 校验后热替换数据库。
enum BackupService {

    /// 导出:生成备份 zip(经分享面板保存到「文件」App)。
    static func exportBackup(db: AppDatabase) throws -> URL {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("yuewen-backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try db.snapshotTo(url: tmp.appendingPathComponent("readword.sqlite"))
        let manifest: [String: Any] = [
            "app": "跃文",
            "format": 1,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]) {
            try data.write(to: tmp.appendingPathComponent("manifest.json"))
        }
        let zipURL = fm.temporaryDirectory
            .appendingPathComponent("跃文备份-\(Int(Date().timeIntervalSince1970)).zip")
        try? fm.removeItem(at: zipURL)
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "readword.sqlite", relativeTo: tmp)
        try archive.addEntry(with: "manifest.json", relativeTo: tmp)
        DiagLog.log("backup: exported \(zipURL.lastPathComponent)")
        return zipURL
    }

    /// 从备份 zip 解出数据库快照到临时文件;校验 SQLite 魔数。
    static func extractDatabase(from zipURL: URL) throws -> URL {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("yuewen-restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        guard let archive = try? Archive(url: zipURL, accessMode: .read) else {
            throw BackupError.badArchive
        }
        guard let entry = archive["readword.sqlite"] else {
            throw BackupError.missingDatabase
        }
        let dest = tmp.appendingPathComponent("readword.sqlite")
        _ = try archive.extract(entry, to: dest)
        let handle = try FileHandle(forReadingFrom: dest)
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 16)
        guard magic.starts(with: Data("SQLite format 3".utf8)) else {
            throw BackupError.notSQLite
        }
        return dest
    }

    enum BackupError: LocalizedError {
        case badArchive
        case missingDatabase
        case notSQLite

        var errorDescription: String? {
            switch self {
            case .badArchive: return "不是有效的备份文件(.zip)"
            case .missingDatabase: return "备份内缺少数据库文件"
            case .notSQLite: return "备份数据库文件损坏"
            }
        }
    }
}

extension Notification.Name {
    /// 数据恢复完成(文档库据此刷新)
    static let yuewenDataDidRestore = Notification.Name("yuewenDataDidRestore")
}

/// 备份 zip 选择器(v0.12.0;沿用文档库的 UIDocumentPicker asCopy 方案——iPadOS 26 上
/// SwiftUI .fileImporter 存在安全作用域失效回归)。
struct ZipImportPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.zip, .data], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPick(url)
            }
        }
    }
}
