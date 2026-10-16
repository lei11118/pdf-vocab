import Foundation
import GRDB
import ZIPFoundation
import CryptoKit

/// M5(v0.11.0):Anki .apkg 导出(genanki 同款 **Legacy 格式**:collection.anki2 schema 11 + media JSON + 编号媒体文件)。
/// - **稳定 GUID**(词元):重复导出同一单词,Anki 导入时**更新**该卡而非重复建卡;
/// - 字段:单词 / 音标 / 中文释义 / 英文释义 / 例句 / 出处 / 备注 / 音频([sound:] 内嵌,正面自动播放);
/// - 音频 = 离线 TTS 合成 WAV(见 AnkiAudio),打包进 apkg,Anki 端可直接播放。
struct AnkiNoteData {
    let term: String
    let key: String
    let phonetic: String
    let translation: String
    let definition: String
    let context: String
    let source: String
    let note: String
    let tags: [String]
    let audioFileName: String?
    let audioURL: URL?
}

struct AnkiExportOptions {
    var deckName: String = "跃文"
    var includeAudio: Bool = true
}

enum AnkiExporter {

    static let modelId: Int64 = 1_721_110_001
    static let deckBase: Int64 = 1_721_110_100

    // MARK: - 稳定 ID(FNV-1a;避免 Swift hashValue 的每进程随机种子)

    static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    static func deckId(for name: String) -> Int64 {
        deckBase + Int64(fnv1a64(name) % 90_000_000)
    }

    // MARK: - 主入口(同步;在后台线程调用)

    static func makeApkg(notes: [AnkiNoteData], options: AnkiExportOptions) throws -> URL {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
            .appendingPathComponent("anki-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let deckIdV = deckId(for: options.deckName)
        let crt = Int64(Date().timeIntervalSince1970)
        let nowMs = crt * 1000

        // 1) 媒体(音频)拷入导出目录 + media JSON(空也写,Anki 容忍)
        var mediaMap: [String: String] = [:]
        if options.includeAudio {
            var idx = 0
            for note in notes {
                guard let audioURL = note.audioURL, fm.fileExists(atPath: audioURL.path) else { continue }
                let entryName = "\(idx)"
                let dest = tmpDir.appendingPathComponent(entryName)
                try? fm.removeItem(at: dest)
                if (try? fm.copyItem(at: audioURL, to: dest)) != nil {
                    mediaMap[entryName] = note.audioFileName ?? audioURL.lastPathComponent
                    idx += 1
                }
            }
        }
        let mediaData = (try? JSONSerialization.data(withJSONObject: mediaMap, options: [.sortedKeys])) ?? Data("{}".utf8)
        try mediaData.write(to: tmpDir.appendingPathComponent("media"))

        // 2) collection.anki2(schema 11)
        let dbURL = tmpDir.appendingPathComponent("collection.anki2")
        let queue = try DatabaseQueue(path: dbURL.path)
        let models = modelsJSON(deckId: deckIdV, mod: nowMs)
        let decks = decksJSON(deckId: deckIdV, name: options.deckName, mod: nowMs)
        let conf = confJSON(deckId: deckIdV)
        let dconf = dconfJSON(mod: nowMs)
        var position = 0
        try queue.write { db in
            try db.execute(sql: Schema.ddl)
            try db.execute(
                sql: """
                INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags)
                VALUES (1, ?, ?, ?, 11, 0, 0, 0, ?, ?, ?, ?, '{}')
                """,
                arguments: [crt, nowMs, nowMs, conf, models, decks, dconf]
            )
            for (i, note) in notes.enumerated() {
                position += 1
                let flds = [
                    note.term,
                    note.phonetic,
                    note.translation,
                    note.definition,
                    note.context,
                    note.source,
                    note.note,
                    note.audioFileName.map { "[sound:\($0)]" } ?? "",
                ].joined(separator: "\u{1f}")
                let sfld = note.term
                let csum = checksum(sfld)
                let guid = "pv_\(note.key)"
                let noteId = nowMs + Int64(i) * 2 + 1
                let cardId = noteId + 1
                try db.execute(
                    sql: """
                    INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
                    VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, 0, '')
                    """,
                    arguments: [noteId, guid, modelId, nowMs, tagsField(note.tags), flds, sfld, csum]
                )
                try db.execute(
                    sql: """
                    INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
                    VALUES (?, ?, ?, 0, ?, 0, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')
                    """,
                    arguments: [cardId, noteId, deckIdV, nowMs, position]
                )
            }
        }
        try queue.close()

        // 3) 打包 zip → .apkg
        let apkgURL = tmpDir.appendingPathComponent("跃文.apkg")
        let archive = try Archive(url: apkgURL, accessMode: .create)
        try archive.addEntry(with: "collection.anki2", relativeTo: tmpDir)
        try archive.addEntry(with: "media", relativeTo: tmpDir)
        for entryName in mediaMap.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
            try archive.addEntry(with: entryName, relativeTo: tmpDir)
        }
        DiagLog.log("anki: export \(notes.count) notes / \(mediaMap.count) audio / deck=\(options.deckName)")
        return apkgURL
    }

