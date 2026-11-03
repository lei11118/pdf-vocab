import Foundation
import SwiftUI
import PDFKit
import NaturalLanguage
import Translation
import CryptoKit
import GRDB

struct TranslationLocation: Equatable {
    var page: Int
    var character: Int
}
struct TranslationWordLink: Codable, Equatable, Identifiable {
    var sourceStart: Int
    var sourceLength: Int
    var word: String
    var targetStart: Int?
    var targetLength: Int?
    var meaning: String?
    var reviewed = false
    var confidence: Double = 0
    var id: Int { sourceStart }
}
struct TranslatedSentence: Codable, Equatable, Identifiable {
    var id: String
    var page: Int
    var start: Int
    var length: Int
    var source: String
    var target = ""
    var links: [TranslationWordLink] = []
    var reviewed = false
    var origin = "Apple Translation"
}

/// Occurrence-based UTF-16 ranges: repeated words in different sentences never share a correction.
/// An untranslated/unaligned token remains explicitly pending; it is never assigned a fabricated gloss.
enum TranslationAlignment {
    static func tokens(_ text: String) -> [TranslationWordLink] {
        var result: [TranslationWordLink] = []
        text.enumerateSubstrings(in:text.startIndex..<text.endIndex,options:.byWords) { word,range,_,_ in
            guard let word else { return }
            let r = NSRange(range,in:text)
            result.append(TranslationWordLink(sourceStart:r.location,sourceLength:r.length,word:word))
        }
        return result
    }
    static func align(source: String, target: String, lookup: (String) -> String?) -> [TranslationWordLink] {
        let chinese = try! NSRegularExpression(pattern:"[\\p{Han}]{2,12}")
        let targetNS = target as NSString
        return tokens(source).map { token in
            var token = token
            guard let definitions = lookup(token.word) else { return token }
            let cleaned = definitions.replacingOccurrences(of:"【[^】]*】",with:"",options:.regularExpression)
            let ns = cleaned as NSString
            let candidates = Set(chinese.matches(in:cleaned,range:NSRange(location:0,length:ns.length)).map { ns.substring(with:$0.range) })
            let matches = candidates.compactMap { value -> (String,NSRange)? in
                let r = targetNS.range(of:value)
                guard r.location != NSNotFound else { return nil }
                return (value,r)
            }.sorted { $0.0.count > $1.0.count }
            if let candidate = matches.first {
                token.meaning = candidate.0; token.targetStart = candidate.1.location; token.targetLength = candidate.1.length
                // Lexicon matches are suggestions, not neural or human verification.
                token.confidence = matches.count == 1 ? 0.65 : 0.35
            }
            return token
        }
    }
    static func sentences(text: String, page: Int) -> [TranslatedSentence] {
        let tokenizer = NLTokenizer(unit:.sentence); tokenizer.string = text; tokenizer.setLanguage(.english)
        var result: [TranslatedSentence] = []
        tokenizer.enumerateTokens(in:text.startIndex..<text.endIndex) { range,_ in
            let source = String(text[range]),r = NSRange(range,in:text)
            guard source.unicodeScalars.filter({ CharacterSet.letters.contains($0) && $0.isASCII }).count >= 2 else { return true }
            let digest = SHA256.hash(data:Data(source.utf8)).map { String(format:"%02x",$0) }.joined()
            result.append(TranslatedSentence(id: "\(page)-\(r.location)-\(digest)",page:page,start:r.location,length:r.length,source:source,links:tokens(source)))
            return true
        }
        return result
    }
    static func correction(in records: [TranslatedSentence], term: String, location: TranslationLocation) -> String {
        guard let sentence = records.first(where: { $0.page == location.page && location.character >= $0.start && location.character < $0.start+$0.length }) else {
            return "【校对】待全文解析"
        }
        guard !sentence.target.isEmpty else { return "【校对】本句待翻译" }
        let offset = location.character-sentence.start
        let link = sentence.links.first { offset >= $0.sourceStart && offset < $0.sourceStart+$0.sourceLength }
        if let link,link.word.caseInsensitiveCompare(term) == .orderedSame,let meaning = link.meaning,!meaning.isEmpty {
            return "【校对：\(link.reviewed ? "人工已确认" : "自动链接·待校对")】\n\(meaning)\n【原句】\n\(sentence.source)\n【句译\(sentence.reviewed ? "·已校对" : "·机器译文")】\n\(sentence.target)"
        }
        return "【校对】尚无可靠词语链接，待校对\n【原句】\n\(sentence.source)\n【句译·机器译文】\n\(sentence.target)"
    }
}

