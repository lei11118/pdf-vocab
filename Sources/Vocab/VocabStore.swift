import UIKit
import GRDB

/// 生词本数据层(M3-A,v0.7.0)。
///
/// 三个概念:
/// - **词条**(vocab_word):键 = 归一化词元(小写;查得词典条目时用条目词,如 went→go);
/// - **语境**(vocab_occurrence):同一词在不同文档/页面的出现,重复位置不重复记;
/// - **永久加亮**(vocab_highlight):按 PDF 内容哈希(docSha)关联,rects = 该次选区的行矩形(页坐标 JSON)。
///
/// 全部方法非抛错(内部消化),返回 Optional;写入用 GRDB 事务。
struct VocabStore: Sendable {
    let db: AppDatabase

    enum Status: String {
        case new
        case mastered
    }

    struct WordSummary: Identifiable {
        let id: Int64
        let lemma: String
        let surface: String
        let status: Status
        let occurrenceCount: Int
        let updatedAt: Date
    }

    struct HighlightRow {
        let wordId: Int64
        let term: String        // 词条原形(surface)
        let page: Int
        let rects: [CGRect]
    }

    // MARK: - 归一化与矩形编解码

    /// 归一化词条键:优先词典解析结果(went→go、running→run),否则小写原词。
    static func normalizedKey(_ term: String) -> String {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .found(let entry) = DictionaryService.lookup(trimmed), !entry.word.isEmpty {
            return entry.word.lowercased()
        }
        return trimmed.lowercased()
    }

    static func rectsToJSON(_ rects: [CGRect]) -> String {
        guard !rects.isEmpty else { return "[]" }
        let arr: [[Double]] = rects.map {
            [Double($0.origin.x), Double($0.origin.y), Double($0.size.width), Double($0.size.height)]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    static func rectsFromJSON(_ json: String) -> [CGRect] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[Double]] else { return [] }
        return arr.compactMap { v in
            guard v.count == 4 else { return nil }
            return CGRect(x: CGFloat(v[0]), y: CGFloat(v[1]), width: CGFloat(v[2]), height: CGFloat(v[3]))
        }
    }

    // MARK: - 查询

    func entryId(forLemma lemma: String) -> Int64? {
        (try? db.dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM vocab_word WHERE lemma = ?", arguments: [lemma])
        }) ?? nil
    }

    func status(forLemma lemma: String) -> Status? {
        let raw = (try? db.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM vocab_word WHERE lemma = ?", arguments: [lemma])
        }) ?? nil
        return raw.flatMap { Status(rawValue: $0) }
    }

    func occurrenceCount(forLemma lemma: String) -> Int {
        ((try? db.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM vocab_occurrence WHERE wordId = (SELECT id FROM vocab_word WHERE lemma = ?)",
                arguments: [lemma]
            )
        }) ?? nil) ?? 0
    }

    /// 某文档的全部永久加亮(排除已掌握词)。
    func highlights(docSha: String) -> [HighlightRow] {
        (try? db.dbQueue.read { db -> [HighlightRow] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT h.wordId AS wordId, h.page AS page, h.rects AS rects, w.surface AS term
                    FROM vocab_highlight h
                    JOIN vocab_word w ON w.id = h.wordId
                    WHERE h.docSha = ? AND w.status != 'mastered'
                    ORDER BY h.page
                    """,
                arguments: [docSha]
            )
            return rows.map { row in
                let wordId: Int64 = row["wordId"]
                let page: Int = row["page"]
                let rectsJSON: String = row["rects"]
                let term: String = row["term"]
                return HighlightRow(wordId: wordId, term: term, page: page, rects: Self.rectsFromJSON(rectsJSON))
            }
        }) ?? []
    }

    /// 生词本列表(按最近更新倒序,含语境数)。
    func listWords() -> [WordSummary] {
        (try? db.dbQueue.read { db -> [WordSummary] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT w.id AS id, w.lemma AS lemma, w.surface AS surface, w.status AS status,
                           w.updatedAt AS updatedAt,
                           (SELECT COUNT(*) FROM vocab_occurrence o WHERE o.wordId = w.id) AS cnt
                    FROM vocab_word w
                    ORDER BY w.updatedAt DESC
                    """
            )
            return rows.map { row in
                let id: Int64 = row["id"]
                let lemma: String = row["lemma"]
                let surface: String = row["surface"]
                let statusRaw: String = row["status"]
                let cnt: Int = row["cnt"]
                let updatedAt: Date = row["updatedAt"]
                return WordSummary(
                    id: id,
                    lemma: lemma,
                    surface: surface,
                    status: Status(rawValue: statusRaw) ?? .new,
                    occurrenceCount: cnt,
                    updatedAt: updatedAt
                )
            }
        }) ?? []
    }

    // MARK: - 写入

    /// 建卡/重新收录:词条 upsert(status 回 new)+ 追加语境(去重)+ 永久加亮(去重)。
    @discardableResult
    func collectWord(lemma: String, surface: String, docSha: String, page: Int, context: String, rectsJSON: String) -> Int64? {
        try? db.dbQueue.write { db in
            let now = Date()
            let wordId: Int64
            if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM vocab_word WHERE lemma = ?", arguments: [lemma]) {
                wordId = existing
                try db.execute(
                    sql: "UPDATE vocab_word SET status = 'new', updatedAt = ? WHERE id = ?",
                    arguments: [now, wordId]
                )
            } else {
                try db.execute(
                    sql: "INSERT INTO vocab_word (lemma, surface, status, createdAt, updatedAt) VALUES (?, ?, 'new', ?, ?)",
                    arguments: [lemma, surface, now, now]
                )
                wordId = db.lastInsertedRowID
            }
            try db.execute(
                sql: "INSERT OR IGNORE INTO vocab_occurrence (wordId, docSha, page, context, createdAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [wordId, docSha, page, context, now]
            )
            if rectsJSON != "[]" {
                let same = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM vocab_highlight WHERE wordId = ? AND docSha = ? AND page = ? AND rects = ?",
                    arguments: [wordId, docSha, page, rectsJSON]
                ) ?? 0
                if same == 0 {
                    try db.execute(
                        sql: "INSERT INTO vocab_highlight (wordId, docSha, page, rects, createdAt) VALUES (?, ?, ?, ?, ?)",
                        arguments: [wordId, docSha, page, rectsJSON, now]
                    )
                }
            }
            return wordId
        }
    }

    /// 追加语境(已收录词再次选中时调用;重复位置自动忽略)。
    func addOccurrence(wordId: Int64, docSha: String, page: Int, context: String) {
        try? db.dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO vocab_occurrence (wordId, docSha, page, context, createdAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [wordId, docSha, page, context, Date()]
            )
        }
    }

    func setStatus(wordId: Int64, status: Status) {
        try? db.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE vocab_word SET status = ?, updatedAt = ? WHERE id = ?",
                arguments: [status.rawValue, Date(), wordId]
            )
        }
    }

    func removeHighlights(wordId: Int64) {
        try? db.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM vocab_highlight WHERE wordId = ?", arguments: [wordId])
        }
    }
}
