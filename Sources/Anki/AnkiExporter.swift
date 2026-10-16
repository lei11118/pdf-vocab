import Foundation
import GRDB
import UIKit
import PDFKit
import ZIPFoundation
import CryptoKit

/// M5(v0.11.0)/ v0.13.0 增强:Anki .apkg 导出(genanki 同款 **Legacy 格式**:collection.anki2 schema 11)。
/// - **稳定 GUID**(词元):重复导出同一单词,Anki 导入时**更新**该卡而非重复;
/// - 基础卡字段(9):单词 / 音标 / 中文释义 / 英文释义 / 例句 / 出处 / 备注 / 音频 / 截图;
/// - **反向卡**(释义→单词,模板 ord=1)、**挖空卡**(例句 {{c1::词}},独立 Cloze 模型)、**页面截图**(PNG 媒体);
/// - 音频 = 离线 TTS 合成 WAV(见 AnkiAudio)。
struct NoteMedia {
    let url: URL
    let name: String
}

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
    let audioName: String?
    let shotName: String?
    let media: [NoteMedia]
}

struct AnkiExportOptions {
    var deckName: String = "跃文"
    var includeAudio: Bool = true
    var includeReverse: Bool = false
    var includeCloze: Bool = false
    var includeScreenshot: Bool = false
}

/// v0.13.4:导出前自检错误(宁可不产包,也不产 Anki 会拒收的包)。
enum AnkiExportError: LocalizedError {
    case invalidCollectionJSON(String)
    var errorDescription: String? {
        switch self {
        case .invalidCollectionJSON(let detail):
            return "导出数据自检失败:\(detail)"
        }
    }
}

enum AnkiExporter {

    static let modelId: Int64 = 1_721_110_001
    static let clozeModelId: Int64 = 1_721_110_002
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

