import Foundation
import GRDB

/// OCR 数据层(v0.11.0,M6):`ocr_word`(逐词框)+ `ocr_status`(整本识别状态)。
final class OCRStore: @unchecked Sendable {
    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    /// 某页的词框(按识别顺序)。
    func words(docSha: String, page: Int) -> [OCRWord] {
        (try? db.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT text, x, y, w, h, line FROM ocr_word WHERE docSha = ? AND page = ? ORDER BY idx",
                arguments: [docSha, page]
            ).map { row in
                OCRWord(
                    text: row["text"],
                    x: row["x"],
                    y: row["y"],
                    w: row["w"],
                    h: row["h"],
                    line: row["line"]
                )
            }
        }) ?? []
    }

    /// 覆盖保存一页的词框(重识别安全)。
    func save(docSha: String, page: Int, words: [OCRWord]) {
        try? db.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM ocr_word WHERE docSha = ? AND page = ?", arguments: [docSha, page])
            for (i, word) in words.enumerated() {
                try db.execute(
                    sql: "INSERT INTO ocr_word (docSha, page, idx, text, x, y, w, h, line) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    arguments: [docSha, page, i, word.text, word.x, word.y, word.w, word.h, word.line]
                )
            }
        }
    }

    func markDone(docSha: String) {
        try? db.dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO ocr_status (docSha, done, updatedAt) VALUES (?, 1, ?)",
                arguments: [docSha, Date()]
            )
        }
    }

    func isDone(docSha: String) -> Bool {
        let done = (try? db.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT done FROM ocr_status WHERE docSha = ?", arguments: [docSha])
        }) ?? nil
        return done == 1
    }
}
