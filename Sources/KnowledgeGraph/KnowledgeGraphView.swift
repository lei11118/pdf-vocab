import SwiftUI
import PencilKit

struct KnowledgeGraphView: View {
    @StateObject private var model: KnowledgeGraphStore
    @ObservedObject var tools: PencilToolSession
    let vocab: VocabStore
    var onSource: ((GraphScreenshot) -> Void)?
    var libraryDocuments: [DocumentRecord]?
    var onOpenDocument: ((String) -> Void)?
    @Environment(\.readerPanelClose) private var panelClose
    @Environment(\.dismiss) private var dismiss
    private func closePanel() { if let panelClose { panelClose() } else { dismiss() } }
    @Environment(\.scenePhase) private var phase
    @State private var selected: String?
    @State private var editing: String?
    @State private var panOrigin: CGPoint?
    @State private var zoomOrigin: CGFloat?
    @State private var zoomOffsetOrigin: CGPoint?
    @State private var movingNode: String?
    @State private var transientFrame: CGRect?
    @State private var moveOrigin: CGRect?
    @State private var connection: (String, GraphAnchor, CGPoint)?
    @State private var viewport: CGSize = .zero
    @State private var moveMode = false
    @GestureState private var nodeGestureActive = false
    @GestureState private var panActive = false
    @GestureState private var zoomActive = false
    private var connectionTarget: String? {
        guard let connection else { return nil }
        return model.graph.nodes.sorted { $0.zIndex > $1.zIndex }.first { $0.id != connection.0 && $0.frame.contains(connection.2) }?.id
    }

