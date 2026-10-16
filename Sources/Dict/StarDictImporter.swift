import Foundation
import UIKit
import Compression
import UniformTypeIdentifiers
import GRDB
import ZIPFoundation

/// v0.13.0(P2):StarDict 词典导入 —— 支持 .ifo/.idx/.dict(.dict.dz) 三件套(可多选),
/// 或把整套文件打包成 .zip 直接选;解析后生成 userdict.sqlite(schema 与内置词库相同,查词优先命中)。
/// 已知限制:词条编码按 UTF-8 解析(仅极老词典用 GBK,会乱码);`.dict.dz` 手动跳过 gzip 头后流式解压。
enum StarDictImporter {

    struct ImportResult {
        let bookName: String
        let entryCount: Int
    }

    enum ImportError: LocalizedError {
        case missingFiles
        case badIfo
        case noData
        case emptyDictionary

        var errorDescription: String? {
            switch self {
            case .missingFiles: return "找不到 .ifo / .idx / .dict(.dz) 三件套(请一起选择,或打包成 zip)"
            case .badIfo: return ".ifo 文件格式不正确"
            case .noData: return "缺少 .dict 或 .dict.dz 数据文件,或数据无法解析"
            case .emptyDictionary: return "词典没有可导入的词条"
            }
        }
    }

    /// pickedFiles:用户选择的文件(单个 .zip 自动解包;或 .ifo/.idx/.dict/.dz 多选)。
    static func importDictionary(pickedFiles: [URL], progress: @escaping (String) -> Void) throws -> ImportResult {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("stardict-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // 1) 收集文件(单个 zip 自动解包)
        var files: [URL] = []
        for url in pickedFiles {
            if url.pathExtension.lowercased() == "zip" {
                progress("解压词典包…")
                let dest = workDir.appendingPathComponent("unzipped", isDirectory: true)
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                guard let archive = try? Archive(url: url, accessMode: .read) else { throw ImportError.missingFiles }
                for entry in archive where entry.type == .file {
                    let out = dest.appendingPathComponent(entry.path)
                    try? fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                    _ = try? archive.extract(entry, to: out)
                }
                if let enumerator = fm.enumerator(at: dest, includingPropertiesForKeys: [.isRegularFileKey]) {
                    for case let fileURL as URL in enumerator {
                        if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                            files.append(fileURL)
                        }
                    }
                }
            } else {
                files.append(url)
            }
        }

        guard let ifoURL = files.first(where: { $0.pathExtension.lowercased() == "ifo" }) else {
            throw ImportError.missingFiles
        }
        let base = ifoURL.deletingPathExtension()
        guard let idxURL = files.first(where: { $0.pathExtension.lowercased() == "idx" })
            ?? (fm.fileExists(atPath: base.appendingPathExtension("idx").path) ? base.appendingPathExtension("idx") : nil) else {
            throw ImportError.missingFiles
        }
        let dictPlain = files.first(where: { $0.pathExtension.lowercased() == "dict" })
            ?? (fm.fileExists(atPath: base.appendingPathExtension("dict").path) ? base.appendingPathExtension("dict") : nil)
        let dictDz = files.first(where: { $0.pathExtension.lowercased() == "dz" })
            ?? (fm.fileExists(atPath: base.path + ".dict.dz") ? URL(fileURLWithPath: base.path + ".dict.dz") : nil)
        guard dictPlain != nil || dictDz != nil else { throw ImportError.noData }

        // 2) .ifo 元数据
        progress("读取词典信息…")
        let ifoText = (try? String(contentsOf: ifoURL, encoding: .utf8)) ?? ""
        var ifo: [String: String] = [:]
        for line in ifoText.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            ifo[key] = value
        }
        guard ifo["bookname"] != nil, ifo["idxfilesize"] != nil else { throw ImportError.badIfo }
        let bookName = ifo["bookname"] ?? "用户词典"
        let sameType = ifo["sametypesequence"]

        // 3) 数据文件:.dz → 流式解压为 .dict
        var dictURL = dictPlain
        if dictURL == nil, let dictDz {
            progress("解压 .dict.dz(字典较大时需要一会儿)…")
            let out = workDir.appendingPathComponent("dictionary.dict")
            try gunzipStream(from: dictDz, to: out)
            dictURL = out
        }
        guard let dictURL else { throw ImportError.noData }
        let dictHandle = try FileHandle(forReadingFrom: dictURL)
        defer { try? dictHandle.close() }

