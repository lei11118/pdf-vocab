import XCTest
@testable import PdfVocab

@MainActor final class DictionaryCombinationTests: XCTestCase {
    func testScientificSourcesAreBundledAndWordnetComplementsChinese() throws {
        let store = DictionaryStore.shared
        let ids = store.catalog().map(\.id)
        XCTAssertEqual(ids.filter { $0.hasPrefix("science.") }.count,8)
        let disabled = UserDefaults.standard.stringArray(forKey:"dictionary.disabled.v1")
        defer { UserDefaults.standard.set(disabled,forKey:"dictionary.disabled.v1") }
        UserDefaults.standard.set([],forKey:"dictionary.disabled.v1")
        let entry = try XCTUnwrap(store.entry(for:"algorithm"))
        XCTAssertTrue(entry.sources.contains("ECDICT · 计算机"))
        XCTAssertTrue(entry.translation?.contains("算法") == true)
        let derivative = try XCTUnwrap(store.entry(for:"derivative"))
        XCTAssertTrue(derivative.definition?.contains("mathematical differentiation") == true)
        store.setEnabled("science.computing",false)
        XCTAssertFalse(store.entry(for:"algorithm")?.sources.contains("ECDICT · 计算机") == true)
        store.setEnabled("wordnet",false)
        XCTAssertFalse(store.entry(for:"derivative")?.sources.contains("Open English WordNet") == true)
    }
    func testIndependentImportsCombineAndCanBeDisabledSeparately() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = DictionaryStore.shared
        var imported: [String] = []
        defer { for id in imported { try? store.removeImportedDictionary(id) } }
        for (name,meaning) in [("Science A","专业释义甲"),("Science B","专业释义乙")] {
            let word = "codexsciencetestword", data = Data(meaning.utf8)
            var index = Data(word.utf8); index.append(0)
            index.append(contentsOf:[0,0,0,0])
            let size = UInt32(data.count)
            index.append(contentsOf:[UInt8((size>>24)&255),UInt8((size>>16)&255),UInt8((size>>8)&255),UInt8(size&255)])
            let ifo = root.appendingPathComponent("test.ifo"),idx=root.appendingPathComponent("test.idx"),dict=root.appendingPathComponent("test.dict")
            try "StarDict's dict ifo file\nversion=2.4.2\nbookname=\(name)\nwordcount=1\nidxfilesize=\(index.count)\nsametypesequence=m\n".write(to:ifo,atomically:true,encoding:.utf8)
            try index.write(to:idx); try data.write(to:dict)
            let result = try StarDictImporter.importDictionary(pickedFiles:[ifo,idx,dict]) { _ in }
            imported.append(result.dictionaryId)
        }
        store.reloadUserDictionary()
        let combined = try XCTUnwrap(store.entry(for:"codexsciencetestword"))
        XCTAssertEqual(Set(combined.sources),Set(["Science A","Science B"]))
        XCTAssertTrue(combined.translation?.contains("专业释义甲") == true)
        XCTAssertTrue(combined.translation?.contains("专业释义乙") == true)
        store.setEnabled(imported[0],false)
        XCTAssertEqual(store.entry(for:"codexsciencetestword")?.sources,["Science B"])
        store.setEnabled(imported[0],true)
    }
    func testLeavingHoverCancelsDelayedPreview() async throws {
        let session = WordInteractionSession()
        session.hover("algorithm",at:.zero)
        session.clear()
        try await Task.sleep(nanoseconds:300_000_000)
        XCTAssertNil(session.preview)
        XCTAssertFalse(session.squeeze())
    }
}
