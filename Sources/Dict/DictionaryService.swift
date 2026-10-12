import Foundation
import NaturalLanguage

/// 查词结果
enum LookupOutcome {
    case found(DictEntry)
    case notFound
    case dictionaryMissing
}

/// 查词服务:词形还原(NLTagger lemma)+ ECDICT 查询。
/// 查询链:原文直查 → 词形表(不规则变形)→ 词元(lemma)直查 → 词元词形表。
enum DictionaryService {

    /// 清洗查询词:去首尾标点、限长、小写。
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "'’\"“”().,;:!?[]"))
        if s.count > 40 { s = String(s.prefix(40)) }
        return s.lowercased()
    }

    /// 词形还原(英文)。失败或与原词相同时返回 nil。
    static func lemma(of word: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        var lemma: String?
        tagger.enumerateTags(
            in: word.startIndex..<word.endIndex,
            unit: .word,
            scheme: .lemma,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, _ in
            if let tag {
                lemma = tag.rawValue.lowercased()
            }
            return false
        }
        guard let l = lemma, !l.isEmpty, l != word.lowercased() else { return nil }
        return l
    }

    static func lookup(_ raw: String) -> LookupOutcome {
        let store = DictionaryStore.shared
        guard store.isAvailable else { return .dictionaryMissing }
        let word = normalize(raw)
        guard !word.isEmpty else { return .notFound }

        // ① 直查
        if let entry = store.entry(for: word) {
            return .found(entry)
        }
        // ② 词形表(不规则变形:went→go 等)
        if let head = store.headword(forForm: word), let entry = store.entry(for: head) {
            return .found(entry)
        }
        // ③ 词形还原再查
        if let lemma = lemma(of: word) {
            if let entry = store.entry(for: lemma) {
                return .found(entry)
            }
            if let head = store.headword(forForm: lemma), let entry = store.entry(for: head) {
                return .found(entry)
            }
        }
        return .notFound
    }
}