        // 4) 解析 .idx(word\0 + 4B 偏移 + 4B 长度,大端序)
        progress("解析词条索引…")
        guard let idxData = try? Data(contentsOf: idxURL) else { throw ImportError.missingFiles }
        let idxBytes = [UInt8](idxData)
        var entries: [(word: String, offset: UInt32, size: UInt32)] = []
        var cursor = 0
        while cursor < idxBytes.count {
            guard let zeroIndex = idxBytes[cursor...].firstIndex(of: 0), zeroIndex + 9 <= idxBytes.count else { break }
            let wordData = Data(idxBytes[cursor..<zeroIndex])
            let word = String(data: wordData, encoding: .utf8) ?? String(decoding: wordData, as: UTF8.self)
            let offset = (UInt32(idxBytes[zeroIndex + 1]) << 24) | (UInt32(idxBytes[zeroIndex + 2]) << 16)
                | (UInt32(idxBytes[zeroIndex + 3]) << 8) | UInt32(idxBytes[zeroIndex + 4])
            let size = (UInt32(idxBytes[zeroIndex + 5]) << 24) | (UInt32(idxBytes[zeroIndex + 6]) << 16)
                | (UInt32(idxBytes[zeroIndex + 7]) << 8) | UInt32(idxBytes[zeroIndex + 8])
            entries.append((word: word, offset: offset, size: size))
            cursor = zeroIndex + 9
            if entries.count >= 1_500_000 { break }
        }
        guard !entries.isEmpty else { throw ImportError.emptyDictionary }

