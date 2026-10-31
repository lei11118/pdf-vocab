import SwiftUI
import GRDB

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
        guard point.x.isFinite,point.y.isFinite else { return }
        try? db.dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO vocab_graph_position(wordId,mode,x,y) VALUES(?,?,?,?)", arguments: [word,mode,Double(point.x),Double(point.y)])
        }
    }
}

struct VocabGraphView: View {
    let store: VocabStore
    let words: [VocabStore.WordSummary]
    var onJump: ((VocabJumpTarget) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var mode: VocabGraphMode = .mixed
    @State private var search = ""
    @State private var data = VocabGraphData()
    @State private var shown: [VocabStore.WordSummary] = []
    @State private var positions: [Int64: CGPoint] = [:]
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var panStart = CGSize.zero
    @State private var zoomStart: CGFloat = 1
    @State private var nodeStarts: [Int64: CGPoint] = [:]
    @State private var detail: VocabStore.WordSummary?
    @State private var evidence: String?
    @State private var sources = false
    @State private var loading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Space.s) {
                Picker("连线方式", selection: $mode) { ForEach(VocabGraphMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                TextField("搜索生词", text: $search).textFieldStyle(.roundedBorder)
                HStack {
                    Text("\(shown.count) / \(words.count) 词 · \(data.edges.count) 条关联").font(DS.Fonts.caption2).foregroundStyle(DS.foreground3)
                    Spacer()
                    Button("复位视图") { pan = .zero; panStart = .zero; zoom = 1; zoomStart = 1 }
                }
                if loading { ProgressView() }
                GeometryReader { geometry in
                    let center=CGPoint(x:geometry.size.width/2,y:geometry.size.height/2)
                    ZStack {
                        DS.background1
                            .gesture(DragGesture().onChanged { value in pan=CGSize(width:panStart.width+value.translation.width,height:panStart.height+value.translation.height) }.onEnded { _ in panStart=pan })
                            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                                if let edge=data.edges.first(where: { edge in
                                    guard let a=positions[edge.a],let b=positions[edge.b] else { return false }
                                    return InkEraser.distance(value.location,to:screen(a,center:center),screen(b,center:center))<10
                                }) { evidence=edge.evidence }
                            })
                        Canvas { context,size in
                            for edge in data.edges {
                                guard let a=positions[edge.a],let b=positions[edge.b] else { continue }
                                var path=Path();path.move(to:screen(a,center:center));path.addLine(to:screen(b,center:center))
                                context.stroke(path,with:.color((edge.morphology ? DS.accent : DS.foreground3).opacity(0.45)),lineWidth:edge.morphology ? 1.5:1)
                            }
                        }.allowsHitTesting(false)
                        ForEach(shown) { word in
                            if let point=positions[word.id] {
                                Button { detail=word } label: {
                                    Text(word.surface).font(DS.Fonts.caption2).foregroundStyle(DS.foreground1).padding(DS.Space.xs)
                                        .background(DS.background2,in:Capsule()).overlay(Capsule().stroke(DS.accent.opacity(0.6),lineWidth:1))
                                }
                                .buttonStyle(.plain).position(screen(point,center:center))
                                .simultaneousGesture(DragGesture(minimumDistance:5).onChanged { value in
                                    if nodeStarts[word.id]==nil { nodeStarts[word.id]=positions[word.id] }
                                    let start=nodeStarts[word.id]!
                                    positions[word.id]=CGPoint(x:start.x+value.translation.width/zoom,y:start.y+value.translation.height/zoom)
                                }.onEnded { _ in
                                    nodeStarts[word.id]=nil
                                    if let p=positions[word.id] { store.saveGraphPosition(p,word:word.id,mode:mode.rawValue) }
                                })
                            }
                        }
                        if !loading && data.edges.isEmpty {
                            VStack { Spacer();Text(data.available ? "当前范围暂无有来源依据的关联，可切换模式或搜索其他词。" : "关系数据不可用，现有生词不受影响。").font(DS.Fonts.caption2).foregroundStyle(DS.foreground3).padding() }.allowsHitTesting(false)
                        }
                    }
                    .clipped()
                    .simultaneousGesture(MagnificationGesture().onChanged { zoom=max(0.2,min(4,zoomStart*$0)) }.onEnded { _ in zoomStart=zoom })
                }
                Text("蓝线：词根词缀词例 · 灰线：共享英文义项；点击连线查看依据。最多展示 250 词，可搜索定位。")
                    .font(DS.Fonts.caption2).foregroundStyle(DS.foreground3)
            }
            .padding(DS.Space.m).background(DS.background1)
            .navigationTitle("知识图谱").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) { Button("返回词表") { dismiss() } }
                ToolbarItem(placement:.topBarTrailing) { Button("数据来源") { sources=true } }
            }
            .task(id:mode.rawValue+":"+search) { await load() }
            .sheet(item:$detail) { VocabularyDetailView(store:store,word:$0,onJump:onJump) }
            .alert("关联依据",isPresented:Binding(get:{evidence != nil},set:{if !$0 { evidence=nil }})) { Button("关闭") { evidence=nil } } message: { Text(evidence ?? "") }
            .sheet(isPresented:$sources) {
                NavigationStack {
                    ScrollView { Text("词根词缀：Colin Goldberg / morphemes，MIT，仅使用来源明确列出的词例。\n\n同近义：Open English WordNet 2025，CC BY 4.0，及 Princeton WordNet 许可。连线表示共享某个英文义项，不代表所有含义相同。\n\n中文译文或中文近义词仅能作为候选辅助，不能独立证明英文同义；当前正式连线不使用未经核准许可的中文词典。\n\n资源许可与校验信息随 App 的 LexicalSources 资源打包。").padding().foregroundStyle(DS.foreground2) }
                        .background(DS.background1).navigationTitle("关系来源").toolbar { Button("关闭") { sources=false } }
                }
            }
        }
    }
    private func screen(_ point: CGPoint, center: CGPoint) -> CGPoint { CGPoint(x:center.x+pan.width+point.x*zoom,y:center.y+pan.height+point.y*zoom) }
    @MainActor private func load() async {
        loading=true
        let key=search.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        let selected=Array(words.filter { key.isEmpty || $0.surface.lowercased().contains(key) || $0.lemma.contains(key) }.prefix(VocabRelationService.nodeLimit))
        let selectedMode=mode, pairs=selected.map { ($0.id,$0.lemma) }
        let computed=await Task.detached(priority:.utility) {
            let result=VocabRelationService.build(words:pairs,mode:selectedMode)
            return (result,VocabRelationService.layout(ids:pairs.map(\.0),edges:result.edges))
        }.value
        guard !Task.isCancelled else { return }
        let result=computed.0
        var layout=computed.1
        let stored=store.graphPositions(mode:selectedMode.rawValue)
        for id in layout.keys { if let p=stored[id] { layout[id]=p } }
        shown=selected;positions=layout;data=result;loading=false
    }
}
