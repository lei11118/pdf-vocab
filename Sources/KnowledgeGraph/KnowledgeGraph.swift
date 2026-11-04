import Foundation
import CoreGraphics
import Combine
import GRDB

enum GraphConfig {
    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 4
    static let minSize: CGFloat = 100
    static let saveDelay = 0.5
    static let anchorSize: CGFloat = 44
    static let resizeSize: CGFloat = 44
    static let edgeWidth: CGFloat = 1.25
    static let edgeHitWidth: CGFloat = 20
    static let snapshotZoom: CGFloat = 0.55
    static let nodeSize = CGSize(width: 300, height: 200)
    static let headerHeight: CGFloat = 32
}

enum GraphAnchor: String, CaseIterable, Codable {
    case top, right, bottom, left
    func point(in frame: CGRect) -> CGPoint {
        switch self {
        case .top: return CGPoint(x: frame.midX, y: frame.minY)
        case .right: return CGPoint(x: frame.maxX, y: frame.midY)
        case .bottom: return CGPoint(x: frame.midX, y: frame.maxY)
        case .left: return CGPoint(x: frame.minX, y: frame.midY)
        }
    }
    static func nearest(to point: CGPoint, frame: CGRect) -> Self {
        allCases.min { a, b in
            let p = a.point(in: frame), q = b.point(in: frame)
            return hypot(p.x-point.x,p.y-point.y) < hypot(q.x-point.x,q.y-point.y)
        } ?? .top
    }
}

struct GraphWord: Codable, Equatable {
    var text: String
    var rect: CGRect // normalized, top-left origin
}
struct GraphScreenshot: Codable, Equatable {
    var imagePath: String
    var thumbPath: String
    var sourceDocId: String
    var pageIndex: Int
    var sourceRect: CGRect // normalized PDF crop box, bottom-left origin
    var words: [GraphWord] = []
    var ocrStatus = "pending"
}
struct KnowledgeNode: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, screenshot, ink, document }
    var id = UUID().uuidString
    var graphId: String
    var kind: Kind
    var frame: CGRect
    var zIndex = 0
    var text = ""
    /// Only master-graph book nodes have a target; old graph payloads omit it.
    var sourceDocumentId: String?
    var screenshot: GraphScreenshot?
    var drawingData = Data()
    var isNew = true
    var createdAt = Date()
    var updatedAt = Date()
}
struct KnowledgeEdge: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var from: String
    var fromAnchor: GraphAnchor
    var to: String
    var toAnchor: GraphAnchor
    var label = ""
    var directed = false
    var createdAt = Date()
}
struct KnowledgeGraph: Codable, Equatable {
    static let libraryID = "__library_knowledge_graph_v1__"
    var id: String
    var docId: String
    var offset = CGPoint(x: 80, y: 80)
    var zoom: CGFloat = 1
    var nodes: [KnowledgeNode] = []
    var edges: [KnowledgeEdge] = []
    var migrationVersion = 0
    var createdAt = Date()
    var updatedAt = Date()

    @discardableResult mutating func syncDocuments(_ documents: [DocumentRecord]) -> Bool {
        var known = Set(nodes.compactMap(\.sourceDocumentId))
        var index = known.count
        var changed = false
        for document in documents where known.insert(document.sha256).inserted {
            let frame = CGRect(x:(index % 4) * 340,y:(index / 4) * 240,width:300,height:200)
            nodes.append(KnowledgeNode(graphId:id,kind:.document,frame:frame,
                                       zIndex:(nodes.map(\.zIndex).max() ?? -1)+1,
                                       text:document.title,sourceDocumentId:document.sha256,isNew:false))
            index += 1; changed = true
        }
        return changed
    }

    mutating func delete(_ id: String) {
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.from == id || $0.to == id || $0.id == id }
    }
    mutating func connect(from: String, anchor: GraphAnchor, to: String, target: GraphAnchor) {
        guard from != to, nodes.contains(where: { $0.id == from }), nodes.contains(where: { $0.id == to }) else { return }
        guard !edges.contains(where: {
            ($0.from == from && $0.fromAnchor == anchor && $0.to == to && $0.toAnchor == target) ||
            ($0.from == to && $0.fromAnchor == target && $0.to == from && $0.toAnchor == anchor)
        }) else { return }
        edges.append(KnowledgeEdge(from: from, fromAnchor: anchor, to: to, toAnchor: target))
    }
}

