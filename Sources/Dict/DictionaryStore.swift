import Foundation
import GRDB

/// 词条(内置 ECDICT 精简库 / 用户导入词典)
struct DictEntry: Equatable {
    var word: String
    var phonetic: String?
    var translation: String?
    var definition: String?
    var pos: String?
    var collins: Int
    var oxford: Bool
    var tags: [String]
    var bnc: Int
    var frq: Int
}

/// 词典访问(v0.13.0):内置精简 ECDICT + **用户导入的 StarDict 词典**(userdict.sqlite,查词时优先命中)。
final class DictionaryStore: @unchecked Sendable {
    static let shared = DictionaryStore()

    private var builtinQueue: DatabaseQueue?
    private var userQueue: DatabaseQueue?

    var isAvailable: Bool { builtinQueue != nil || userQueue != nil }
    var hasUserDictionary: Bool { userQueue != nil }

    private init() {
        if let url = Bundle.main.url(forResource: "ecdict", withExtension: "sqlite") {
            var config = Configuration()
            config.readonly = true
            builtinQueue = try? DatabaseQueue(path: url.path, configuration: config)
            DiagLog.log("dict: 内置词库已加载 \(url.lastPathComponent)")
        } else {
            DiagLog.log("dict: 内置词库缺失(此构建未包含)")
        }
        loadUserDictionary()
    }

    // MARK: - 用户词典(v0.13.0,StarDict 导入)

    static func userDatabaseURL() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return dir.appendingPathComponent("userdict.sqlite")
    }

    private func loadUserDictionary() {
        userQueue = nil
        guard let url = try? Self.userDatabaseURL(),
              FileManager.default.fileExists(atPath: url.path) else { return }
        var config = Configuration()
        config.readonly = true
        userQueue = try? DatabaseQueue(path: url.path, configuration: config)
        DiagLog.log("dict: 用户词典已加载 \(userDictionaryName() ?? "?")")
    }

    /// 导入 / 移除后刷新。
    func reloadUserDictionary() {
        loadUserDictionary()
    }

    func userDictionaryName() -> String? {
        guard let userQueue else { return nil }
        return (try? userQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'bookname'")
        }) ?? nil
    }

    // MARK: - 查询(用户词典优先)

    func entry(for word: String) -> DictEntry? {
        let key = word.lowercased()
        if let userQueue, let entry = queryEntry(in: userQueue, key: key) { return entry }
        return queryEntry(in: builtinQueue, key: key)
    }

    private func queryEntry(in queue: DatabaseQueue?, key: String) -> DictEntry? {
        guard let queue else { return nil }
        do {
            return try queue.read { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM dict WHERE word = ?", arguments: [key]) else {
                    return nil
                }
                return Self.entry(from: row)
            }
        } catch {
            DiagLog.log("dict: 查询失败 \(error.localizedDescription)")
            return nil
        }
    }

    /// 词形 → 词头(用户词典优先;用户词典通常无词形表,自动跳内置)。
    func headword(forForm form: String) -> String? {
        let key = form.lowercased()
        for queue in [userQueue, builtinQueue] {
            guard let queue else { continue }
            let head = (try? queue.read { db in
                try String.fetchOne(db, sql: "SELECT word FROM form WHERE form = ?", arguments: [key])
            }) ?? nil
            if let head { return head }
        }
        return nil
    }

    private static func entry(from row: Row) -> DictEntry {
        let tagString = (row["tag"] as String?) ?? ""
        let tags = tagString.split(separator: " ").map(String.init)
        return DictEntry(
            word: (row["word"] as String?) ?? "",
            phonetic: row["phonetic"] as String?,
            translation: row["translation"] as String?,
            definition: row["definition"] as String?,
            pos: row["pos"] as String?,
            collins: (row["collins"] as Int?) ?? 0,
            oxford: ((row["oxford"] as Int?) ?? 0) != 0,
            tags: tags,
            bnc: (row["bnc"] as Int?) ?? 0,
            frq: (row["frq"] as Int?) ?? 0
        )
    }
}
