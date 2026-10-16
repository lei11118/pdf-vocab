import Foundation
import GRDB

/// 应用数据库(GRDB)。位置:Application Support/readword.sqlite
final class AppDatabase: @unchecked Sendable {
    static let shared: AppDatabase? = try? AppDatabase()

    private(set) var dbQueue: DatabaseQueue

    private init() throws {
        let dbURL = try Self.databaseURL()
        dbQueue = try DatabaseQueue(path: dbURL.path)
        try Self.migrator.migrate(dbQueue)
    }

    /// 数据库文件位置(v0.12.0:备份/恢复用)。
    static func databaseURL() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return dir.appendingPathComponent("readword.sqlite")
    }

    /// 生成一致性整库快照(VACUUM INTO;不能跑在事务里 → writeWithoutTransaction)。
    func snapshotTo(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
    }

    /// 用快照热替换当前数据库(v0.12.0,P2 数据恢复):关旧队列 → 换文件 → 新队列 → 迁移。
    /// 各 Store 持有 AppDatabase 引用,替换后自动使用新队列。
    func replaceDatabase(withFileAt source: URL) throws {
        let fm = FileManager.default
        let dbURL = try Self.databaseURL()
        try dbQueue.close()
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: dbURL.path + suffix))
        }
        try fm.copyItem(at: source, to: dbURL)
        let queue = try DatabaseQueue(path: dbURL.path)
        try Self.migrator.migrate(queue)
        dbQueue = queue
        DiagLog.log("backup: database replaced")
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1.documents") { db in
            try db.create(table: "document") { t in
                t.primaryKey("sha256", .text)
                t.column("title", .text).notNull()
                t.column("fileName", .text).notNull()
                t.column("pageCount", .integer).notNull()
                t.column("hasTextLayer", .boolean).notNull()
                t.column("importedAt", .datetime).notNull()
                t.column("lastPage", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("v2.readingProgress") { db in
            try db.alter(table: "document") { t in
                t.add(column: "pageX", .double).notNull().defaults(to: 0)
                t.add(column: "pageY", .double).notNull().defaults(to: 0)
                t.add(column: "zoom", .double).notNull().defaults(to: 1)
                t.add(column: "zoomAuto", .boolean).notNull().defaults(to: true)
            }
        }
        migrator.registerMigration("v3.vocab") { db in
            // 生词本词条(键 = 归一化词元,went→go;surface = 最近选中的原形)
            try db.create(table: "vocab_word") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("lemma", .text).notNull().unique()
                t.column("surface", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "new")   // new / mastered
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            // 语境(同一词在不同位置/文档出现;重复位置不重复记)
            try db.create(table: "vocab_occurrence") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("wordId", .integer).notNull().references("vocab_word", onDelete: .cascade)
                t.column("docSha", .text).notNull()
                t.column("page", .integer).notNull()
                t.column("context", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["wordId", "docSha", "page", "context"])
            }
            // 永久加亮(按 PDF 哈希关联;rects = 页坐标矩形 JSON 数组)
            try db.create(table: "vocab_highlight") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("wordId", .integer).notNull().references("vocab_word", onDelete: .cascade)
                t.column("docSha", .text).notNull()
                t.column("page", .integer).notNull()
                t.column("rects", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_vocab_highlight_doc", on: "vocab_highlight", columns: ["docSha", "page"])
            try db.create(index: "idx_vocab_occurrence_word", on: "vocab_occurrence", columns: ["wordId"])
        }
        migrator.registerMigration("v4.highlightColorAndGroups") { db in
            // 高亮颜色(v0.8.0;默认蓝)
            try db.alter(table: "vocab_highlight") { t in
                t.add(column: "color", .text).notNull().defaults(to: "blue")
            }
            // 分组(v0.8.0,M3-B)
            try db.create(table: "vocab_group") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "vocab_word_group") { t in
                t.column("wordId", .integer).notNull().references("vocab_word", onDelete: .cascade)
                t.column("groupId", .integer).notNull().references("vocab_group", onDelete: .cascade)
                t.column("addedAt", .datetime).notNull()
                t.primaryKey(["wordId", "groupId"])
            }
        }
        migrator.registerMigration("v5.pencilInk") { db in
            // Pencil 手写标记(v0.9.0,M4):按 (docSha, page) 存 PKDrawing 数据;不改动原 PDF
            try db.create(table: "pencil_ink") { t in
                t.column("docSha", .text).notNull()
                t.column("page", .integer).notNull()
                t.column("data", .blob).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["docSha", "page"])
            }
        }
        migrator.registerMigration("v6.vocabNote") { db in
            // 生词备注(v0.10.0,Task 2.2)
            try db.alter(table: "vocab_word") { t in
                t.add(column: "note", .text).notNull().defaults(to: "")
            }
        }
        migrator.registerMigration("v7.ocr") { db in
            // 扫描版 OCR 词框与整本识别状态(v0.11.0,M6)
            try db.create(table: "ocr_word") { t in
                t.column("docSha", .text).notNull()
                t.column("page", .integer).notNull()
                t.column("idx", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("w", .double).notNull()
                t.column("h", .double).notNull()
                t.column("line", .integer).notNull()
                t.primaryKey(["docSha", "page", "idx"])
            }
            try db.create(table: "ocr_status") { t in
                t.column("docSha", .text).primaryKey()
                t.column("done", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v8.bookmark") { db in
            // 书签(v0.12.0,M7):每文档每页一条
            try db.create(table: "bookmark") { t in
                t.column("docSha", .text).notNull()
                t.column("page", .integer).notNull()
                t.column("label", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["docSha", "page"])
            }
        }
        migrator.registerMigration("v9.vocabSense") { db in
            // 义项勾选(v0.13.0):只存「被排除」的义项
            try db.create(table: "vocab_sense") { t in
                t.column("wordId", .integer).notNull().references("vocab_word", onDelete: .cascade)
                t.column("idx", .integer).notNull()
                t.column("selected", .integer).notNull().defaults(to: 1)
                t.primaryKey(["wordId", "idx"])
            }
        }
        return migrator
    }
}
