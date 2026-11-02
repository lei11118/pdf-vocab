import Foundation
import GRDB

struct DictionarySource: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let count: Int
}

/// Subject packs are explicitly ECDICT subsets, not separate publisher dictionaries.
enum ScienceDomains {
    static let names = ["math": "数学", "physics": "物理", "chemistry": "化学",
                        "medicine": "医学", "biology": "生物", "computing": "计算机",
                        "engineering": "工程", "earth": "地球科学"]
}

extension DictionaryStore {
    static func dictionaryDirectory() throws -> URL {
        let root = try userDatabaseURL().deletingLastPathComponent().appendingPathComponent("Dictionaries")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func catalog() -> [DictionarySource] {
        var result = [DictionarySource(id: "builtin", name: "ECDICT 通用英汉", detail: "基础词库 · MIT", count: 0)]
        if Bundle.main.url(forResource:"lexical",withExtension:"sqlite") != nil {
            result.append(DictionarySource(id:"wordnet",name:"Open English WordNet 英英补充",detail:"含数学、科学等多义项 · CC BY 4.0 / WordNet License",count:0))
        }
        var config = Configuration(); config.readonly = true
        if let url = Bundle.main.url(forResource: "science", withExtension: "sqlite"),
           let queue = try? DatabaseQueue(path: url.path, configuration:config) {
            let counts = (try? queue.read { db in try Row.fetchAll(db, sql: "SELECT domain,COUNT(*) AS n FROM dict GROUP BY domain") }) ?? []
            for row in counts {
                let id: String = row["domain"], count: Int = row["n"]
                result.append(DictionarySource(id: "science.\(id)", name: "\(ScienceDomains.names[id] ?? id)术语", detail: "ECDICT 学科标注子库 · MIT", count: count))
            }
        }
        for (id, queue) in importedQueues() {
            let name = (try? queue.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key='bookname'") }) ?? "导入词典"
            let count = (try? queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dict") }) ?? 0
            result.append(DictionarySource(id: id, name: name, detail: "本机 StarDict", count: count))
        }
        return result
    }

    func isEnabled(_ id: String) -> Bool {
        !(UserDefaults.standard.stringArray(forKey: "dictionary.disabled.v1") ?? []).contains(id)
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: "dictionary.disabled.v1") ?? [])
        if enabled { ids.remove(id) } else { ids.insert(id) }
        UserDefaults.standard.set(ids.sorted(), forKey: "dictionary.disabled.v1")
        NotificationCenter.default.post(name: .dictionarySelectionChanged, object: nil)
    }

    func removeImportedDictionary(_ id: String) throws {
        let url: URL
        if id == "legacy" { url = try Self.userDatabaseURL() }
        else {
            guard UUID(uuidString:URL(fileURLWithPath:id).deletingPathExtension().lastPathComponent) != nil,
                  !id.contains("/"), !id.contains("\\"), id.hasSuffix(".sqlite") else { throw CocoaError(.fileReadInvalidFileName) }
            url = try Self.dictionaryDirectory().appendingPathComponent(id)
        }
        try FileManager.default.removeItem(at:url)
        reloadUserDictionary()
        NotificationCenter.default.post(name:.dictionarySelectionChanged,object:nil)
    }

    func importedQueues() -> [(String, DatabaseQueue)] {
        var urls: [(String, URL)] = []
        if let legacy = try? Self.userDatabaseURL(), FileManager.default.fileExists(atPath: legacy.path) {
            urls.append(("legacy", legacy)) // Preserve legacy dictionary without rewriting it.
        }
        if let dir = try? Self.dictionaryDirectory(), let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            urls += files.filter { $0.pathExtension == "sqlite" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { ($0.lastPathComponent, $0) }
        }
        return urls.compactMap { id, url in
            var config = Configuration(); config.readonly = true
            guard let queue = try? DatabaseQueue(path: url.path, configuration: config) else { return nil }
            return (id, queue)
        }
    }
}

extension Notification.Name {
    static let dictionarySelectionChanged = Notification.Name("dictionarySelectionChanged")
}
