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

    /// 扫描版搜索(v0.12.0,M7):LIKE 命中词框 → 按行聚合(该行全部词,供片段与跳转高亮)。
    func searchLines(docSha: String, query: String, limit: Int = 100) -> [(page: Int, words: [OCRWord])] {
        var out: [(page: Int, words: [OCRWord])] = []
        try? db.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT page, line FROM ocr_word
                    WHERE docSha = ? AND text LIKE ?
                    ORDER BY page, line LIMIT ?
                    """,
                arguments: [docSha, "%\(query)%", limit]
            )
            for row in rows {
                let page: Int = row["page"]
                let line: Int = row["line"]
                let words = try Row.fetchAll(
                    db,
                    sql: "SELECT text, x, y, w, h FROM ocr_word WHERE docSha = ? AND page = ? AND line = ? ORDER BY idx",
                    arguments: [docSha, page, line]
                ).map { wordRow in
                    OCRWord(
                        text: wordRow["text"],
                        x: wordRow["x"],
                        y: wordRow["y"],
                        w: wordRow["w"],
                        h: wordRow["h"],
                        line: line
                    )
                }
                out.append((page: page, words: words))
            }
        }
        return out
    }
}
