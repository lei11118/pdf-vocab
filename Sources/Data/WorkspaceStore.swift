import Foundation
import GRDB

struct WorkspaceFolder: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "workspace_folder"
    var id: String
    var name: String
    var icon: String
    var createdAt: Date
    static let icons = ["folder", "books.vertical", "graduationcap", "doc.text", "atom", "globe.asia.australia", "leaf", "sparkles", "pencil.and.outline", "bookmark", "heart", "star"]
}

struct WorkspaceStore {
    let db: AppDatabase
    func folders() throws -> [WorkspaceFolder] {
        try db.dbQueue.read { try WorkspaceFolder.order(Column("createdAt")).fetchAll($0) }
    }
    func membership() throws -> [String: String] {
        try db.dbQueue.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT docSha, folderId FROM workspace_document").map {
                ($0["docSha"] as String, $0["folderId"] as String)
            })
        }
    }
    @discardableResult
    func save(id: String? = nil, name: String, icon: String) throws -> WorkspaceFolder {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, WorkspaceFolder.icons.contains(icon) else { throw WorkspaceError.invalidFolder }
        return try db.dbQueue.write { db in
            let existing = try id.flatMap { try WorkspaceFolder.fetchOne(db, key: $0) }
            let folder = WorkspaceFolder(id: existing?.id ?? UUID().uuidString, name: clean,
                                         icon: icon, createdAt: existing?.createdAt ?? Date())
            try folder.save(db)
            return folder
        }
    }
    func move(docSha: String, to folderId: String?) throws {
        try db.dbQueue.write { db in
            if let folderId {
                try db.execute(sql: "INSERT INTO workspace_document(docSha, folderId) VALUES (?, ?) ON CONFLICT(docSha) DO UPDATE SET folderId=excluded.folderId", arguments: [docSha, folderId])
            } else {
                try db.execute(sql: "DELETE FROM workspace_document WHERE docSha=?", arguments: [docSha])
            }
        }
    }
    /// Membership cascades away; documents, progress and annotations are retained.
    func delete(folder: WorkspaceFolder) throws {
        try db.dbQueue.write { _ = try WorkspaceFolder.deleteOne($0, key: folder.id) }
    }
}
enum WorkspaceError: LocalizedError {
    case invalidFolder
    var errorDescription: String? { "请输入文件夹名称并选择图标。" }
}
