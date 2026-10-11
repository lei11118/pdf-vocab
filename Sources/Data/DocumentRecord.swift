import Foundation
import GRDB

/// 已导入的 PDF 文档。sha256 为主键,文件按 sha 命名保存在 Documents/PDFs/。
struct DocumentRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "document"

    var sha256: String
    var title: String
    var fileName: String
    var pageCount: Int
    var hasTextLayer: Bool
    var importedAt: Date
    var lastPage: Int

    var id: String { sha256 }
}
