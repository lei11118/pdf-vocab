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
    var sources: [String] = []
}

/// 词典访问(v0.13.0):内置精简 ECDICT + **用户导入的 StarDict 词典**(userdict.sqlite,查词时优先命中)。
final class DictionaryStore: @unchecked Sendable {
    static let shared = DictionaryStore()

    private var builtinQueue: DatabaseQueue?
    private var userQueue: DatabaseQueue?
    private var imports: [(String, DatabaseQueue)] = []
    private var scienceQueue: DatabaseQueue?
    private var wordnetQueue: DatabaseQueue?
    private let lock = NSRecursiveLock()
    private var exactPhraseLookupRevisionStorage = 0

    var isAvailable: Bool { lock.lock(); defer { lock.unlock() }; return builtinQueue != nil || scienceQueue != nil || wordnetQueue != nil || !imports.isEmpty }
    var hasUserDictionary: Bool { userQueue != nil }
    var exactPhraseLookupRevision: Int {
        lock.lock(); defer { lock.unlock() }
        return exactPhraseLookupRevisionStorage
    }

    private init() {
        if let url = Bundle.main.url(forResource: "ecdict", withExtension: "sqlite") {
            var config = Configuration()
            config.readonly = true
            builtinQueue = try? DatabaseQueue(path: url.path, configuration: config)
            DiagLog.log("dict: 内置词库已加载 \(url.lastPathComponent)")
        } else {
            DiagLog.log("dict: 内置词库缺失(此构建未包含)")
        }
        if let url = Bundle.main.url(forResource: "science", withExtension: "sqlite") {
            var config = Configuration(); config.readonly = true
            scienceQueue = try? DatabaseQueue(path: url.path, configuration: config)
        }
        if let url = Bundle.main.url(forResource:"lexical",withExtension:"sqlite") {
            var config = Configuration(); config.readonly = true
            wordnetQueue = try? DatabaseQueue(path:url.path,configuration:config)
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
        imports = importedQueues()
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
        lock.lock(); defer { lock.unlock() }
        loadUserDictionary()
        exactPhraseLookupRevisionStorage &+= 1
    }

    /// Lightweight exact phrase check used by bounded selection expansion.
    /// It reads only existence keys from enabled sources and never aggregates
    /// full dictionary entries or definitions.
    func hasEnabledExactPhrase(_ rawPhrase: String) -> Bool {
        let key = rawPhrase.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        guard !key.isEmpty, key.count <= 40 else { return false }
        lock.lock(); defer { lock.unlock() }

        for (id, queue) in imports where isEnabled(id) {
            if Self.hasExactDictionaryEntry(in: queue, key: key) { return true }
        }
        if let scienceQueue {
            let domains = (try? scienceQueue.read { db in
                try String.fetchAll(db,
                                    sql: "SELECT domain FROM dict WHERE word = ? ORDER BY domain",
                                    arguments: [key])
            }) ?? []
            for domain in domains where isEnabled("science.\(domain)") {
                return true
            }
        }
        if isEnabled("builtin"), Self.hasExactDictionaryEntry(in: builtinQueue, key: key) {
            return true
        }
        if isEnabled("wordnet"), let wordnetQueue {
            let exists = (try? wordnetQueue.read { db in
                try Int.fetchOne(db,
                                 sql: "SELECT 1 FROM membership WHERE lemma = ? LIMIT 1",
                                 arguments: [key]) != nil
            }) ?? false
            if exists { return true }
        }
        return false
    }

    func noteExactPhraseCatalogChanged() {
        lock.lock(); defer { lock.unlock() }
        exactPhraseLookupRevisionStorage &+= 1
    }

    private static func hasExactDictionaryEntry(in queue: DatabaseQueue?, key: String) -> Bool {
        guard let queue else { return false }
        return (try? queue.read { db in
            try Int.fetchOne(db,
                             sql: "SELECT 1 FROM dict WHERE word = ? LIMIT 1",
                             arguments: [key]) != nil
        }) ?? false
    }

    func userDictionaryName() -> String? {
        guard let userQueue else { return nil }
        return (try? userQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'bookname'")
        }) ?? nil
    }

    // MARK: - 查询(用户词典优先)

    func entry(for word: String) -> DictEntry? {
        lock.lock(); defer { lock.unlock() }
        let key = word.lowercased()
        var matches: [(String, DictEntry)] = []
        for (id, queue) in imports where isEnabled(id) {
            if let entry = queryEntry(in: queue, key: key) {
                let name = (try? queue.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key='bookname'") }) ?? id
                matches.append((name, entry))
            }
        }
        if let scienceQueue {
            let rows = (try? scienceQueue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM dict WHERE word=? ORDER BY domain", arguments: [key]) }) ?? []
            for row in rows {
                let domain: String = row["domain"]
                if isEnabled("science.\(domain)") {
                    matches.append(("ECDICT · \(ScienceDomains.names[domain] ?? domain)", Self.entry(from: row)))
                }
            }
        }
        if isEnabled("builtin"), let entry = queryEntry(in: builtinQueue, key: key) {
            matches.append(("ECDICT 通用", entry))
        }
        if isEnabled("wordnet"),let wordnetQueue {
            let rows = (try? wordnetQueue.read { db in try Row.fetchAll(db,sql:"SELECT DISTINCT m.pos,s.definition FROM membership m JOIN synset s ON s.id=m.synset WHERE m.lemma=? ORDER BY m.pos,s.definition",arguments:[key]) }) ?? []
            let definitions = rows.map { row -> String in
                let pos: String = row["pos"], definition: String = row["definition"]
                return "\(pos). \(definition)"
            }
            if !definitions.isEmpty {
                matches.append(("Open English WordNet",DictEntry(word:key,phonetic:nil,translation:nil,definition:definitions.joined(separator:"\n"),pos:nil,collins:0,oxford:false,tags:[],bnc:0,frq:0)))
            }
        }
        guard var result = matches.first?.1 else { return nil }
        result.sources = matches.map(\.0)
        func combined(_ field: (DictEntry) -> String?) -> String? {
            let sections = matches.compactMap { name, entry -> String? in
                guard let value = field(entry), !value.isEmpty else { return nil }
                return "【\(name)】\n\(value)"
            }
            return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
        }
        result.translation = combined { $0.translation }
        result.definition = combined { $0.definition }
        return result
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
        lock.lock(); defer { lock.unlock() }
        var queues = imports.filter { isEnabled($0.0) }.map(\.1)
        if isEnabled("builtin"), let builtinQueue { queues.append(builtinQueue) }
        for queue in queues {
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
