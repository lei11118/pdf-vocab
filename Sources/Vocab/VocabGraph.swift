import SwiftUI
import UIKit
import GRDB
import Combine

enum VocabGraphMode: String, CaseIterable, Identifiable, Sendable {
    case morphology, synonym, mixed
    var id: String { rawValue }
    var title: String {
        switch self { case .morphology: return "词根词缀"; case .synonym: return "同近义"; case .mixed: return "混合" }
    }
}

struct VocabGraphEdge: Identifiable, Sendable {
    var id: String
    var a: Int64
    var b: Int64
    var morphology: Bool
    var evidence: String
}

struct VocabGraphData: Sendable {
    var edges: [VocabGraphEdge] = []
    var indexedWords = 0
    var available = false
}

/// Relations are supported by explicit source examples or shared English sense
/// IDs. Lemmatization, common substrings and translated gloss overlap are not
/// accepted as proof of an etymological/synonym relationship.
enum VocabRelationService {
    static let nodeLimit = 250
    static let edgeLimit = 1500

    static func build(words: [(Int64, String)], mode: VocabGraphMode, url: URL? = nil) -> VocabGraphData {
        guard let source = url ?? Bundle.main.url(forResource: "lexical", withExtension: "sqlite") else { return VocabGraphData() }
        var config = Configuration(); config.readonly = true
        guard let queue = try? DatabaseQueue(path: source.path, configuration: config) else { return VocabGraphData() }
        return (try? queue.read { db in
            var groups: [String: [(Int64, String, Bool)]] = [:]
            var covered = Set<Int64>()
            for (id, lemma) in words.prefix(nodeLimit) {
                if mode != .synonym {
                    for row in try Row.fetchAll(db, sql: "SELECT morpheme,kind,meaning FROM morphology WHERE lemma=?", arguments: [lemma.lowercased()]) {
                        let root: String = row["morpheme"], kind: String = row["kind"], meaning: String = row["meaning"]
                        groups["m:\(kind):\(root)", default: []].append((id, "词素词例：\(root)（\(kind)）\n\(meaning)\n来源：Colin Goldberg / morphemes，MIT", true))
                        covered.insert(id)
                    }
                }
                if mode != .morphology {
                    for row in try Row.fetchAll(db, sql: "SELECT m.synset,m.pos,s.definition FROM membership m JOIN synset s ON s.id=m.synset WHERE m.lemma=?", arguments: [lemma.lowercased()]) {
                        let sense: String = row["synset"], pos: String = row["pos"], definition: String = row["definition"]
                        groups["s:\(sense)", default: []].append((id, "共享英文义项（\(pos)）：\n\(definition)\n\(sense)\n来源：Open English WordNet 2025 / Princeton WordNet", false))
                        covered.insert(id)
                    }
                }
            }
            var result = VocabGraphData(edges: [], indexedWords: covered.count, available: true)
            for key in groups.keys.sorted() {
                let entries = groups[key]!.sorted { $0.0 < $1.0 }
                guard entries.count > 1 else { continue }
                for i in 0..<(entries.count-1) {
                    for j in (i+1)..<entries.count where entries[i].0 != entries[j].0 {
                        guard result.edges.count < edgeLimit else { return result }
                        result.edges.append(VocabGraphEdge(id: "\(key):\(entries[i].0):\(entries[j].0)", a: entries[i].0, b: entries[j].0, morphology: entries[i].2, evidence: entries[i].1))
                    }
                }
            }
            return result
        }) ?? VocabGraphData()
    }

    static func layout(ids: [Int64], edges: [VocabGraphEdge]) -> [Int64: CGPoint] {
        var positions: [Int64: CGPoint] = [:]
        for (i,id) in ids.enumerated() {
            let angle = Double(i) / Double(max(1,ids.count)) * 2 * Double.pi
            let radius = max(110, sqrt(Double(ids.count))*32)
            positions[id] = CGPoint(x:cos(angle)*radius,y:sin(angle)*radius)
        }
        // Bounded deterministic layout; never run a perpetual display-link loop.
        for _ in 0..<24 {
            var forces = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGPoint.zero) })
            for i in ids.indices {
                for j in ids.indices where j > i {
                    let a=positions[ids[i]]!,b=positions[ids[j]]!
                    let dx=a.x-b.x,dy=a.y-b.y,d=max(12,hypot(dx,dy))
                    let strength=min(5,1400/(d*d))
                    forces[ids[i]]!.x += dx/d*strength;forces[ids[i]]!.y += dy/d*strength
                    forces[ids[j]]!.x -= dx/d*strength;forces[ids[j]]!.y -= dy/d*strength
                }
            }
            for edge in edges {
                guard let a=positions[edge.a],let b=positions[edge.b] else { continue }
                let dx=b.x-a.x,dy=b.y-a.y,d=max(1,hypot(dx,dy)),force=(d-110)*0.025
                forces[edge.a]!.x += dx/d*force;forces[edge.a]!.y += dy/d*force
                forces[edge.b]!.x -= dx/d*force;forces[edge.b]!.y -= dy/d*force
            }
            for id in ids { positions[id]!.x += max(-8,min(8,forces[id]!.x));positions[id]!.y += max(-8,min(8,forces[id]!.y)) }
        }
        return positions
    }
}

extension VocabStore {
    func graphPositions(mode: String) -> [Int64: CGPoint] {
        (try? db.dbQueue.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT wordId,x,y FROM vocab_graph_position WHERE mode=?", arguments: [mode]).map { row in
                let id: Int64=row["wordId"], x: Double=row["x"], y: Double=row["y"]
                return (id,CGPoint(x:x,y:y))
            })
        }) ?? [:]
    }
    func saveGraphPosition(_ point: CGPoint, word: Int64, mode: String) {
        saveGraphPositions([word:point],mode:mode)
    }
    func saveGraphPositions(_ positions:[Int64:CGPoint],mode:String) {
        try? db.dbQueue.write { db in
            for (word,point) in positions where point.x.isFinite && point.y.isFinite {
                try db.execute(sql: "INSERT OR REPLACE INTO vocab_graph_position(wordId,mode,x,y) VALUES(?,?,?,?)", arguments: [word,mode,Double(point.x),Double(point.y)])
            }
        }
    }
}
