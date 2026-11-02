import SwiftUI
import PencilKit

struct KnowledgeGraphView: View {
    @StateObject private var model: KnowledgeGraphStore
    @ObservedObject var tools: PencilToolSession
    let vocab: VocabStore
    var onSource: ((GraphScreenshot) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var selected: String?
    @State private var editing: String?
    @State private var panOrigin: CGPoint?
    @State private var zoomOrigin: CGFloat?
    @State private var moveOrigin: CGRect?
    @State private var connection: (String, GraphAnchor, CGPoint)?
    @State private var viewport: CGSize = .zero
    @State private var moveMode = false

    init(docId: String, db: AppDatabase, tools: PencilToolSession, onSource: ((GraphScreenshot) -> Void)? = nil) {
        _model = StateObject(wrappedValue: KnowledgeGraphStore(docId: docId, db: db))
        self.tools = tools; vocab = VocabStore(db: db); self.onSource = onSource
    }
    init(model: KnowledgeGraphStore, tools: PencilToolSession, vocab: VocabStore, onSource: ((GraphScreenshot) -> Void)? = nil) {
        _model = StateObject(wrappedValue: model); self.tools = tools; self.vocab = vocab; self.onSource = onSource
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    DS.background1.ignoresSafeArea()
                        .contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            if panOrigin == nil { panOrigin = model.graph.offset; editing = nil; selected = nil }
                            model.graph.offset = CGPoint(x: panOrigin!.x + value.translation.width, y: panOrigin!.y + value.translation.height)
                        }.onEnded { _ in panOrigin = nil; model.save() })
                        .onTapGesture { editing = nil; selected = nil }
                        .onLongPressGesture { add(.text) }
                    edges
                    ForEach(model.graph.nodes.sorted { $0.zIndex < $1.zIndex }) { node in
                        if screenRect(node.frame).intersects(CGRect(origin: .zero, size: geo.size).insetBy(dx: -100, dy: -100)) {
                            nodeView(node)
                                .frame(width: node.frame.width, height: node.frame.height)
                                .scaleEffect(model.graph.zoom, anchor: .topLeading)
                                .position(x: screenRect(node.frame).minX + node.frame.width / 2, y: screenRect(node.frame).minY + node.frame.height / 2)
                        }
                    }
                }
                .clipped()
                .coordinateSpace(name: "graph")
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    if zoomOrigin == nil { zoomOrigin = model.graph.zoom; editing = nil }
                    let old = model.graph.zoom
                    let new = min(GraphConfig.maxZoom, max(GraphConfig.minZoom, zoomOrigin! * value.magnification))
                    let pivot = CGPoint(x: geo.size.width * value.startAnchor.x, y: geo.size.height * value.startAnchor.y)
                    model.graph.offset = CGPoint(x: pivot.x - (pivot.x-model.graph.offset.x)*new/old, y: pivot.y - (pivot.y-model.graph.offset.y)*new/old)
                    model.graph.zoom = new
                }.onEnded { _ in zoomOrigin = nil; model.save() })
                .onAppear { viewport = geo.size }
                .onChange(of: geo.size) { _, size in viewport = size }
            }
            .navigationTitle("知识图谱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { model.save(immediate: true); dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { moveMode.toggle(); editing = nil } label: { Label(moveMode ? "阅读节点" : "选择/移动", systemImage: moveMode ? "text.cursor" : "hand.draw") }
                    Button { add(.text) } label: { Label("文本框", systemImage: "text.badge.plus") }
                    Button { add(.ink) } label: { Label("标记框", systemImage: "pencil.tip.crop.circle.badge.plus") }
                    Button { model.undo() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }.disabled(model.undoStack.isEmpty)
                    Button { model.redo() } label: { Label("重做", systemImage: "arrow.uturn.forward") }.disabled(model.redoStack.isEmpty)
                    Button { fit() } label: { Label("适应画面", systemImage: "arrow.up.left.and.arrow.down.right") }
                    Button(role: .destructive) {
                        if let selected { model.checkpoint(); model.graph.delete(selected); self.selected = nil; model.save() }
                    } label: { Label("删除", systemImage: "trash") }.disabled(selected == nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let node = model.graph.nodes.first(where: { $0.id == selected }), node.kind == .ink {
                    ScrollView(.horizontal) {
                        PencilPaletteView(session: tools, onUndo: { model.undo() }, onRedo: { model.redo() }, onExitWriting: { selected = nil })
                    }.frame(height: 90)
                }
            }
            .task {
                await model.load()
                await model.migrate(words: vocab.listWords(), vocab: vocab)
                for index in model.graph.nodes.indices { model.graph.nodes[index].isNew = false }
                model.save()
            }
            .onChange(of: phase) { _, phase in if phase != .active { model.save(immediate: true) } }
            .onDisappear { model.save(immediate: true) }
            .alert("图谱保存提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("好") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
    private func screenRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * model.graph.zoom + model.graph.offset.x, y: rect.minY * model.graph.zoom + model.graph.offset.y,
               width: rect.width * model.graph.zoom, height: rect.height * model.graph.zoom)
    }
    private func canvas(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x-model.graph.offset.x)/model.graph.zoom, y: (point.y-model.graph.offset.y)/model.graph.zoom)
    }
    private func add(_ kind: KnowledgeNode.Kind) {
        let point = canvas(CGPoint(x: viewport.width/2-150, y: viewport.height/2-100))
        model.add(kind: kind, at: point); selected = model.graph.nodes.last?.id
        if kind == .text { editing = selected }
    }
    private func fit() {
        let rect = model.graph.nodes.reduce(CGRect.null) { $0.union($1.frame) }
        guard !rect.isNull else { return }
        model.graph.zoom = min(2, max(GraphConfig.minZoom, min((viewport.width-80)/rect.width, (viewport.height-80)/rect.height)))
        model.graph.offset = CGPoint(x: (viewport.width-rect.width*model.graph.zoom)/2-rect.minX*model.graph.zoom,
                                     y: (viewport.height-rect.height*model.graph.zoom)/2-rect.minY*model.graph.zoom)
        model.save()
    }
    private func binding(_ id: String) -> Binding<KnowledgeNode> {
        Binding(get: { model.graph.nodes.first(where: { $0.id == id })! }, set: { value in
            if let index = model.graph.nodes.firstIndex(where: { $0.id == id }) { model.graph.nodes[index] = value; model.save() }
        })
    }
    private func nodeView(_ node: KnowledgeNode) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: node.kind == .ink ? "pencil.tip" : node.kind == .text ? "text.alignleft" : "photo")
                Text(node.isNew ? "新" : node.kind == .text ? "文本" : node.kind == .ink ? "标记" : "截图").font(.caption)
                Spacer()
                if let shot = node.screenshot { Button("来源") { model.save(immediate: true); dismiss(); onSource?(shot) }.font(.caption) }
                if editing == node.id { Button("完成") { editing = nil }.font(.caption) }
            }
            .padding(7).background(Color.secondary.opacity(0.08)).contentShape(Rectangle())
            .gesture(DragGesture().onChanged { value in
                selected = node.id; editing = nil
                if moveOrigin == nil { model.checkpoint(); moveOrigin = node.frame }
                var valueNode = node
                valueNode.frame.origin = CGPoint(x: moveOrigin!.minX+value.translation.width/model.graph.zoom, y: moveOrigin!.minY+value.translation.height/model.graph.zoom)
                binding(node.id).wrappedValue = valueNode
            }.onEnded { _ in moveOrigin = nil; model.save() })
            content(node)
        }
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected == node.id ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected == node.id ? 2 : 1))
        .overlay { if selected == node.id { handles(node) } }
        .onTapGesture { selected = node.id }
        .onHover { inside in if inside { selected = node.id } }
        .overlay {
            if moveMode {
                Color.clear.contentShape(Rectangle()).gesture(DragGesture().onChanged { value in
                    selected = node.id
                    if moveOrigin == nil { model.checkpoint(); moveOrigin = node.frame }
                    var n = node; n.frame.origin = CGPoint(x:moveOrigin!.minX+value.translation.width/model.graph.zoom,y:moveOrigin!.minY+value.translation.height/model.graph.zoom)
                    binding(node.id).wrappedValue = n
                }.onEnded { _ in moveOrigin = nil; model.save() })
            }
        }
        .contextMenu {
            Button("置于顶层") { model.checkpoint(); var n = node; n.zIndex = (model.graph.nodes.map(\.zIndex).max() ?? 0)+1; binding(node.id).wrappedValue = n }
            Button("置于底层") { model.checkpoint(); var n = node; n.zIndex = (model.graph.nodes.map(\.zIndex).min() ?? 0)-1; binding(node.id).wrappedValue = n }
            Button("删除", role: .destructive) { model.checkpoint(); model.graph.delete(node.id); model.save() }
        }
    }
    @ViewBuilder private func content(_ node: KnowledgeNode) -> some View {
        if node.kind == .text {
            if editing == node.id {
                TextEditor(text: Binding(get: { binding(node.id).wrappedValue.text }, set: { text in
                    var n = binding(node.id).wrappedValue; n.text = text; binding(node.id).wrappedValue = n
                })).padding(5).onAppear { model.checkpoint() }
            } else {
                WordInteractionLayer(text: node.text, onEdit: { model.checkpoint(); editing = node.id })
            }
        } else if node.kind == .ink {
            GraphInkView(data: Binding(get: { binding(node.id).wrappedValue.drawingData }, set: { data in
                var n = binding(node.id).wrappedValue; n.drawingData = data; binding(node.id).wrappedValue = n
            }), tools: tools, live: selected == node.id && model.graph.zoom >= GraphConfig.snapshotZoom,
               onBegin: { model.checkpoint() })
        } else if let shot = node.screenshot, let url = try? GraphAssets.url(model.graph.zoom < GraphConfig.snapshotZoom ? shot.thumbPath : shot.imagePath), let image = UIImage(contentsOfFile: url.path) {
            WordInteractionLayer(image: image, words: shot.words, enabled: shot.ocrStatus == "done")
                .overlay(alignment: .bottom) {
                    if shot.ocrStatus != "done" { Text(shot.ocrStatus == "pending" ? "文字识别中…" : "未能识别文字，可查看图片").font(.caption).padding(4).background(.regularMaterial) }
                }
        } else { Color.secondary.opacity(0.1).overlay(Text("图片不可用")) }
    }
    private func handles(_ node: KnowledgeNode) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(GraphAnchor.allCases, id: \.self) { anchor in
                let p = anchor.point(in: CGRect(origin: .zero, size: node.frame.size))
                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    .frame(width: GraphConfig.anchorSize, height: GraphConfig.anchorSize).contentShape(Rectangle())
                    .position(p)
                    .gesture(DragGesture(coordinateSpace: .named("graph")).onChanged { value in
                        connection = (node.id, anchor, canvas(value.location))
                    }.onEnded { value in
                        let end = canvas(value.location)
                        if let target = model.graph.nodes.sorted(by: { $0.zIndex > $1.zIndex }).first(where: { $0.id != node.id && $0.frame.contains(end) }) {
                            model.checkpoint(); model.graph.connect(from: node.id, anchor: anchor, to: target.id, target: .nearest(to: end, frame: target.frame)); model.save()
                        }
                        connection = nil
                    })
            }
            ForEach(0..<4, id: \.self) { corner in
                let x: CGFloat = corner % 2 == 0 ? 0 : node.frame.width
                let y: CGFloat = corner < 2 ? 0 : node.frame.height
                Rectangle().fill(Color.accentColor).frame(width: 8, height: 8)
                    .frame(width: GraphConfig.resizeSize, height: GraphConfig.resizeSize).contentShape(Rectangle()).position(x: x,y: y)
                    .gesture(DragGesture().onChanged { value in
                        if moveOrigin == nil { model.checkpoint(); moveOrigin = node.frame }
                        let original = moveOrigin!, dx = value.translation.width/model.graph.zoom, dy = value.translation.height/model.graph.zoom
                        var rect = original
                        rect.size.width = max(GraphConfig.minSize, original.width + (corner % 2 == 0 ? -dx : dx))
                        rect.size.height = max(GraphConfig.minSize, original.height + (corner < 2 ? -dy : dy))
                        if node.kind == .screenshot { rect.size.height = (rect.width * (original.height-32)/original.width)+32 }
                        if corner % 2 == 0 { rect.origin.x = original.maxX-rect.width }
                        if corner < 2 { rect.origin.y = original.maxY-rect.height }
                        var n = node; n.frame = rect; binding(node.id).wrappedValue = n
                    }.onEnded { _ in moveOrigin = nil; model.save() })
            }
        }
    }
    private func edgePath(_ a: CGPoint, _ b: CGPoint) -> Path {
        let a = CGPoint(x: a.x*model.graph.zoom+model.graph.offset.x,y: a.y*model.graph.zoom+model.graph.offset.y)
        let b = CGPoint(x: b.x*model.graph.zoom+model.graph.offset.x,y: b.y*model.graph.zoom+model.graph.offset.y)
        var path = Path(); path.move(to: a)
        path.addCurve(to: b, control1: CGPoint(x: a.x+(b.x-a.x)*0.4,y:a.y), control2: CGPoint(x: b.x-(b.x-a.x)*0.4,y:b.y))
        return path
    }
    private var edges: some View {
        ZStack {
            ForEach(model.graph.edges) { edge in
                if let a = model.graph.nodes.first(where: { $0.id == edge.from }), let b = model.graph.nodes.first(where: { $0.id == edge.to }) {
                    let path = edgePath(edge.fromAnchor.point(in:a.frame),edge.toAnchor.point(in:b.frame))
                    path.stroke(selected == edge.id ? Color.accentColor : Color.secondary, lineWidth: GraphConfig.edgeWidth)
                    path.stroke(Color.black.opacity(0.001), lineWidth: GraphConfig.edgeHitWidth).onTapGesture { selected = edge.id }
                }
            }
            if let connection, let node = model.graph.nodes.first(where: { $0.id == connection.0 }) {
                edgePath(connection.1.point(in: node.frame), connection.2).stroke(Color.accentColor,lineWidth:GraphConfig.edgeWidth)
            }
        }
    }
}

private struct GraphInkView: UIViewRepresentable {
    @Binding var data: Data
    @ObservedObject var tools: PencilToolSession
    var live: Bool
    var onBegin: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView(); canvas.drawingPolicy = .pencilOnly; canvas.delegate = context.coordinator
        canvas.backgroundColor = .clear; canvas.isScrollEnabled = false
        return canvas
    }
    func updateUIView(_ view: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        view.tool = tools.makeTool(); view.isUserInteractionEnabled = live
        if context.coordinator.last != data {
            context.coordinator.last = data
            view.drawing = (try? PKDrawing(data: data)) ?? PKDrawing()
        }
    }
    class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: GraphInkView
        var last = Data()
        init(_ parent: GraphInkView) { self.parent = parent }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { parent.onBegin() }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let value = canvasView.drawing.dataRepresentation()
            guard value != last else { return }; last = value; parent.data = value
        }
    }
}