/// Uses the existing app database, so the normal database backup includes graphs.
@MainActor final class KnowledgeGraphStore: ObservableObject {
    @Published var graph: KnowledgeGraph
    @Published var error: String?
    @Published private(set) var loaded = false
    @Published private(set) var undoStack: [KnowledgeGraph] = []
    @Published private(set) var redoStack: [KnowledgeGraph] = []
    private let db: AppDatabase
    private let writer = DispatchQueue(label: "knowledgegraph.persistence", qos: .utility)
    private var pending: DispatchWorkItem?
    private var loading: Task<Data?, Error>?
    private var migrating = false
    init(docId: String, db: AppDatabase) {
        self.db = db
        graph = KnowledgeGraph(id: docId, docId: docId)
    }
    func load() async {
        guard !loaded else { return }
        do {
            let database = db, id = graph.id
            if loading == nil { loading = Task.detached(priority: .utility) {
                try database.dbQueue.write { db -> Data? in
                    try db.execute(sql: "CREATE TABLE IF NOT EXISTS knowledge_graph(id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
                    return try Data.fetchOne(db, sql: "SELECT payload FROM knowledge_graph WHERE id=?", arguments: [id])
                }
            } }
            let data = try await loading!.value
            guard !loaded else { return }
            if let data { graph = try JSONDecoder().decode(KnowledgeGraph.self, from: data) }
            loaded = true
        } catch { loading = nil; self.error = error.localizedDescription }
    }
    func checkpoint() {
        guard loaded else { return }
        undoStack.append(graph); if undoStack.count > 80 { undoStack.removeFirst() }; redoStack = []
    }
    func undo() { guard let value = undoStack.popLast() else { return }; redoStack.append(graph); graph = value; save() }
    func redo() { guard let value = redoStack.popLast() else { return }; undoStack.append(graph); graph = value; save() }
    func save(immediate: Bool = false) {
        guard loaded else { return }
        graph.updatedAt = Date()
            let snapshot = graph, id = graph.id, database = db
            pending?.cancel()
            let work = DispatchWorkItem {
                do {
                    let data = try JSONEncoder().encode(snapshot)
                    try database.dbQueue.write { db in
                    try db.execute(sql: "INSERT OR REPLACE INTO knowledge_graph VALUES(?,?)", arguments: [id, data])
                } } catch { Task { @MainActor [weak self] in self?.error = error.localizedDescription } }
            }
            pending = work
            if immediate { writer.async(execute: work) } else { writer.asyncAfter(deadline: .now() + GraphConfig.saveDelay, execute: work) }
    }
    func add(kind: KnowledgeNode.Kind, at point: CGPoint) {
        guard loaded else { return }
        checkpoint()
        graph.nodes.append(KnowledgeNode(graphId: graph.id, kind: kind, frame: CGRect(origin: point, size: GraphConfig.nodeSize), zIndex: graph.nodes.count))
        save()
    }
    func flush() async {
        save(immediate:true)
        await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
            writer.async { continuation.resume() }
        }
    }
    func migrate(words: [VocabStore.WordSummary], vocab: VocabStore) async {
        guard loaded, graph.migrationVersion == 0, !migrating else { return }
        migrating = true; defer { migrating = false }
        let document = graph.docId
        do {
            // Backup before changing the graph; original vocab/history remain intact.
            let database = db
            let backup = try GraphAssets.directory().appendingPathComponent("legacy-before-migration.sqlite")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try await Task.detached { try database.snapshotTo(url: backup) }.value
            }
            let texts = await Task.detached(priority:.utility) {
                words.compactMap { word -> String? in
                    let occurrences = vocab.occurrences(forLemma:word.lemma).filter { $0.docSha == document }
                    guard word.sourceDocSha == document || !occurrences.isEmpty else { return nil }
                    let meaning: String
                    if case .found(let entry) = DictionaryService.lookup(word.lemma) { meaning = entry.translation ?? entry.definition ?? "" } else { meaning = "" }
                    return "旧生词\n\(word.surface)\n\(meaning)\n\(occurrences.first?.context ?? "")"
                }
            }.value
            for (index, text) in texts.enumerated() {
                graph.nodes.append(KnowledgeNode(graphId: graph.id, kind: .text,
                    frame: CGRect(x: (index % 4) * 340, y: (index / 4) * 240, width: 300, height: 200),
                    zIndex: index, text:text, isNew: false))
            }
            graph.migrationVersion = 1; save(immediate: true)
        } catch { self.error = error.localizedDescription }
    }
}

enum GraphAssets {
    static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("KnowledgeGraphAssets")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func url(_ name: String) throws -> URL {
        guard !name.contains("/"), !name.contains("\\"), !name.contains("..") else { throw CocoaError(.fileReadInvalidFileName) }
        return try directory().appendingPathComponent(name)
    }
}
