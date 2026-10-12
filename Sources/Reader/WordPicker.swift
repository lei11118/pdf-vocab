import Foundation
import PDFKit

/// 统一取词接口(文本层实现;扫描版 OCR 词框实现见 M6)。
/// 注意:所有索引都是 PDFPage.string(NSString)的 UTF-16 索引。
enum WordPicker {

    /// 取指定字符索引处的"词"范围。落在空白处时向右取最近的词。
    static func wordRange(in page: PDFPage, at index: Int) -> NSRange? {
        guard let string = page.string else { return nil }
        let ns = string as NSString
        guard ns.length > 0, index >= 0, index < ns.length else { return nil }

        let ch = ns.character(at: index)
        if isCJK(ch) { return NSRange(location: index, length: 1) }

        var i = index
        if !isWordChar(ch) {
            var j = index
            while j < ns.length, !isWordChar(ns.character(at: j)) { j += 1 }
            guard j < ns.length else { return nil }
            if isCJK(ns.character(at: j)) { return NSRange(location: j, length: 1) }
            i = j
        }
        var start = i
        while start > 0, isWordChar(ns.character(at: start - 1)) { start -= 1 }
        var end = i + 1
        while end < ns.length, isWordChar(ns.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// 从锚点范围拖到目标索引,得到按"整词"对齐的选择范围。
    static func extendedRange(in page: PDFPage, from anchor: NSRange, to index: Int) -> NSRange? {
        guard let string = page.string else { return nil }
        let ns = string as NSString
        guard ns.length > 0 else { return nil }

        let idx = min(max(index, 0), ns.length - 1)
        var lower = min(anchor.location, idx)
        var upper = max(anchor.location + anchor.length - 1, idx)

        // 起点落在词中间 → 向左扩到词首
        if lower > 0, isWordChar(ns.character(at: lower)), isWordChar(ns.character(at: lower - 1)) {
            while lower > 0, isWordChar(ns.character(at: lower - 1)) { lower -= 1 }
        }
        // 终点落在词中间 → 向右扩到词尾
        if upper < ns.length - 1, isWordChar(ns.character(at: upper)), isWordChar(ns.character(at: upper + 1)) {
            while upper < ns.length - 1, isWordChar(ns.character(at: upper + 1)) { upper += 1 }
        }
        // 终点落在空白 → 取其后第一个词的词尾
        if !isWordChar(ns.character(at: upper)) {
            var j = upper
            while j < ns.length, !isWordChar(ns.character(at: j)) { j += 1 }
            if j < ns.length {
                var e = j
                while e < ns.length, isWordChar(ns.character(at: e)) { e += 1 }
                upper = e - 1
            } else {
                upper = max(upper, lower)
            }
        }
        guard upper >= lower else { return nil }
        return NSRange(location: lower, length: upper - lower + 1)
    }

    /// 统计词数(线性扫描,不用 NLTokenizer——长文本上会造成明显卡顿)。
    static func countWords(in text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isCJKScalar(scalar) {
                count += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord { count += 1 }
                inWord = true
            } else {
                inWord = false
            }
        }
        return count
    }

    /// 取文本中第一个"可查询词"(连续字母/连字符/撇号,排除 CJK)。
    static func firstLexicalWord(in text: String) -> String? {
        lexicalWords(in: text, limit: 1).first
    }

    /// 提取"可查询词"列表(小写、去重、保序、限量)。
    static func lexicalWords(in text: String, limit: Int = 120) -> [String] {
        var words: [String] = []
        var seen = Set<String>()
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "'’-"))
            current = ""
            guard !trimmed.isEmpty, trimmed.count <= 40 else { return }
            let lower = trimmed.lowercased()
            if seen.insert(lower).inserted {
                words.append(lower)
            }
        }
        for ch in text {
            let isCJKChar = ch.utf16.first.map { isCJK($0) } ?? false
            if (ch.isLetter && !isCJKChar) || ch == "'" || ch == "’" || ch == "-" {
                current.append(ch)
            } else if !current.isEmpty {
                flush()
                if words.count >= limit { return Array(words.prefix(limit)) }
            }
        }
        if !current.isEmpty { flush() }
        return Array(words.prefix(limit))
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    // MARK: - 字符分类

    static func isWordChar(_ ch: unichar) -> Bool {
        if isCJK(ch) { return false }
        guard let scalar = Unicode.Scalar(ch) else { return false }
        if CharacterSet.letters.contains(scalar) { return true }
        if CharacterSet.decimalDigits.contains(scalar) { return true }
        return ch == 0x27 /* ' */ || ch == 0x2019 /* ’ */
    }

    static func isCJK(_ ch: unichar) -> Bool {
        switch ch {
        case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}