    init(docId: String, db: AppDatabase, tools: PencilToolSession, onSource: ((GraphScreenshot) -> Void)? = nil,
         libraryDocuments: [DocumentRecord]? = nil, onOpenDocument: ((String) -> Void)? = nil) {
        _model = StateObject(wrappedValue: KnowledgeGraphStore.session(docId: docId, db: db))
        self.tools = tools; vocab = VocabStore(db: db); self.onSource = onSource
        self.libraryDocuments = libraryDocuments; self.onOpenDocument = onOpenDocument
    }
    init(model: KnowledgeGraphStore, tools: PencilToolSession, vocab: VocabStore, onSource: ((GraphScreenshot) -> Void)? = nil) {
        _model = StateObject(wrappedValue: model); self.tools = tools; self.vocab = vocab; self.onSource = onSource
        libraryDocuments = nil; onOpenDocument = nil
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    DS.background1
                        .overlay { GraphGridBackground(offset:model.graph.offset,zoom:model.graph.zoom).allowsHitTesting(false) }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance:2,coordinateSpace:.global).updating($panActive) { _,active,_ in active = true }.onChanged { value in
                            guard zoomOrigin == nil else { return }
                            if panOrigin == nil { panOrigin = model.graph.offset; editing = nil; selected = nil }
                            model.graph.offset = CGPoint(x: panOrigin!.x + value.translation.width, y: panOrigin!.y + value.translation.height)
                        }.onEnded { _ in panOrigin = nil; model.save() })
                        .onTapGesture { editing = nil; selected = nil }
                        .onLongPressGesture { add(.text) }
                    edges
                    ForEach(model.graph.nodes.sorted { $0.zIndex < $1.zIndex }) { savedNode in
                        let node = displayed(savedNode)
                        if movingNode == node.id || screenRect(node.frame).intersects(CGRect(origin: .zero, size: geo.size).insetBy(dx: -100, dy: -100)) {
                            nodeView(node)
                                .frame(width: node.frame.width, height: node.frame.height)
                                .scaleEffect(model.graph.zoom, anchor: .topLeading)
                                .frame(width: node.frame.width * model.graph.zoom, height: node.frame.height * model.graph.zoom, alignment: .topLeading)
                                .position(x: screenRect(node.frame).midX, y: screenRect(node.frame).midY)
                        }
                    }
                }
                .transaction { if movingNode != nil || panOrigin != nil || zoomOrigin != nil { $0.animation = nil } }
                .clipped()
                .coordinateSpace(name: "graph")
                .simultaneousGesture(MagnifyGesture().updating($zoomActive) { _,active,_ in active = true }.onChanged { value in
                    guard movingNode == nil else { return }
                    if zoomOrigin == nil { zoomOrigin = model.graph.zoom; zoomOffsetOrigin = model.graph.offset; panOrigin = nil; editing = nil }
                    let old = zoomOrigin!
                    let offset = zoomOffsetOrigin!
                    let new = min(GraphConfig.maxZoom, max(GraphConfig.minZoom, zoomOrigin! * value.magnification))
                    let pivot = CGPoint(x: geo.size.width * value.startAnchor.x, y: geo.size.height * value.startAnchor.y)
                    model.graph.offset = CGPoint(x: pivot.x - (pivot.x-offset.x)*new/old, y: pivot.y - (pivot.y-offset.y)*new/old)
                    model.graph.zoom = new
                }.onEnded { _ in zoomOrigin = nil; zoomOffsetOrigin = nil; model.save() })
                .onAppear { viewport = geo.size }
                .onChange(of: geo.size) { _, size in viewport = size }
            }
            .navigationTitle(libraryDocuments == nil ? "知识图谱" : "主知识图谱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DS.background1,for:.navigationBar)
            .toolbarBackground(.visible,for:.navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { if panelClose == nil { Button("完成") { model.save(immediate: true); closePanel() } } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                    Button { moveMode.toggle(); editing = nil } label: { Label(moveMode ? "阅读节点" : "选择/移动", systemImage: moveMode ? "text.cursor" : "hand.draw") }
                    Divider()
                    Button { add(.text) } label: { Label("文本框", systemImage: "text.badge.plus") }
                    Button { add(.ink) } label: { Label("标记框", systemImage: "pencil.tip.crop.circle.badge.plus") }
                    Button("编辑选中文本") { editSelectedText() }.disabled(!canEditSelectedText)
                    Divider()
                    Button { model.undo() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }.disabled(model.undoStack.isEmpty)
                    Button { model.redo() } label: { Label("重做", systemImage: "arrow.uturn.forward") }.disabled(model.redoStack.isEmpty)
                    Button { withAnimation(.smooth(duration:0.24)) { fit() } } label: { Label("适应画面", systemImage: "arrow.up.left.and.arrow.down.right") }
                    Button(role: .destructive) {
                        if let selected { model.checkpoint(); model.graph.delete(selected); self.selected = nil; model.save() }
                    } label: { Label("删除", systemImage: "trash") }.disabled(!canDeleteSelection)
                    } label: { Label("图谱操作", systemImage: "ellipsis.circle") }
                    .accessibilityLabel("图谱操作")
                }
            }
            .toolbar(panelClose == nil ? .visible : .hidden, for:.navigationBar)
            .safeAreaInset(edge:.top,spacing:0) {
                if panelClose != nil {
                    ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:8) {
                        Button { add(.text) } label: { Label("文本框",systemImage:"text.badge.plus").lineLimit(1).fixedSize() }.disabled(!model.loaded)
                        Button { add(.ink) } label: { Label("标记框",systemImage:"pencil.tip.crop.circle.badge.plus").lineLimit(1).fixedSize() }.disabled(!model.loaded)
                        Menu {
                            Button { moveMode.toggle(); editing = nil } label: { Label(moveMode ? "阅读节点" : "选择/移动",systemImage:"hand.draw") }
                            Button("编辑选中文本") { editSelectedText() }.disabled(!canEditSelectedText)
                            Button("撤销") { model.undo() }.disabled(model.undoStack.isEmpty)
                            Button("重做") { model.redo() }.disabled(model.redoStack.isEmpty)
                            Button("适应画面") { withAnimation(.smooth(duration:0.24)) { fit() } }
                            Button("删除",role:.destructive) { deleteSelection() }.disabled(!canDeleteSelection)
                        } label: { Image(systemName:"ellipsis.circle").frame(width:32,height:36) }
                        .accessibilityLabel("图谱操作")
                    }
                    .fixedSize(horizontal:true,vertical:false)
                    .font(.caption.weight(.medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    }
                    .padding(.leading,16).padding(.trailing,48).padding(.vertical,8)
                    .background(DS.background1)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let node = model.graph.nodes.first(where: { $0.id == selected }), node.kind == .ink {
                    ScrollView(.horizontal) {
                        PencilPaletteView(session: tools, onUndo: { model.undo() }, onRedo: { model.redo() }, onExitWriting: { selected = nil })
                    }
                }
            }
            .task {
                await model.load()
                if let libraryDocuments { syncDocuments(libraryDocuments) }
                else { await model.migrate(words: vocab.listWords(), vocab: vocab) }
                for index in model.graph.nodes.indices { model.graph.nodes[index].isNew = false }
                model.save()
                await resumePendingTextRecognition()
            }
            .onChange(of:libraryDocuments) { _, docs in if let docs { syncDocuments(docs) } }
            .onChange(of: phase) { _, phase in if phase != .active { model.save(immediate: true) } }
            .onChange(of:panActive) { _,active in if !active { panOrigin = nil; model.save() } }
            .onChange(of:zoomActive) { _,active in if !active { zoomOrigin = nil; zoomOffsetOrigin = nil; model.save() } }
            .onChange(of:nodeGestureActive) { _,active in if !active && movingNode != nil { finishManipulation() } }
            .onDisappear { finishManipulation(); model.save(immediate: true) }
            .alert("图谱保存提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("好") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
    private var canDeleteSelection: Bool {
        guard let selected else { return false }
        return !model.graph.nodes.contains { $0.id == selected && $0.kind == .document }
    }
    private var canEditSelectedText: Bool {
        model.graph.nodes.contains { $0.id == selected && $0.kind == .text }
    }
    private func editSelectedText() {
        guard canEditSelectedText, let selected else { return }
        model.checkpoint(); editing = selected
    }
    private func deleteSelection() {
        guard canDeleteSelection, let selected else { return }
        model.checkpoint(); model.graph.delete(selected); self.selected = nil; model.save()
    }
    private func syncDocuments(_ documents:[DocumentRecord]) {
        guard model.loaded else { return }
        if model.graph.syncDocuments(documents) { model.save() }
    }
    private func displayed(_ node: KnowledgeNode) -> KnowledgeNode {
        var result = node
        if movingNode == node.id, let transientFrame { result.frame = transientFrame }
        return result
    }
    private func finishManipulation() {
        if let id = movingNode, let frame = transientFrame,
           let index = model.graph.nodes.firstIndex(where: { $0.id == id }) {
            model.graph.nodes[index].frame = frame
        }
        movingNode = nil; transientFrame = nil; moveOrigin = nil
        model.save()
    }
    private func screenRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * model.graph.zoom + model.graph.offset.x, y: rect.minY * model.graph.zoom + model.graph.offset.y,
               width: rect.width * model.graph.zoom, height: rect.height * model.graph.zoom)
    }
    private func resumePendingTextRecognition() async {
        let pending = model.graph.nodes.compactMap { node -> (String,String)? in
            guard let shot = node.screenshot,shot.ocrStatus == "pending" else { return nil }
            return (node.id,shot.imagePath)
        }
        for (id,path) in pending {
            guard !Task.isCancelled else { return }
            let words = await Task.detached(priority:.utility) { () -> [GraphWord] in
                guard let url = try? GraphAssets.url(path),let image = UIImage(contentsOfFile:url.path) else { return [] }
                return (try? GraphCapture.recognize(image)) ?? []
            }.value
            if let index = model.graph.nodes.firstIndex(where: { $0.id == id }),model.graph.nodes[index].screenshot?.ocrStatus == "pending" {
                model.graph.nodes[index].screenshot?.words = words
                model.graph.nodes[index].screenshot?.ocrStatus = words.isEmpty ? "failed" : "done"
                model.save()
            }
        }
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
        Binding(get: { model.graph.nodes.first(where: { $0.id == id }) ?? KnowledgeNode(id:id,graphId:model.graph.id,kind:.text,frame:.zero,isNew:false) }, set: { value in
            if let index = model.graph.nodes.firstIndex(where: { $0.id == id }) { model.graph.nodes[index] = value; model.save() }
        })
    }
    private func nodeView(_ node: KnowledgeNode) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: node.kind == .ink ? "pencil.tip" : node.kind == .text ? "text.alignleft" : node.kind == .document ? "book.closed" : "photo")
                Text(node.isNew ? "新" : node.kind == .text ? "文本" : node.kind == .ink ? "标记" : node.kind == .document ? "文档图谱" : "截图").font(.caption)
                Spacer()
                if let shot = node.screenshot, onSource != nil { Button("来源") { model.save(immediate: true); closePanel(); onSource?(shot) }.font(.caption) }
                if editing == node.id { Button("完成") { editing = nil }.font(.caption) }
                else if node.kind == .text { Button("编辑") { selected = node.id; model.checkpoint(); editing = node.id }.font(.caption) }
            }
            .foregroundStyle(DS.foreground2)
            .padding(.horizontal,10).frame(height:GraphConfig.headerHeight).background(DS.accentContainer.opacity(0.65)).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global).updating($nodeGestureActive) { _,active,_ in active = true }.onChanged { value in
                guard zoomOrigin == nil else { return }
                selected = node.id; editing = nil
                if moveOrigin == nil { model.checkpoint(); moveOrigin = node.frame; movingNode = node.id }
                var valueNode = node
                valueNode.frame.origin = CGPoint(x: moveOrigin!.minX+value.translation.width/model.graph.zoom, y: moveOrigin!.minY+value.translation.height/model.graph.zoom)
                transientFrame = valueNode.frame
            }.onEnded { _ in finishManipulation() })
            content(node)
        }
        .background(DS.background2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected == node.id || connectionTarget == node.id ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected == node.id || connectionTarget == node.id ? 2 : 1))
        .overlay { if selected == node.id { handles(node) } }
        .onTapGesture { selected = node.id }
        .onHover { inside in if inside && movingNode == nil && zoomOrigin == nil { selected = node.id } }
        .overlay {
            if moveMode {
                Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global).updating($nodeGestureActive) { _,active,_ in active = true }.onChanged { value in
                    guard zoomOrigin == nil else { return }
                    selected = node.id
                    if moveOrigin == nil { model.checkpoint(); moveOrigin = node.frame; movingNode = node.id }
                    var n = node; n.frame.origin = CGPoint(x:moveOrigin!.minX+value.translation.width/model.graph.zoom,y:moveOrigin!.minY+value.translation.height/model.graph.zoom)
                    transientFrame = n.frame
                }.onEnded { _ in finishManipulation() })
            }
        }
        .contextMenu {
            Button("置于顶层") { model.checkpoint(); var n = node; n.zIndex = (model.graph.nodes.map(\.zIndex).max() ?? 0)+1; binding(node.id).wrappedValue = n }
            Button("置于底层") { model.checkpoint(); var n = node; n.zIndex = (model.graph.nodes.map(\.zIndex).min() ?? 0)-1; binding(node.id).wrappedValue = n }
            if node.kind != .document {
                Button("删除", role: .destructive) { model.checkpoint(); model.graph.delete(node.id); model.save() }
            }
        }
    }
    @ViewBuilder private func content(_ node: KnowledgeNode) -> some View {
        if node.kind == .document {
            let document = libraryDocuments?.first { $0.sha256 == node.sourceDocumentId }
            Button {
                if let id = node.sourceDocumentId { model.save(immediate:true); onOpenDocument?(id) }
            } label: {
                VStack(alignment:.leading,spacing:10) {
                    Image(systemName:"book.closed.fill").font(.title2).foregroundStyle(DS.accent)
                    Text(document?.title ?? node.text).font(.headline).multilineTextAlignment(.leading).lineLimit(3)
                    Label(document == nil ? "文档不可用" : "打开知识图谱",systemImage:"arrow.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading).padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(document == nil || onOpenDocument == nil)
        } else if node.kind == .text {
            if editing == node.id {
                TextEditor(text: Binding(get: { binding(node.id).wrappedValue.text }, set: { text in
                    var n = binding(node.id).wrappedValue; n.text = text; binding(node.id).wrappedValue = n
                }))
                .accessibilityIdentifier("graph-node-editor")
                .padding(5).onAppear { model.checkpoint() }
            } else {
                WordInteractionLayer(text: node.text, onEdit: { model.checkpoint(); editing = node.id })
            }
        } else if node.kind == .ink {
            if selected == node.id && (model.graph.zoom >= GraphConfig.snapshotZoom || movingNode == node.id) {
                GraphInkView(data: Binding(get: { binding(node.id).wrappedValue.drawingData }, set: { data in
                    var n = binding(node.id).wrappedValue; n.drawingData = data; binding(node.id).wrappedValue = n
                }), tools: tools, live: true, onBegin: { model.checkpoint() })
            } else { GraphInkSnapshot(data:node.drawingData) }
        } else if let shot = node.screenshot, let image = GraphImageCache.image(model.graph.zoom < GraphConfig.snapshotZoom ? shot.thumbPath : shot.imagePath) {
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
                    .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).updating($nodeGestureActive) { _,active,_ in active = true }.onChanged { value in
                        guard zoomOrigin == nil else { return }
                        if moveOrigin == nil { model.checkpoint(); moveOrigin = node.frame; movingNode = node.id }
                        let original = moveOrigin!, dx = value.translation.width/model.graph.zoom, dy = value.translation.height/model.graph.zoom
                        var rect = original
                        rect.size.width = max(GraphConfig.minSize, original.width + (corner % 2 == 0 ? -dx : dx))
                        rect.size.height = max(GraphConfig.minSize, original.height + (corner < 2 ? -dy : dy))
                        if node.kind == .screenshot { rect.size.height = (rect.width * (original.height-GraphConfig.headerHeight)/original.width)+GraphConfig.headerHeight }
                        if corner % 2 == 0 { rect.origin.x = original.maxX-rect.width }
                        if corner < 2 { rect.origin.y = original.maxY-rect.height }
                        transientFrame = rect
                    }.onEnded { _ in finishManipulation() })
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
                if let originalA = model.graph.nodes.first(where: { $0.id == edge.from }), let originalB = model.graph.nodes.first(where: { $0.id == edge.to }) {
                    let a = displayed(originalA), b = displayed(originalB)
                    let path = edgePath(edge.fromAnchor.point(in:a.frame),edge.toAnchor.point(in:b.frame))
                    path.stroke(selected == edge.id ? Color.accentColor : Color.secondary, lineWidth: GraphConfig.edgeWidth)
                    path.stroke(Color.black.opacity(0.001), lineWidth: GraphConfig.edgeHitWidth)
                        .contentShape(path.strokedPath(StrokeStyle(lineWidth:GraphConfig.edgeHitWidth)))
                        .onTapGesture { selected = edge.id }
                }
            }
            if let connection, let node = model.graph.nodes.first(where: { $0.id == connection.0 }) {
                edgePath(connection.1.point(in: node.frame), connection.2).stroke(Color.accentColor,lineWidth:GraphConfig.edgeWidth)
            }
        }
    }
}

