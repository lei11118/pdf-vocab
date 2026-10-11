import Foundation
import GRDB

/// 应用数据库(GRDB)。位置:Application Support/readword.sqlite
final class AppDatabase: @unchecked Sendable {
    static let shared: AppDatabase? = try? AppDatabase()

    let dbQueue: DatabaseQueue

    private init() throws {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dbURL = dir.appendingPathComponent("readword.sqlite")
        dbQueue = try DatabaseQueue(path: dbURL.path)
        try Self.migrator.migrate(dbQueue)
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
        return migrator
    }
}