final class DocumentTranslationRepository: @unchecked Sendable {
    let db: AppDatabase
    init(db:AppDatabase) { self.db = db }
    func load(doc: String) throws -> [TranslatedSentence] {
        try db.dbQueue.write { db in
            try db.execute(sql:"CREATE TABLE IF NOT EXISTS document_translation(doc TEXT NOT NULL,id TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(doc,id))")
            return try Data.fetchAll(db,sql:"SELECT payload FROM document_translation WHERE doc=?",arguments:[doc]).compactMap { try? JSONDecoder().decode(TranslatedSentence.self,from:$0) }
        }
    }
    func save(doc:String,records:[TranslatedSentence],preservingReviews:Bool = false) throws {
        try db.dbQueue.write { db in
            for record in records {
                if preservingReviews,
                   let data = try Data.fetchOne(db,sql:"SELECT payload FROM document_translation WHERE doc=? AND id=?",arguments:[doc,record.id]),
                   let saved = try? JSONDecoder().decode(TranslatedSentence.self,from:data),
                   saved.reviewed || saved.links.contains(where: { $0.reviewed }) { continue }
                try db.execute(sql:"INSERT OR REPLACE INTO document_translation(doc,id,payload) VALUES(?,?,?)",arguments:[doc,record.id,try JSONEncoder().encode(record)])
            }
        }
    }
}

@MainActor final class DocumentTranslationModel: ObservableObject {
    let doc: String
    let repository: DocumentTranslationRepository
    @Published private(set) var records: [TranslatedSentence] = []
    @Published private(set) var ready = false
    @Published var running = false
    @Published var paused = false
    @Published var error: String?
    @Published var retry = 0
    init(doc:String,db:AppDatabase) { self.doc = doc; repository = DocumentTranslationRepository(db:db) }
    var completed: Int { records.filter { !$0.target.isEmpty }.count }
    var pending: [TranslatedSentence] { records.filter { $0.target.isEmpty } }
    var status: String {
        if let error { return error }
        if !ready { return "正在解析全文…" }
        if records.isEmpty { return "未发现可翻译英文句子" }
        return "全文翻译 \(completed)/\(records.count)\(paused ? " · 已暂停" : running ? " · 端侧处理" : "")"
    }
    func prepare(url: URL, ocr: OCRStore) async {
        guard !ready else { return }
        do {
            let repository = self.repository, doc = self.doc
            let values = try await Task.detached(priority:.utility) { () throws -> [TranslatedSentence] in
                let cache = Dictionary(uniqueKeysWithValues:try repository.load(doc:doc).map { ($0.id,$0) })
                guard let pdf = PDFDocument(url:url) else { throw CocoaError(.fileReadCorruptFile) }
                var result: [TranslatedSentence] = []
                for index in 0..<pdf.pageCount {
                    try Task.checkCancellation()
                    var text = pdf.page(at:index)?.string ?? ""
                    if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                        text = ocr.words(docSha:doc,page:index).map(\.text).joined(separator:" ")
                    }
                    result += TranslationAlignment.sentences(text:text,page:index).map { cache[$0.id] ?? $0 }
                }
                return result
            }.value
            guard !Task.isCancelled else { return }
            records = values; ready = true
        } catch is CancellationError {} catch { self.error = "全文解析失败：\(error.localizedDescription)" }
    }
    func cachedTranslation(text:String,location:TranslationLocation?) -> String? {
        let key = text.trimmingCharacters(in:.whitespacesAndNewlines)
        let matches = records.filter { $0.source.trimmingCharacters(in:.whitespacesAndNewlines) == key && !$0.target.isEmpty }
        let match = location.flatMap { location in matches.first { $0.page == location.page && location.character >= $0.start && location.character < $0.start+$0.length } } ?? (matches.count == 1 ? matches.first : nil)
        return match.map { "【句译·\($0.reviewed ? "已校对" : "机器译文")】\n\($0.target)" }
    }
    func correction(term:String,location:TranslationLocation?) -> String {
        guard let location else { return "【校对】请从 PDF 中选取具体词语以关联原句" }
        return TranslationAlignment.correction(in:records,term:term,location:location)
    }
    func accept(_ values:[TranslatedSentence],preservingReviews:Bool = true) async throws {
        let repository = self.repository, doc = self.doc
        // Persist the batch before marking it complete, so interruption resumes without losing work.
        try await Task.detached(priority:.utility) { try repository.save(doc:doc,records:values,preservingReviews:preservingReviews) }.value
        let updates = Dictionary(uniqueKeysWithValues:values.map { ($0.id,$0) })
        records = records.map { current in
            if preservingReviews && (current.reviewed || current.links.contains(where:{ $0.reviewed })) { return current }
            return updates[current.id] ?? current
        }
    }
    func review(sentence:TranslatedSentence,target:String,word:Int?,meaning:String) {
        guard !target.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { error = "请输入句译后再保存校对"; return }
        var value = sentence
        if word == nil { value.reviewed = true }
        if target != sentence.target {
            value.target = target; value.reviewed = true
            value.links = TranslationAlignment.align(source:value.source,target:target,lookup:WordInteraction.detail)
        }
        if let word,let index = value.links.firstIndex(where: { $0.sourceStart == word }) {
            let gloss = meaning.trimmingCharacters(in:.whitespacesAndNewlines)
            value.links[index].meaning = gloss
            let range = gloss.isEmpty ? NSRange(location:NSNotFound,length:0) : (target as NSString).range(of:gloss)
            value.links[index].targetStart = range.location == NSNotFound ? nil : range.location
            value.links[index].targetLength = range.location == NSNotFound ? nil : range.length
            value.links[index].reviewed = !meaning.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
            value.links[index].confidence = value.links[index].reviewed ? 1 : 0
        }
        let result = value
        if let index = records.firstIndex(where: { $0.id == result.id }) { records[index] = result }
        Task { do { try await accept([result],preservingReviews:false) } catch { self.error = "校对保存失败：\(error.localizedDescription)" } }
    }
}