        // 5) 逐条读取释义并入库(每 2000 条一个事务)
        progress("构建词典数据库(0/\(entries.count))…")
        let outURL = try DictionaryStore.userDatabaseURL()
        let tmpURL = outURL.deletingLastPathComponent().appendingPathComponent("userdict.import.sqlite")
        try? fm.removeItem(at: tmpURL)
        let queue = try DatabaseQueue(path: tmpURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
                CREATE TABLE dict(word TEXT PRIMARY KEY, phonetic TEXT, translation TEXT, definition TEXT, pos TEXT,
                                  collins INTEGER DEFAULT 0, oxford INTEGER DEFAULT 0, tag TEXT,
                                  bnc INTEGER DEFAULT 0, frq INTEGER DEFAULT 0);
                CREATE TABLE form(form TEXT PRIMARY KEY, word TEXT);
                """)
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('bookname', ?)", arguments: [bookName])
        }

        var written = 0
        var skipped = 0
        var batch: [(String, String?, String)] = []
        func flush(_ items: [(String, String?, String)]) {
            guard !items.isEmpty else { return }
            try? queue.write { db in
                for item in items {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO dict (word, phonetic, translation) VALUES (?, ?, ?)",
                        arguments: [item.0, item.1, item.2]
                    )
                }
            }
        }
        for (i, entry) in entries.enumerated() {
            if i % 5_000 == 0 { progress("构建词典数据库(\(i)/\(entries.count))…") }
            let word = entry.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !word.isEmpty else { skipped += 1; continue }
            dictHandle.seek(toFileOffset: UInt64(entry.offset))
            guard let chunk = try? dictHandle.read(upToCount: Int(entry.size)), let chunk, !chunk.isEmpty else {
                skipped += 1
                continue
            }
            let (phonetic, text) = parseEntry(chunk, sameType: sameType)
            guard !text.isEmpty else { skipped += 1; continue }
            batch.append((word, phonetic, text))
            written += 1
            if batch.count >= 2_000 {
                flush(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        flush(batch)
        try queue.close()

        // 6) 安装(原子替换)
        try? fm.removeItem(at: outURL)
        try fm.moveItem(at: tmpURL, to: outURL)
        DiagLog.log("stardict: imported 「\(bookName)」 entries=\(written) skipped=\(skipped)")
        return ImportResult(bookName: bookName, entryCount: written)
    }

    // MARK: - 释义解析(尽力而为)

    /// 剥离行首类型字节、HTML → 纯文本、抽取音标。
    private static func parseEntry(_ chunk: Data, sameType: String?) -> (phonetic: String?, text: String) {
        var raw = String(data: chunk, encoding: .utf8) ?? String(decoding: chunk, as: UTF8.self)
        if sameType?.contains("h") == true || raw.contains("<") {
            raw = raw.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            raw = raw.replacingOccurrences(of: "(?i)</p>", with: "\n", options: .regularExpression)
            raw = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        let typeChars: Set<Character> = ["m", "l", "g", "t", "x", "y", "k", "w", "h", "r", "W", "P", "n"]
        var lines: [String] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if sameType == nil, let first = line.first, typeChars.contains(first), line.count > 1 {
                let second = line[line.index(after: line.startIndex)]
                // 第二字符不是小写 ASCII 字母 → 该字符更像类型字节而非正文
                if !(second.isLowercase && second.isLetter) {
                    line = String(line.dropFirst())
                }
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append(line) }
        }
        var phonetic: String?
        if let idx = lines.firstIndex(where: { $0.hasPrefix("[") && $0.hasSuffix("]") && $0.count <= 48 }) {
            phonetic = String(lines[idx].dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if phonetic?.isEmpty == true { phonetic = nil }
            lines.remove(at: idx)
        }
        return (phonetic, lines.joined(separator: "\n"))
    }

    // MARK: - gzip 流式解压(.dict.dz)

    /// 手动跳过 gzip 头,用 Compression 框架(COMPRESSION_ZLIB = raw deflate)流式解压。
    private static func gunzipStream(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        fm.createFile(atPath: dst.path, contents: nil)
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }

        // gzip 头(10 字节 + 可选字段)
        let header = try input.read(upToCount: 10) ?? Data()
        guard header.count == 10,
              header[header.startIndex] == 0x1f,
              header[header.index(after: header.startIndex)] == 0x8b else {
            throw ImportError.noData
        }
        let flags = header[header.index(header.startIndex, offsetBy: 3)]
        func skipCString() throws {
            while true {
                guard let byte = try input.read(upToCount: 1), !byte.isEmpty else { break }
                if byte[byte.startIndex] == 0 { break }
            }
        }
        if flags & 0x04 != 0 {   // FEXTRA(dictzip 的随机访问字段在此)
            guard let xlenData = try input.read(upToCount: 2), xlenData.count == 2 else { throw ImportError.noData }
            let xlen = Int(xlenData[xlenData.startIndex]) | (Int(xlenData[xlenData.startIndex + 1]) << 8)
            _ = try input.read(upToCount: xlen)
        }
        if flags & 0x08 != 0 { try skipCString() }   // FNAME
        if flags & 0x10 != 0 { try skipCString() }   // FCOMMENT
        if flags & 0x02 != 0 { _ = try input.read(upToCount: 2) }   // FHCRC

        let bufferSize = 1 << 20
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dstBuffer.deallocate() }
        var stream = compression_stream(
            dst_ptr: dstBuffer,
            dst_size: bufferSize,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 0x1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ImportError.noData
        }
        defer { compression_stream_destroy(&stream) }

        var finished = false
        var sawEOF = false
        while !finished {
            var chunk = (try input.read(upToCount: bufferSize)) ?? Data()
            if chunk.isEmpty { sawEOF = true }
            let flags: Int32 = sawEOF ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                if raw.count > 0 {
                    stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
                    stream.src_size = raw.count
                } else {
                    stream.src_size = 0
                }
                var lastStatus = COMPRESSION_STATUS_OK
                repeat {
                    stream.dst_ptr = dstBuffer
                    stream.dst_size = bufferSize
                    let status = compression_stream_process(&stream, flags)
                    if status == COMPRESSION_STATUS_ERROR { throw ImportError.noData }
                    lastStatus = status
                    let produced = bufferSize - stream.dst_size
                    if produced > 0 {
                        try output.write(contentsOf: Data(bytes: dstBuffer, count: produced))
                    }
                    if status == COMPRESSION_STATUS_END {
                        finished = true
                        return
                    }
                } while stream.src_size > 0 || (lastStatus == COMPRESSION_STATUS_OK && stream.dst_size == 0)
            }
            if sawEOF && !finished {
                // 输入耗尽但未收到 END:依赖 FINALIZE 的最后一轮已尽力,退出避免死循环
                break
            }
        }
    }
}

// MARK: - StarDict 文件选择器(多选;沿用文档库的 UIDocumentPicker asCopy 方案)

struct StarDictPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .zip], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}