    // MARK: - 小工具

    /// genanki 同款:sha1(首字段)前 8 个十六进制位 → Int。
    static func checksum(_ s: String) -> Int64 {
        let digest = Insecure.SHA1.hash(data: Data(s.utf8))
        var value: Int64 = 0
        for byte in digest.prefix(4) {
            value = (value << 8) | Int64(byte)
        }
        return value
    }

    static func tagsField(_ tags: [String]) -> String {
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "_") }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "" }
        return " " + cleaned.joined(separator: " ") + " "
    }

    private static func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    private static func field(_ name: String, _ ord: Int) -> [String: Any] {
        ["name": name, "ord": ord, "sticky": false, "rtl": false, "font": "Arial", "size": 20, "media": []]
    }

    // MARK: - 模型 / 牌组 / 配置 JSON

    static func modelsJSON(deckId: Int64, mod: Int64) -> String {
        let qfmt = """
        <div class="word">{{单词}}</div>
        <div class="phonetic">{{音标}}</div>
        <div class="audio">{{音频}}</div>
        """
        let afmt = """
        {{FrontSide}}
        <hr id=answer>
        <div class="trans">{{中文释义}}</div>
        {{#英文释义}}<div class="def">{{英文释义}}</div>{{/英文释义}}
        {{#例句}}<div class="eg">{{例句}}</div>{{/例句}}
        {{#出处}}<div class="src">{{出处}}</div>{{/出处}}
        {{#备注}}<div class="note">{{备注}}</div>{{/备注}}
        """
        let template: [String: Any] = [
            "name": "Card 1",
            "ord": 0,
            "qfmt": qfmt,
            "afmt": afmt,
            "bqfmt": "",
            "bafmt": "",
            "did": NSNull(),
            "bfont": "",
            "bsize": 0,
        ]
        let model: [String: Any] = [
            "id": modelId,
            "name": "跃文词卡",
            "type": 0,
            "mod": mod,
            "usn": 0,
            "sortf": 0,
            "did": deckId,
            "tmpls": [template],
            "flds": [
                field("单词", 0), field("音标", 1), field("中文释义", 2), field("英文释义", 3),
                field("例句", 4), field("出处", 5), field("备注", 6), field("音频", 7),
            ],
            "css": css,
            "latexPre": "\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage[utf8,utf8x]{inputenc}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n",
            "latexPost": "\\end{document}",
            "req": [[0, "any", [0]]],
            "tags": [],
            "vers": [],
        ]
        return jsonString(["\(modelId)": model])
    }

    static let css = """
    .card {
      font-family: -apple-system, "Helvetica Neue", Arial, sans-serif;
      font-size: 18px;
      text-align: left;
      color: #1c1c1e;
      background: #ffffff;
      line-height: 1.5;
      padding: 6px 2px;
    }
    .nightMode .card, .card.night_mode { color: #f2f2f7; background: #1c1c1e; }
    .word { font-size: 26px; font-weight: 600; }
    .phonetic { color: #8e8e93; margin-top: 2px; }
    .audio { margin-top: 4px; }
    .trans { font-size: 19px; margin-top: 6px; }
    .def { color: #636366; margin-top: 4px; font-size: 16px; }
    .eg { margin-top: 8px; font-size: 16px; }
    .src { margin-top: 8px; color: #8e8e93; font-size: 13px; }
    .note { margin-top: 6px; color: #8e8e93; font-size: 14px; font-style: italic; }
    """

    static func decksJSON(deckId: Int64, name: String, mod: Int64) -> String {
        func deck(_ id: Int64, _ deckName: String) -> [String: Any] {
            ["id": id, "name": deckName, "mod": mod, "usn": 0, "collapsed": false, "dyn": 0,
             "desc": "", "browserCollapsed": false, "conf": 1, "extendNew": 10, "extendRev": 50]
        }
        return jsonString(["1": deck(1, "Default"), "\(deckId)": deck(deckId, name)])
    }

    static func confJSON(deckId: Int64) -> String {
        jsonString([
            "nextPos": 1, "estTimes": true, "activeDecks": [1], "sortType": "noteFld",
            "timeLim": 0, "sortBackwards": false, "addToCur": true, "curDeck": deckId,
            "newBury": true, "newSpread": 0, "dueCounts": true, "collapseTime": 1200,
        ])
    }

    static func dconfJSON(mod: Int64) -> String {
        let config: [String: Any] = [
            "name": "Default", "mod": mod, "usn": 0, "maxTaken": 60, "autoplay": true,
            "timer": 0, "replayq": true,
            "new": ["bury": true, "delays": [1, 10], "initialFactor": 2500,
                    "ints": [1, 4, 7], "order": 1, "perDay": 20] as [String: Any],
            "rev": ["bury": true, "ease4": 1.3, "fuzz": 0.05, "ivlFct": 1,
                    "maxIvl": 36500, "minSpace": 1, "perDay": 200] as [String: Any],
            "lapse": ["delays": [10], "leechAction": 0, "leechFails": 8, "minInt": 1, "mult": 0] as [String: Any],
            "dyn": false,
        ]
        return jsonString(["1": config])
    }

    /// Anki schema 11(legacy)DDL,与 genanki 写出格式一致。
    enum Schema {
        static let ddl = """
        CREATE TABLE col (id integer primary key, crt integer not null, mod integer not null, scm integer not null, ver integer not null, dty integer not null, usn integer not null, ls integer not null, conf text not null, models text not null, decks text not null, dconf text not null, tags text not null);
        CREATE TABLE notes (id integer primary key, guid text not null, mid integer not null, mod integer not null, usn integer not null, tags text not null, flds text not null, sfld integer not null, csum integer not null, flags integer not null, data text not null);
        CREATE TABLE cards (id integer primary key, nid integer not null, did integer not null, ord integer not null, mod integer not null, usn integer not null, type integer not null, queue integer not null, due integer not null, ivl integer not null, factor integer not null, reps integer not null, lapses integer not null, left integer not null, odue integer not null, odid integer not null, flags integer not null, data text not null);
        CREATE TABLE revlog (id integer primary key, cid integer not null, usn integer not null, ease integer not null, ivl integer not null, lastIvl integer not null, factor integer not null, time integer not null, type integer not null);
        CREATE TABLE graves (usn integer not null, oid integer not null, type integer not null);
        CREATE INDEX ix_notes_usn on notes (usn);
        CREATE INDEX ix_cards_usn on cards (usn);
        CREATE INDEX ix_revlog_usn on revlog (usn);
        CREATE INDEX ix_cards_nid on cards (nid);
        CREATE INDEX ix_cards_sched on cards (did, queue, due);
        CREATE INDEX ix_revlog_cid on revlog (cid);
        CREATE INDEX ix_notes_csum on notes (csum);
        """
    }
}