@available(iOS 18.0, *)
struct DocumentTranslationDriver: View {
    @ObservedObject var model: DocumentTranslationModel
    @State private var configuration: TranslationSession.Configuration?
    var body: some View {
        Color.clear.frame(width:0,height:0).allowsHitTesting(false)
            .translationTask(configuration) { session in
                guard model.ready,!model.paused else { return }
                model.running = true; model.error = nil
                defer { model.running = false }
                do {
                    try await session.prepareTranslation()
                    while !model.pending.isEmpty && !model.paused {
                        try Task.checkCancellation()
                        let batch = Array(model.pending.prefix(16))
                        let requests = batch.map { TranslationSession.Request(sourceText:$0.source,clientIdentifier:$0.id) }
                        let responses = try await session.translate(batch:requests)
                        var translated: [(String,String)] = []
                        for try await response in responses {
                            if let id = response.clientIdentifier { translated.append((id,response.targetText)) }
                        }
                        let output = translated
                        let originals = Dictionary(uniqueKeysWithValues:batch.map { ($0.id,$0) })
                        let results = await Task.detached(priority:.utility) {
                            output.compactMap { id,target -> TranslatedSentence? in
                                guard var value = originals[id] else { return nil }
                                value.target = target
                                value.links = TranslationAlignment.align(source:value.source,target:value.target,lookup:WordInteraction.detail)
                                return value
                            }
                        }.value
                        guard results.count == batch.count,results.allSatisfy({ !$0.target.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }) else { throw CocoaError(.coderValueNotFound) }
                        try await model.accept(results)
                        await Task.yield()
                    }
                } catch is CancellationError {} catch { model.error = "全文翻译暂停：\(error.localizedDescription)；可在全文校对中重试" }
            }
            .onAppear { configure() }
            .onChange(of:model.ready) { _,_ in configure() }
            .onChange(of:model.paused) { _,_ in configure() }
            .onChange(of:model.retry) { _,_ in configure() }
    }
    private func configure() {
        guard model.ready,!model.paused,!model.pending.isEmpty else { configuration = nil; return }
        if configuration == nil { configuration = .init(source:Locale.Language(identifier:"en"),target:Locale.Language(identifier:"zh-Hans")) }
        else { configuration?.invalidate() }
    }
}

