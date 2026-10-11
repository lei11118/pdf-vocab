import Foundation
import CryptoKit
import GRDB
import PDFKit

/// 文档导入与查询。导入流程:计算 SHA-256 → 拷贝到沙盒 → 解析 PDF → 入库。
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

    /// 导入一个 PDF 文件(来自文件选择器或"用读词打开")。
    /// 同一文件重复导入时直接返回已有记录(保留阅读进度)。
    @discardableResult
    func importFile(from url: URL) throws -> DocumentRecord {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let sha = try Self.sha256(ofFileAt: url)
        if let existing = try document(sha256: sha) { return existing }

        let destDir = try pdfDirectory
        let dest = destDir.appendingPathComponent("\(sha).pdf")
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: url, to: dest)

        guard let pdf = PDFDocument(url: dest) else {
            try? fm.removeItem(at: dest)
            throw ImportError.unreadablePDF
        }

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

    private static func displayTitle(from url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "未命名" : name
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
    case unreadablePDF

    var errorDescription: String? {
        switch self {
        case .unreadablePDF:
            return "无法读取该 PDF 文件(可能已损坏或受密码保护)"
        }
    }
}
