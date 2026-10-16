import Foundation
import GRDB

/// 书签数据层(v0.12.0,M7):每文档每页一条。
struct BookmarkRow: Identifiable {
    let page: Int
    let label: String
    var id: Int { page }
}

final class BookmarkStore: @unchecked Sendable {
    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    func list(docSha: String) -> [BookmarkRow] {
        (try? db.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT page, label FROM bookmark WHERE docSha = ? ORDER BY page",
                arguments: [docSha]
            ).map { row in
                BookmarkRow(page: row["page"], label: row["label"])
            }
        }) ?? []
    }

    func add(docSha: String, page: Int, label: String = "") {
        try? db.dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO bookmark (docSha, page, label, createdAt) VALUES (?, ?, ?, ?)",
                arguments: [docSha, page, label, Date()]
            )
        }
    }

    func remove(docSha: String, page: Int) {
        try? db.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM bookmark WHERE docSha = ? AND page = ?", arguments: [docSha, page])
        }
    }
}
