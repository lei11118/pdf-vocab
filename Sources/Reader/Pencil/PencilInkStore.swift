import Foundation
import GRDB

/// Pencil 手写标记数据层(v0.9.0,M4):按 (docSha, page) 存 PKDrawing 二进制;**不改动原 PDF**。
struct PencilInkStore: Sendable {
    let db: AppDatabase

    func drawing(docSha: String, page: Int) -> Data? {
        (try? db.dbQueue.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT data FROM pencil_ink WHERE docSha = ? AND page = ?",
                arguments: [docSha, page]
            )
        }) ?? nil
    }

    func save(docSha: String, page: Int, data: Data) {
        try? db.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO pencil_ink (docSha, page, data, updatedAt) VALUES (?, ?, ?, ?)
                    ON CONFLICT(docSha, page) DO UPDATE SET data = excluded.data, updatedAt = excluded.updatedAt
                    """,
                arguments: [docSha, page, data, Date()]
            )
        }
    }

    func delete(docSha: String, page: Int) {
        try? db.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pencil_ink WHERE docSha = ? AND page = ?", arguments: [docSha, page])
        }
    }

    /// 某文档是否有手写(供 P2「导出带标记 PDF」等功能使用)。
    func hasInk(docSha: String) -> Bool {
        ((try? db.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pencil_ink WHERE docSha = ?", arguments: [docSha])
        }) ?? nil ?? 0) > 0
    }
}