        // 1) 媒体(音频/截图统一编号 + media JSON)
        var mediaMap: [String: String] = [:]
        var mediaEntries: [(entry: String, url: URL)] = []
        for note in notes {
            for media in note.media {
                guard fm.fileExists(atPath: media.url.path) else { continue }
                let entryName = "\(mediaEntries.count)"
                mediaEntries.append((entryName, media.url))
                mediaMap[entryName] = media.name
            }
        }
        let mediaData = (try? JSONSerialization.data(withJSONObject: mediaMap, options: [.sortedKeys])) ?? Data("{}".utf8)
        try mediaData.write(to: tmpDir.appendingPathComponent("media"))
        for item in mediaEntries {
            let dest = tmpDir.appendingPathComponent(item.entry)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: item.url, to: dest)
        }

        // 2) collection.anki2(schema 11)
        let dbURL = tmpDir.appendingPathComponent("collection.anki2")
        let queue = try DatabaseQueue(path: dbURL.path)
        let models = modelsJSON(deckId: deckIdV, mod: nowMs)
        let decks = decksJSON(deckId: deckIdV, name: options.deckName, mod: nowMs)
        let conf = confJSON(deckId: deckIdV)
        let dconf = dconfJSON(mod: nowMs)
        // v0.13.4:导出前自检——按 Anki 新后端「必填字段」口径校验(如 dconf 缺 id 会被整包拒收:
        // 「decoding deck config: missing field `id`」)。宁可不产包,也不产会被 Anki 拒收的包。
        try validateCollectionJSON(models: models, decks: decks, dconf: dconf)
        var nextId = nowMs * 100 + 1
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
            for note in notes {
                // ---- 基础卡 ----
                position += 1
                let noteId = nextId; nextId += 1
                let flds = [
                    note.term,
                    note.phonetic,
                    note.translation,
                    note.definition,
                    note.context,
                    note.source,
                    note.note,
                    note.audioName.map { "[sound:\($0)]" } ?? "",
                    note.shotName.map { "<img src=\"\($0)\" class=\"shot\">" } ?? "",
                ].joined(separator: "\u{1f}")
                try db.execute(
                    sql: """
                    INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
                    VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, 0, '')
                    """,
                    arguments: [noteId, "pv_\(note.key)", modelId, nowMs, tagsField(note.tags), flds, note.term, checksum(note.term)]
                )
                var cardId = nextId; nextId += 1
                try db.execute(
                    sql: """
                    INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
                    VALUES (?, ?, ?, 0, ?, 0, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')
                    """,
                    arguments: [cardId, noteId, deckIdV, nowMs, position]
                )
                if options.includeReverse {
                    cardId = nextId; nextId += 1
                    try db.execute(
                        sql: """
                        INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
                        VALUES (?, ?, ?, 1, ?, 0, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')
                        """,
                        arguments: [cardId, noteId, deckIdV, nowMs, position]
                    )
                }
                // ---- 挖空卡 ----
                if options.includeCloze, let cloze = clozeText(context: note.context, term: note.term) {
                    position += 1
                    let clozeNoteId = nextId; nextId += 1
                    let extra = clozeExtra(note)
                    let cflds = [cloze, extra].joined(separator: "\u{1f}")
                    try db.execute(
                        sql: """
                        INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
                        VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, 0, '')
                        """,
                        arguments: [clozeNoteId, "pvc_\(note.key)", clozeModelId, nowMs, tagsField(note.tags), cflds, cloze, checksum(cloze)]
                    )
                    let clozeCardId = nextId; nextId += 1
                    try db.execute(
                        sql: """
                        INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
                        VALUES (?, ?, ?, 0, ?, 0, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')
                        """,
                        arguments: [clozeCardId, clozeNoteId, deckIdV, nowMs, position]
                    )
                }
            }
        }
        try queue.close()

        // 3) 打包 zip → .apkg
        let apkgURL = tmpDir.appendingPathComponent("跃文.apkg")
        let archive = try Archive(url: apkgURL, accessMode: .create)
        try archive.addEntry(with: "collection.anki2", relativeTo: tmpDir)
        try archive.addEntry(with: "media", relativeTo: tmpDir)
        for item in mediaEntries {
            try archive.addEntry(with: item.entry, relativeTo: tmpDir)
        }
        DiagLog.log("anki: export \(notes.count) notes / \(mediaEntries.count) media / deck=\(options.deckName) reverse=\(options.includeReverse) cloze=\(options.includeCloze)")
        return apkgURL
    }

    // MARK: - 挖空 / 截图

    /// 例句挖空:把例句中的目标词替换为 {{c1::词}}(保留原大小写;保持词边界)。
    static func clozeText(context: String, term: String) -> String? {
        guard !context.isEmpty, !term.isEmpty else { return nil }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = context as NSString
        guard let match = regex.firstMatch(in: context, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let matched = ns.substring(with: match.range)
        return ns.replacingCharacters(in: match.range, with: "{{c1::\(matched)}}")
    }

    private static func clozeExtra(_ note: AnkiNoteData) -> String {
        var parts: [String] = ["单词 <b>\(note.term)</b>"]
        if !note.phonetic.isEmpty { parts.append("/\(note.phonetic)/") }
        if !note.translation.isEmpty { parts.append(note.translation) }
        return parts.joined(separator: "<br>")
    }

    /// 页面截图:渲染指定页并裁剪高亮区域(附上下文边距)为 PNG。
    /// rects 为页坐标(与阅读器一致;PDFView 默认 displayBox = cropBox)。
    static func pageScreenshot(pdfURL: URL, pageIndex: Int, rects: [CGRect], scale: CGFloat = 2) -> Data? {
        guard let document = PDFDocument(url: pdfURL), let page = document.page(at: pageIndex) else { return nil }
        let pageBounds = page.bounds(for: .cropBox)
        guard pageBounds.width > 1, pageBounds.height > 1 else { return nil }
        let pixelSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
        guard let full = page.thumbnail(of: pixelSize, for: .cropBox).cgImage else { return nil }
        var union: CGRect = .null
        for rect in rects where rect.width > 1 && rect.height > 1 {
            union = union.isNull ? rect : union.union(rect)
        }
        guard !union.isNull else { return nil }
        var crop = CGRect(
            x: union.minX - 24,
            y: union.minY - 60,
            width: union.width + 48,
            height: union.height + 130
        )
        crop = crop.intersection(pageBounds)
        guard crop.width > 8, crop.height > 8 else { return nil }
        let pixelCrop = CGRect(
            x: (crop.minX - pageBounds.minX) * scale,
            y: (pageBounds.maxY - crop.maxY) * scale,
            width: crop.width * scale,
            height: crop.height * scale
        )
        guard let cropped = full.cropping(to: pixelCrop) else { return nil }
        return UIImage(cgImage: cropped).pngData()
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

    /// v0.13.4:按 Anki 后端的「必填字段」口径自检 col JSON(字段集以 genanki 0.13.1 输出为基准):
    /// dconf 每条必须含 id/name;decks 每条必须含 id/name;models 每个必须含 id/tmpls/flds。
    /// 任一缺失 → 抛错(避免产出「Anki 拒收」的包,如 missing field `id`)。
    static func validateCollectionJSON(models: String, decks: String, dconf: String) throws {
        func object(_ json: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        }
        guard let modelMap = object(models), let deckMap = object(decks), let configMap = object(dconf) else {
            throw AnkiExportError.invalidCollectionJSON("col JSON 无法解析")
        }
        for (key, value) in configMap {
            guard let item = value as? [String: Any], item["id"] != nil, item["name"] != nil else {
                throw AnkiExportError.invalidCollectionJSON("牌组配置 \(key) 缺 id/name(Anki 报错口径:missing field `id`)")
            }
        }
        for (key, value) in deckMap {
            guard let item = value as? [String: Any], item["id"] != nil, item["name"] != nil else {
                throw AnkiExportError.invalidCollectionJSON("牌组 \(key) 缺 id/name")
            }
        }
        for (key, value) in modelMap {
            guard let item = value as? [String: Any],
                  item["id"] != nil, item["tmpls"] != nil, item["flds"] != nil else {
                throw AnkiExportError.invalidCollectionJSON("模型 \(key) 缺 id/tmpls/flds")
            }
        }
    }

    private static func field(_ name: String, _ ord: Int) -> [String: Any] {
        ["name": name, "ord": ord, "sticky": false, "rtl": false, "font": "Arial", "size": 20, "media": []]
    }

    // MARK: - 模型 / 牌组 / 配置 JSON

    static func modelsJSON(deckId: Int64, mod: Int64) -> String {
        // 正面:单词 + 音标 + 音频
        let qfmt = """
        <div class="word">{{单词}}</div>
        <div class="phonetic">{{音标}}</div>
        <div class="audio">{{音频}}</div>
        """
        // 背面:释义 + 例句 + 出处 + 备注 + 截图
        let afmt = """
        {{FrontSide}}
        <hr id=answer>
        <div class="trans">{{中文释义}}</div>
        {{#英文释义}}<div class="def">{{英文释义}}</div>{{/英文释义}}
        {{#例句}}<div class="eg">{{例句}}</div>{{/例句}}
        {{#出处}}<div class="src">{{出处}}</div>{{/出处}}
        {{#备注}}<div class="note">{{备注}}</div>{{/备注}}
        {{#截图}}<div class="shotwrap">{{截图}}</div>{{/截图}}
        """
        // 反向卡:释义/例句在前,单词在后
        let reverseQfmt = """
        <div class="trans">{{中文释义}}</div>
        {{#例句}}<div class="eg">{{例句}}</div>{{/例句}}
        {{#出处}}<div class="src">{{出处}}</div>{{/出处}}
        """
        let reverseAfmt = """
        {{FrontSide}}
        <hr id=answer>
        <div class="word">{{单词}}</div>
        <div class="phonetic">{{音标}}</div>
        <div class="audio">{{音频}}</div>
        """
        let template0: [String: Any] = [
            "name": "Card 1", "ord": 0, "qfmt": qfmt, "afmt": afmt,
            "bqfmt": "", "bafmt": "", "did": NSNull(), "bfont": "", "bsize": 0,
        ]
        let template1: [String: Any] = [
            "name": "Card 2(反查)", "ord": 1, "qfmt": reverseQfmt, "afmt": reverseAfmt,
            "bqfmt": "", "bafmt": "", "did": NSNull(), "bfont": "", "bsize": 0,
        ]
        let basic: [String: Any] = [
            "id": modelId,
            "name": "跃文词卡",
            "type": 0,
            "mod": mod,
            "usn": 0,
            "sortf": 0,
            "did": deckId,
            "tmpls": [template0, template1],
            "flds": [
                field("单词", 0), field("音标", 1), field("中文释义", 2), field("英文释义", 3),
                field("例句", 4), field("出处", 5), field("备注", 6), field("音频", 7), field("截图", 8),
            ],
            "css": css,
            "latexPre": "\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage[utf8,utf8x]{inputenc}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n",
            "latexPost": "\\end{document}",
            "req": [[0, "any", [0]]],
            "tags": [],
            "vers": [],
        ]
        let clozeTemplate: [String: Any] = [
            "name": "Cloze", "ord": 0,
            "qfmt": "<div class=\"cloze\">{{cloze:Text}}</div>",
            "afmt": "<div class=\"cloze\">{{cloze:Text}}</div><hr id=answer><div class=\"extra\">{{Extra}}</div>",
            "bqfmt": "", "bafmt": "", "did": NSNull(), "bfont": "", "bsize": 0,
        ]
        let clozeModel: [String: Any] = [
            "id": clozeModelId,
            "name": "跃文挖空",
            "type": 1,
            "mod": mod,
            "usn": 0,
            "sortf": 0,
            "did": deckId,
            "tmpls": [clozeTemplate],
            "flds": [field("Text", 0), field("Extra", 1)],
            "css": css,
            "latexPre": "\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage[utf8,utf8x]{inputenc}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n",
            "latexPost": "\\end{document}",
            "req": [[0, "any", [0]]],
            "tags": [],
            "vers": [],
        ]
        return jsonString(["\(modelId)": basic, "\(clozeModelId)": clozeModel])
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
    .shotwrap { margin-top: 10px; }
    .shotwrap img, img.shot { max-width: 100%; border-radius: 6px; }
    .cloze { font-size: 19px; line-height: 1.6; }
    .cloze b { color: #0a84ff; }
    .extra { margin-top: 6px; font-size: 16px; color: #636366; }
    """

    static func decksJSON(deckId: Int64, name: String, mod: Int64) -> String {
        func deck(_ id: Int64, _ deckName: String) -> [String: Any] {
            // v0.13.4:补 *Today 数组(与 genanki 输出对齐;有默认值,补齐更稳)
            ["id": id, "name": deckName, "mod": mod, "usn": 0, "collapsed": false, "dyn": 0,
             "desc": "", "browserCollapsed": false, "conf": 1, "extendNew": 10, "extendRev": 50,
             "lrnToday": [0, 0], "revToday": [0, 0], "newToday": [0, 0], "timeToday": [0, 0]]
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
        // ⚠️ v0.13.4 真机实测:Anki 新后端(AnkiMobile / 桌面 2.1.50+,Rust+serde)解码牌组配置时
        // 把 id/name 视为**必填**——缺 id 会整包拒收:「decoding deck config: missing field `id`」。
        // 字段口径以 genanki 0.13.1 输出为基准(已用其生成基准包逐键核对)。
        let config: [String: Any] = [
            "id": 1, "name": "Default", "mod": mod, "usn": 0, "maxTaken": 60, "autoplay": true,
            "timer": 0, "replayq": true,
            "new": ["bury": true, "delays": [1, 10], "initialFactor": 2500,
                    "ints": [1, 4, 7], "order": 1, "perDay": 20, "separate": true] as [String: Any],
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
