import Foundation
import GRDB

/// 词条(ECDICT 精简库)
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

/// 内置精简词库(ECDICT;CI 生成、只读打开)。
final class DictionaryStore: @unchecked Sendable {
    static let shared = DictionaryStore()

    private let dbQueue: DatabaseQueue?

    var isAvailable: Bool { dbQueue != nil }

    private init() {
        guard let url = Bundle.main.url(forResource: "ecdict", withExtension: "sqlite") else {
            dbQueue = nil
            DiagLog.log("dict: 内置词库缺失(此构建未包含)")
            return
        }
        var config = Configuration()
        config.readonly = true
        dbQueue = try? DatabaseQueue(path: url.path, configuration: config)
        DiagLog.log("dict: 词库已加载 \(url.lastPathComponent)")
    }

    /// 按词头直查。
    func entry(for word: String) -> DictEntry? {
        guard let dbQueue else { return nil }
        let key = word.lowercased()
        do {
            return try dbQueue.read { db in
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

    /// 词形 → 词头(went → go、running → run 等,来自 exchange 展开)。
    func headword(forForm form: String) -> String? {
        guard let dbQueue else { return nil }
        let key = form.lowercased()
        do {
            return try dbQueue.read { db in
                try String.fetchOne(db, sql: "SELECT word FROM form WHERE form = ?", arguments: [key])
            }
        } catch {
            return nil
        }
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