private enum GraphImageCache {
    static let cache: NSCache<NSString,UIImage> = { let cache = NSCache<NSString,UIImage>(); cache.totalCostLimit = 48*1024*1024; return cache }()
    static func image(_ name: String) -> UIImage? {
        if let image = cache.object(forKey:name as NSString) { return image }
        guard let url = try? GraphAssets.url(name),let image = UIImage(contentsOfFile:url.path) else { return nil }
        cache.setObject(image,forKey:name as NSString,cost:Int(image.size.width*image.size.height*4)); return image
    }
}
private struct GraphInkSnapshot: UIViewRepresentable {
    let data: Data
    func makeUIView(context:Context) -> SnapshotView { SnapshotView() }
    func updateUIView(_ view:SnapshotView,context:Context) { view.data = data }
    final class SnapshotView: UIImageView {
        var data = Data() { didSet { if oldValue != data { refresh = true; setNeedsLayout() } } }
        private var refresh = true
        private var lastSize = CGSize.zero
        override func layoutSubviews() {
            super.layoutSubviews()
            guard refresh || lastSize != bounds.size else { return }
            guard bounds.width > 0,bounds.height > 0 else { return }
            refresh = false; lastSize = bounds.size
            image = (try? PKDrawing(data:data))?.image(from:bounds,scale:1)
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
