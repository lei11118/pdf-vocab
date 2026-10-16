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

    struct WordSummary: Identifiable {
        let id: Int64
        let lemma: String
        let surface: String
        let occurrenceCount: Int
        let updatedAt: Date
        // 出处(v0.8.0:最近一次语境所在文档/页;若该处有高亮,带出矩形供"一键抵达"临时高亮)
        let sourceDocSha: String?
        let sourceDocTitle: String?
        let sourcePage: Int?
        let sourceRectsJSON: String?
    }

    struct HighlightRow {
        let wordId: Int64
        let term: String        // 词条原形(surface)
        let page: Int
        let rects: [CGRect]
        let color: String       // v0.8.0:高亮颜色名
    }

    struct GroupSummary: Identifiable {
        let id: Int64
        let name: String
        let count: Int
    }

    struct OccurrenceRow: Identifiable {
        let id: Int64
        let docSha: String
        let docTitle: String
        let page: Int
        let context: String
        let rectsJSON: String?   // 该处若有高亮,带出矩形供跳转临时高亮
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

    // (v0.10.0:「已掌握」Status 查询已随概念一起移除)

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
                    SELECT h.wordId AS wordId, h.page AS page, h.rects AS rects, h.color AS color, w.surface AS term
                    FROM vocab_highlight h
                    JOIN vocab_word w ON w.id = h.wordId
                    WHERE h.docSha = ?
                    ORDER BY h.page
                    """,
                arguments: [docSha]
            )
            return rows.map { row in
                let wordId: Int64 = row["wordId"]
                let page: Int = row["page"]
                let rectsJSON: String = row["rects"]
                let color: String = row["color"]
                let term: String = row["term"]
                return HighlightRow(wordId: wordId, term: term, page: page, rects: Self.rectsFromJSON(rectsJSON), color: color)
            }
        }) ?? []
    }

    /// 生词本列表(v0.8.0:按文档 / 分组 / 搜索筛选;v0.10.0:支持「未分组」筛选;带出处)。
    func listWords(docSha: String? = nil, groupId: Int64? = nil, ungrouped: Bool = false, search: String? = nil) -> [WordSummary] {
        var sql = """
            SELECT w.id AS id, w.lemma AS lemma, w.surface AS surface,
                   w.updatedAt AS updatedAt,
                   (SELECT COUNT(*) FROM vocab_occurrence o0 WHERE o0.wordId = w.id
                    \(docSha != nil ? "AND o0.docSha = ?" : "")) AS cnt,
                   o.docSha AS srcDoc, o.page AS srcPage, d.title AS srcTitle,
                   (SELECT h.rects FROM vocab_highlight h
                    WHERE h.wordId = w.id AND h.docSha = o.docSha AND h.page = o.page
                    ORDER BY h.createdAt DESC LIMIT 1) AS srcRects
            FROM vocab_word w
            LEFT JOIN vocab_occurrence o ON o.id = (
                SELECT id FROM vocab_occurrence WHERE wordId = w.id
                \(docSha != nil ? "AND docSha = ?" : "")
                ORDER BY createdAt DESC LIMIT 1)
            LEFT JOIN document d ON d.sha256 = o.docSha
            WHERE 1 = 1
            """
        if docSha != nil {
            sql += "\n    AND EXISTS (SELECT 1 FROM vocab_occurrence ox WHERE ox.wordId = w.id AND ox.docSha = ?)"
        }
        if groupId != nil {
            sql += "\n    AND EXISTS (SELECT 1 FROM vocab_word_group wx WHERE wx.wordId = w.id AND wx.groupId = ?)"
        }
        if ungrouped {
            sql += "\n    AND NOT EXISTS (SELECT 1 FROM vocab_word_group wx WHERE wx.wordId = w.id)"
        }
        if search != nil {
            sql += "\n    AND (w.surface LIKE ? OR w.lemma LIKE ?)"
        }
        sql += "\n    ORDER BY w.updatedAt DESC"

        var args: [DatabaseValueConvertible?] = []
        if let docSha {
            args.append(docSha)   // cnt 子查询
            args.append(docSha)   // 最新语境子查询
            args.append(docSha)   // WHERE EXISTS
        }
        if let groupId { args.append(groupId) }
        if let search {
            let like = "%\(search)%"
            args.append(like)
            args.append(like)
        }

        return (try? db.dbQueue.read { db -> [WordSummary] in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                let id: Int64 = row["id"]
                let lemma: String = row["lemma"]
                let surface: String = row["surface"]
                let cnt: Int = row["cnt"]
                let updatedAt: Date = row["updatedAt"]
                let srcDoc: String? = row["srcDoc"]
                let srcPage: Int? = row["srcPage"]
                let srcTitle: String? = row["srcTitle"]
                let srcRects: String? = row["srcRects"]
                return WordSummary(
                    id: id,
                    lemma: lemma,
                    surface: surface,
                    occurrenceCount: cnt,
                    updatedAt: updatedAt,
                    sourceDocSha: srcDoc,
                    sourceDocTitle: srcTitle,
                    sourcePage: srcPage,
                    sourceRectsJSON: srcRects
                )
            }
        }) ?? []
    }

    /// 某词的全部语境(v0.8.2;新→旧;带出处文档标题与可选高亮矩形)。
    func occurrences(forLemma lemma: String) -> [OccurrenceRow] {
        (try? db.dbQueue.read { db -> [OccurrenceRow] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT o.id AS id, o.docSha AS docSha, o.page AS page, o.context AS context,
                           COALESCE(d.title, '未知文档') AS docTitle,
                           (SELECT h.rects FROM vocab_highlight h
                            WHERE h.wordId = o.wordId AND h.docSha = o.docSha AND h.page = o.page
                            ORDER BY h.createdAt DESC LIMIT 1) AS rects
                    FROM vocab_occurrence o
                    JOIN vocab_word w ON w.id = o.wordId
                    LEFT JOIN document d ON d.sha256 = o.docSha
                    WHERE w.lemma = ?
                    ORDER BY o.createdAt DESC
                    """,
                arguments: [lemma]
            )
            return rows.map { row in
                OccurrenceRow(
                    id: row["id"],
                    docSha: row["docSha"],
                    docTitle: row["docTitle"],
                    page: row["page"],
                    context: row["context"],
                    rectsJSON: row["rects"]
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
                    sql: "UPDATE vocab_word SET updatedAt = ? WHERE id = ?",
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

    func removeHighlights(wordId: Int64) {
        try? db.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM vocab_highlight WHERE wordId = ?", arguments: [wordId])
        }
    }

    // MARK: - 备注(v0.10.0,Task 2.2)

    func note(forLemma lemma: String) -> String {
        let value = (try? db.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT note FROM vocab_word WHERE lemma = ?", arguments: [lemma])
        }) ?? nil
        return value ?? ""
    }

    func setNote(forLemma lemma: String, note: String) {
        try? db.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE vocab_word SET note = ?, updatedAt = ? WHERE lemma = ?",
                arguments: [note, Date(), lemma]
            )
        }
    }

    /// 批量收录(v0.12.0,M7 词频分析):只建词卡,不携带语境/位置。
    @discardableResult
    func collectHeadword(lemma: String, surface: String) -> Int64? {
        try? db.dbQueue.write { db in
            if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM vocab_word WHERE lemma = ?", arguments: [lemma]) {
                return existing
            }
            let now = Date()
            try db.execute(
                sql: "INSERT INTO vocab_word (lemma, surface, status, createdAt, updatedAt) VALUES (?, ?, 'new', ?, ?)",
                arguments: [lemma, surface, now, now]
            )
            return db.lastInsertedRowID
        }
    }

    // MARK: - 颜色 / 分组 / 删除(v0.8.0)

    static let highlightColorNames = ["blue", "orange", "green", "pink"]

    static func highlightColor(named name: String) -> UIColor {
        switch name {
        case "orange": return .systemOrange
        case "green": return .systemGreen
        case "pink": return .systemPink
        default: return .systemBlue
        }
    }

    /// 当前高亮颜色(取该词最新一条高亮;无高亮返回 nil)。
    func highlightColorName(forLemma lemma: String) -> String? {
        (try? db.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT h.color FROM vocab_highlight h
                    WHERE h.wordId = (SELECT id FROM vocab_word WHERE lemma = ?)
                    ORDER BY h.createdAt DESC LIMIT 1
                    """,
                arguments: [lemma]
            )
        }) ?? nil
    }

    func setHighlightColor(forLemma lemma: String, colorName: String) {
        try? db.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE vocab_highlight SET color = ? WHERE wordId = (SELECT id FROM vocab_word WHERE lemma = ?)",
                arguments: [colorName, lemma]
            )
        }
    }

    /// 删除某个生词(连同语境/高亮/分组归属一起清掉)。
    func deleteWord(id: Int64) {
        try? db.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM vocab_highlight WHERE wordId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM vocab_occurrence WHERE wordId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM vocab_word_group WHERE wordId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM vocab_word WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - 分组(v0.8.0,M3-B)

    /// 把词移出所有分组(拖到「未分组」文件夹;v0.10.0 Task 2.3)。
    func removeFromAllGroups(wordId: Int64) {
        try? db.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM vocab_word_group WHERE wordId = ?", arguments: [wordId])
        }
    }

    func groups() -> [GroupSummary] {
        (try? db.dbQueue.read { db -> [GroupSummary] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT g.id AS id, g.name AS name,
                           (SELECT COUNT(*) FROM vocab_word_group wg WHERE wg.groupId = g.id) AS cnt
                    FROM vocab_group g
                    ORDER BY g.name COLLATE NOCASE
                    """
            )
            return rows.map { row in
                let id: Int64 = row["id"]
                let name: String = row["name"]
                let cnt: Int = row["cnt"]
                return GroupSummary(id: id, name: name, count: cnt)
            }
        }) ?? []
    }

    /// 新建分组(同名已存在时直接返回其 id)。
    @discardableResult
    func createGroup(name: String) -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? db.dbQueue.write { db in
            if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM vocab_group WHERE name = ?", arguments: [trimmed]) {
                return existing
            }
            try db.execute(sql: "INSERT INTO vocab_group (name, createdAt) VALUES (?, ?)", arguments: [trimmed, Date()])
            return db.lastInsertedRowID
        }
    }

    func renameGroup(id: Int64, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? db.dbQueue.write { db in
            try db.execute(sql: "UPDATE vocab_group SET name = ? WHERE id = ?", arguments: [trimmed, id])
        }
    }

    func deleteGroup(id: Int64) {
        try? db.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM vocab_word_group WHERE groupId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM vocab_group WHERE id = ?", arguments: [id])
        }
    }

    func setMembership(wordId: Int64, groupId: Int64, member: Bool) {
        try? db.dbQueue.write { db in
            if member {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO vocab_word_group (wordId, groupId, addedAt) VALUES (?, ?, ?)",
                    arguments: [wordId, groupId, Date()]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM vocab_word_group WHERE wordId = ? AND groupId = ?",
                    arguments: [wordId, groupId]
                )
            }
        }
    }

    func groupIds(forLemma lemma: String) -> Set<Int64> {
        let ids = (try? db.dbQueue.read { db -> [Int64] in
            try Int64.fetchAll(
                db,
                sql: "SELECT groupId FROM vocab_word_group WHERE wordId = (SELECT id FROM vocab_word WHERE lemma = ?)",
                arguments: [lemma]
            )
        }) ?? []
        return Set(ids)
    }
}

/// 生词出处跳转目标(v0.8.0):生词本"一键抵达"的载荷。
struct VocabJumpTarget: Hashable {
    var docSha: String
    var docTitle: String
    var page: Int
    var term: String
    /// 该处高亮的矩形 JSON(可 nil:只跳页不画临时高亮)
    var rectsJSON: String?
}