struct DocumentTranslationReview: View {
    @ObservedObject var model: DocumentTranslationModel
    @State private var page = 0
    var body: some View {
        VStack(spacing:8) {
            HStack {
                Text(model.status).font(.caption)
                Spacer()
                Button(model.paused ? "继续" : "暂停") { model.paused.toggle() }
                Button("重试") { model.error = nil; model.paused = false; model.retry += 1 }
            }.padding(.horizontal)
            Text("机器译文与自动词语链接均需校对；点击原词可保存该处语境释义。首次使用可能需要下载系统语言包。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            Stepper("第 \(page+1) 页",value:$page,in:0...max(0,model.records.map(\.page).max() ?? 0)).padding(.horizontal)
            ScrollView {
                LazyVStack(spacing:16) {
                    ForEach(model.records.filter { $0.page == page }) { record in
                        TranslationSentenceEditor(sentence:record,onSave:{ target,word,meaning in
                            model.review(sentence:record,target:target,word:word,meaning:meaning)
                        }).id(record.id)
                    }
                }.padding()
            }
        }.onAppear { if #unavailable(iOS 18.0) { model.error = "端侧全文翻译需要 iPadOS 18 或更高版本" } }
    }
}
private struct TranslationSentenceEditor: View {
    let sentence: TranslatedSentence
    let onSave: (String,Int?,String) -> Void
    @State private var target = ""
    @State private var word: Int?
    @State private var meaning = ""
    @State private var dirty = false
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(sentence.source).textSelection(.enabled)
            Text(sentence.reviewed ? "句译 · 已校对" : "句译 · 机器译文").font(.caption).foregroundStyle(.secondary)
            TextEditor(text:Binding(get:{target},set:{target = $0; dirty = true})).frame(minHeight:80)
            ScrollView(.horizontal) {
                HStack {
                    ForEach(sentence.links) { link in
                        Button(link.word) { word = link.sourceStart; meaning = link.meaning ?? "" }
                            .buttonStyle(.bordered).tint(word == link.sourceStart ? .accentColor : .secondary)
                    }
                }
            }
            if word != nil {
                TextField("该处词语对应译文（可多词短语）",text:$meaning).textFieldStyle(.roundedBorder)
                Text("若释义出现在句译中，会同时保存目标文字范围；原词按具体出现位置关联。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button("保存校对") { onSave(target,word,meaning); dirty = false }
        }.padding().background(Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:20))
            .onAppear { target = sentence.target; dirty = false }
            .onChange(of:sentence.target) { _,value in if !dirty { target = value } }
    }
}

struct ReaderSentenceTranslationView: View {
    let text: String
    var cached: String? = nil
    @State private var translated = ""
    @State private var failure: String?
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text(text).textSelection(.enabled)
                Divider()
                if let cached { Text(cached).textSelection(.enabled) }
                else if let failure { Text(failure) }
                else if translated.isEmpty { ProgressView("正在端侧翻译…") }
                else { Text(translated).textSelection(.enabled) }
            }.padding()
        }.background { if cached == nil { if #available(iOS 18.0, *) { SentenceTranslationTask(text:text,onResult:{translated = $0},onError:{failure = $0}) } } }
            .onAppear { if #unavailable(iOS 18.0) { failure = "端侧翻译需要 iPadOS 18 或更高版本" } }
    }
}
@available(iOS 18.0, *)
private struct SentenceTranslationTask: View {
    let text: String
    let onResult: (String) -> Void
    let onError: (String) -> Void
    var body: some View {
        Color.clear.frame(width:0,height:0)
            .translationTask(source:Locale.Language(identifier:"en"),target:Locale.Language(identifier:"zh-Hans")) { session in
                do { onResult(try await session.translate(text).targetText) }
                catch { onError("翻译失败：\(error.localizedDescription)") }
            }
    }
}
