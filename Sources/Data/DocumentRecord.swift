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
    /// 页内位置:视口左上角相对页面宽/高的比例(-0.5…1.5)
    var pageX: Double
    var pageY: Double
    /// 缩放(scaleFactor;zoomAuto 为 true 时忽略)
    var zoom: Double
    /// 是否"适应宽度"(autoScales)模式
    var zoomAuto: Bool

    var id: String { sha256 }

    /// 阅读位置(供恢复用)
    var readingState: ReadingState {
        ReadingState(page: lastPage, pageX: pageX, pageY: pageY, zoom: zoom, zoomAuto: zoomAuto)
    }
}

/// 阅读位置(页码 + 页内比例位置 + 缩放),用于"退出位置记忆"。
struct ReadingState: Codable, Equatable {
    var page: Int
    var pageX: Double
    var pageY: Double
    var zoom: Double
    var zoomAuto: Bool
}
