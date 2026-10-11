import Foundation
import CryptoKit
import GRDB
import PDFKit

/// 文档导入与查询。
/// 导入管线(对所有来源统一):安全作用域(如需要)→ 拷贝到沙盒临时档 → 校验 %PDF →
/// 计算 SHA-256 → 去重 → 移动到 PDFs/<sha>.pdf → 入库。
/// 先落地再处理,兼容 iCloud/网盘等文件提供商(读 FileHandle 前先 copy 触发物化)。
struct DocumentStore: Sendable {
    let db: AppDatabase

    var pdfDirectory: URL {
        get throws {
            let fm = FileManager.default
            let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = docs.appendingPathComponent("PDFs", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
    }

    func pdfURL(for rec: DocumentRecord) throws -> URL {
        try pdfDirectory.appendingPathComponent(rec.fileName)
    }

    func allDocuments() throws -> [DocumentRecord] {
        try db.dbQueue.read { db in
            try DocumentRecord.all().order(Column("importedAt").desc).fetchAll(db)
        }
    }

    func document(sha256: String) throws -> DocumentRecord? {
        try db.dbQueue.read { db in
            try DocumentRecord.fetchOne(db, key: sha256)
        }
    }

    /// 导入一个 PDF 文件(来自文件选择器)。
    /// 同一文件重复导入时返回已有记录(保留阅读进度)。
    @discardableResult
    func importFile(from url: URL) throws -> DocumentRecord {
        let fm = FileManager.default
        let destDir = try pdfDirectory
        let scratch = try scratchDirectory()
        let staged = scratch.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? fm.removeItem(at: staged) } // 成功 move 后此处静默失效

        // 1) 先拷贝进沙盒——选择器已给沙盒副本时相当于同卷复制;iCloud/文件提供商在此触发物化
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try fm.copyItem(at: url, to: staged)
        } catch {
            throw ImportError.cannotRead(error)
        }

        // 2) 校验是不是 PDF(文件头 1KB 内应含 %PDF)
        guard Self.looksLikePDF(staged) else { throw ImportError.notAPDF }

        // 3) 哈希 + 去重
        let sha = try Self.sha256(ofFileAt: staged)
        if let existing = try document(sha256: sha) { return existing }

        // 4) 能否解析(含加密检测)
        guard let pdf = PDFDocument(url: staged) else { throw ImportError.unreadablePDF }
        if pdf.isLocked, !pdf.unlock(withPassword: "") {
            throw ImportError.encryptedPDF
        }

        // 5) 移入正式位置 + 入库
        let dest = destDir.appendingPathComponent("\(sha).pdf")
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: staged, to: dest)

        let rec = DocumentRecord(
            sha256: sha,
            title: Self.displayTitle(from: url),
            fileName: "\(sha).pdf",
            pageCount: pdf.pageCount,
            hasTextLayer: Self.detectTextLayer(pdf),
            importedAt: Date(),
            lastPage: 0
        )
        try db.dbQueue.write { db in
            try rec.insert(db)
        }
        return rec
    }

    func setLastPage(_ page: Int, for sha256: String) throws {
        try db.dbQueue.write { db in
            if var rec = try DocumentRecord.fetchOne(db, key: sha256) {
                rec.lastPage = page
                try rec.update(db)
            }
        }
    }

    func delete(_ rec: DocumentRecord) throws {
        try db.dbQueue.write { db in
            _ = try DocumentRecord.deleteOne(db, key: rec.sha256)
        }
        if let url = try? pdfURL(for: rec) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    private func scratchDirectory() throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("import-scratch", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func displayTitle(from url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "未命名" : name
    }

    /// PDF 文件头校验:%PDF 出现在开头 1KB 内。
    private static func looksLikePDF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head: Data
        do {
            head = try handle.read(upToCount: 1024) ?? Data()
        } catch {
            return false
        }
        return head.range(of: Data("%PDF".utf8)) != nil
    }

    /// 是否含文字层(抽查前 5 页)。扫描版为 false,取词走 OCR(M6)。
    private static func detectTextLayer(_ pdf: PDFDocument) -> Bool {
        let checkLimit = min(pdf.pageCount, 5)
        for i in 0..<checkLimit {
            if let text = pdf.page(at: i)?.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    private static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum ImportError: LocalizedError {
    case cannotRead(Error)
    case notAPDF
    case unreadablePDF
    case encryptedPDF

    var errorDescription: String? {
        switch self {
        case .cannotRead(let error):
            let ns = error as NSError
            return "无法读取文件(\(ns.domain) \(ns.code)):\(error.localizedDescription)"
        case .notAPDF:
            return "所选文件不是有效的 PDF"
        case .unreadablePDF:
            return "PDF 无法解析(文件可能已损坏)"
        case .encryptedPDF:
            return "PDF 受密码保护,暂不支持导入(后续版本加入)"
        }
    }
}
