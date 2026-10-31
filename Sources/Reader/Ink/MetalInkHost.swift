import UIKit
import PDFKit
import PencilKit

/// Ink lives in PDFKit's document tree, so scrolling transforms paper and ink together.
/// Page-local vectors remain the only persisted coordinates.
final class MetalInkHost: UIView {
    private weak var pdfView: PDFView?
    private let canvas = InkMetalCanvasView()
    private var store: PencilInkStore?
    private var docSha = ""
    private var pages: [Int: InkPage] = [:]
    private var boxes: [Int: CGRect] = [:]
    private var mappings: [Int: CGAffineTransform] = [:]
    private var observations: [NSKeyValueObservation] = []
    private weak var observedScrollView: UIScrollView?
    private var refreshScheduled = false
    private(set) var isAttached = false
    private var pencilGrab: InkPencilGrabRecognizer?
    private let editing = InkEditingOverlay(frame:.zero)
    private var shapeKind: PencilShapeKind = .line
    private var editPath: [CGPoint] = []
    private var editEnd: CGPoint?
    private var transforming = false
    private var selected: [Int: Set<Int>] = [:]
    private var transformRefs: [Int: Set<Int>] = [:]
    private var transformBefore: [Int: InkPage] = [:]
    private var memoryObserver: NSObjectProtocol?
    private var activeTool: PencilToolKind = .pen
    private var eraserWhole = false
    private var eraserRadius: CGFloat = 11
    private var lastEraserPoint: CGPoint?
    private var eraseBefore: [Int: InkPage] = [:]
    private var drawingEnabled = false
    private var needsInkRefresh = true
    private struct UndoEntry {
        var group: Int
        var page: Int
        var before: InkPage
        var after: InkPage
    }
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private var commitGroup = 0
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// Ruler geometry is defined in viewport coordinates.
    var strokeProjector: ((CGPoint) -> ((CGPoint) -> CGPoint)?)?
    var isDrawingEnabled: Bool {
        get { drawingEnabled }
        set {
            if !newValue { finishErase(); clearInkSelection() }
            drawingEnabled = newValue
            canvas.isDrawingEnabled = newValue && canvas.isReady
        }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    func attach(to pdfView: PDFView, store: PencilInkStore?, docSha: String) {
        if self.docSha != docSha {
            finishErase(); canvas.handleCancelled(); clearInkSelection()
            pages.removeAll(); undoStack.removeAll(); redoStack.removeAll()
            boxes.removeAll();mappings.removeAll();canvas.renderItems=[];needsInkRefresh=true
        }
        if self.pdfView !== pdfView, let pencilGrab { self.pdfView?.removeGestureRecognizer(pencilGrab); self.pencilGrab = nil }
        self.pdfView = pdfView; self.store = store; self.docSha = docSha
        backgroundColor = .clear; isOpaque = false
        canvas.backgroundColor = .clear
        if canvas.superview == nil { addSubview(canvas) }
        canvas.onStrokeCommitted = { [weak self] in self?.commit($0) }
        canvas.strokeProjector = { [weak self] local in
            guard let self, let pdf = self.pdfView,
                  let project = self.strokeProjector?(self.canvas.convert(local, to: pdf)) else { return nil }
            return { [weak self, weak pdf] p in
                guard let self, let pdf else { return p }
                return self.canvas.convert(project(self.canvas.convert(p, to: pdf)), from: pdf)
            }
        }
        editing.frame = pdfView.bounds
        editing.autoresizingMask = [.flexibleWidth,.flexibleHeight]
        pdfView.addSubview(editing)
        editing.onBegin = { [weak self] in self?.beginInkTransform() }
        editing.onChange = { [weak self] in self?.transformSelectedInk($0) }
        editing.onEnd = { [weak self] in self?.endInkTransform(cancelled:$0) }
        if memoryObserver == nil {
            memoryObserver = NotificationCenter.default.addObserver(forName:UIApplication.didReceiveMemoryWarningNotification,object:nil,queue:.main) { [weak self] _ in
                guard let self else { return }
                DiagLog.log("metal ink: memory warning cachePages=\(self.pages.count) undo=\(self.undoStack.count)")
                self.canvas.releaseCachedResources()
                if let newest=self.undoStack.last?.group { self.undoStack.removeAll { $0.group < newest-7 } }
                self.redoStack.removeAll()
                self.trimPageCache(); self.needsInkRefresh = true; self.scheduleRefresh()
            }
        }
        isAttached = true
        installPencilGrab(on: pdfView)
        observeScroll()
        refresh()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if canvas.frame != bounds { canvas.frame = bounds }
    }

    private func installPencilGrab(on pdf: PDFView) {
        guard pencilGrab == nil else { return }
        let grab = InkPencilGrabRecognizer(target: nil, action: nil)
        grab.isActive = { [weak self] in
            guard let self else { return false }
            return self.drawingEnabled && self.canvas.isReady &&
                [.pen, .pencil, .marker, .crayon, .eraser, .lasso, .shape].contains(self.activeTool)
        }
        grab.onBegan = { [weak self] touch, _ in
            guard let self else { return }
            self.refresh()
            DiagLog.log("metal ink: input begin tool=\(self.activeTool.rawValue) cachePages=\(self.pages.count) undo=\(self.undoStack.count)")
            if self.activeTool == .lasso || self.activeTool == .shape { self.beginEdit(at:touch.location(in:self.pdfView)) }
            else if self.activeTool == .eraser { self.erase(at: touch.location(in: self.canvas)) }
            else { self.canvas.handleBegan(touch) }
        }
        grab.onMoved = { [weak self] touches, event in
            guard let self else { return }
            if self.activeTool == .lasso || self.activeTool == .shape {
                if let t = touches.first(where: { $0.type == .pencil }) { self.moveEdit(to:t.location(in:self.pdfView)) }
            } else if self.activeTool == .eraser, let touch = touches.first(where: { $0.type == .pencil }) {
                for sample in event?.coalescedTouches(for: touch) ?? [touch] { self.erase(at: sample.location(in: self.canvas)) }
            } else { self.canvas.handleMoved(touches, event: event) }
        }
        grab.onEnded = { [weak self] touches, event in
            guard let self else { return }
            if self.activeTool == .lasso || self.activeTool == .shape {
                if let t = touches.first(where: { $0.type == .pencil }) { self.moveEdit(to:t.location(in:self.pdfView)) }
                self.endEdit()
            } else if self.activeTool == .eraser {
                if let touch = touches.first(where: { $0.type == .pencil }) { self.erase(at: touch.location(in: self.canvas)) }
                self.finishErase()
            } else { self.canvas.handleEnded(touches, event: event) }
        }
        grab.onCancelled = { [weak self] in self?.cancelEdit(); self?.finishErase(); self?.canvas.handleCancelled() }
        pdf.addGestureRecognizer(grab); pencilGrab = grab
    }

    private func observeScroll() {
        guard let pdfView, let scroll = pdfView.documentView?.superview as? UIScrollView else { return }
        guard observedScrollView !== scroll else { return }
        observedScrollView = scroll
        scroll.isDirectionalLockEnabled = false
        scroll.panGestureRecognizer.require(toFail:editing.pan)
        observations = [
            scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            scroll.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() }
        ]
    }
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false; self.refresh()
        }
    }

    func applyTool(kind: PencilToolKind, color: UIColor, baseWidth: CGFloat, eraserRadius: CGFloat, whole: Bool, shape: PencilShapeKind = .line) {
        finishErase(); canvas.handleCancelled(); clearInkSelection()
        shapeKind = shape
        activeTool = kind; self.eraserRadius = eraserRadius; eraserWhole = whole
        canvas.inkKind = InkStroke.Kind(rawValue: kind.rawValue) ?? .pen
        canvas.inkColor = color; canvas.baseWidth = max(0.8, baseWidth)
        DiagLog.log("metal ink: tool=\(kind.rawValue) whole=\(whole) radius=\(eraserRadius)")
    }

    func refresh() {
        guard isAttached, let pdfView, let document = pdfView.document, let docView = pdfView.documentView,
              document.pageCount > 0 else { return }
        observeScroll()
        let focus = pdfView.page(for: CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), nearest: true)
        let current = min(document.pageCount-1, max(0, focus.map { document.index(for: $0) } ?? 0))
        var docRects: [Int: CGRect] = [:]
        var docMappings: [Int: CGAffineTransform] = [:]
        var window = CGRect.null
        for index in max(0,current-1)...min(document.pageCount-1,current+1) {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: pdfView.displayBox)
            func convert(_ p: CGPoint) -> CGPoint { docView.convert(pdfView.convert(p, from: page), from: pdfView) }
            let o = convert(CGPoint(x: box.minX, y: box.maxY))
            let x = convert(CGPoint(x: box.minX+1, y: box.maxY))
            let y = convert(CGPoint(x: box.minX, y: box.maxY-1))
            let transform = CGAffineTransform(a: x.x-o.x, b: x.y-o.y, c: y.x-o.x, d: y.y-o.y, tx: o.x, ty: o.y)
            guard abs(transform.a*transform.d-transform.b*transform.c) > 0.000001 else { continue }
            let rect = docView.convert(pdfView.convert(box, from: page), from: pdfView)
            docRects[index] = rect; docMappings[index] = transform; window = window.union(rect)
        }
        guard !window.isNull, window.width > 1, window.height > 1 else { return }
        if superview !== docView { docView.addSubview(self); needsInkRefresh = true }
        // Keep a stable, padded viewport tile in document coordinates. Moving
        // inside it needs no geometry rebuild; the scroll view moves ink natively.
        let visible = docView.convert(pdfView.bounds, from: pdfView)
        let expectedSize = CGSize(width:visible.width*1.3,height:visible.height*1.3)
        let tileSizedForZoom = abs(frame.width-expectedSize.width) < expectedSize.width*0.15 && abs(frame.height-expectedSize.height) < expectedSize.height*0.15
        if frame.width > 1 && ((frame.contains(visible) && tileSizedForZoom) || canvas.hasActiveStroke || lastEraserPoint != nil || transforming || !editPath.isEmpty) {
            window = frame
        } else {
            window = visible.insetBy(dx: -visible.width*0.15, dy: -visible.height*0.15)
        }
        let geometryChanged = frame != window
        if geometryChanged { frame = window; canvas.frame = bounds }
        let origin = docView.convert(CGPoint.zero, to: pdfView)
        let unit = docView.convert(CGPoint(x: 1,y: 0), to: pdfView)
        let screenDensity = UIScreen.main.scale * hypot(unit.x-origin.x,unit.y-origin.y)
        // Pixel budget bounds the three render surfaces without stretching a
        // document-sized low-resolution cache during a zoom gesture.
        let pixelBudget: CGFloat = 10_000_000
        canvas.rasterScale = screenDensity
        let density = min(screenDensity, min(8192 / max(bounds.width,bounds.height),sqrt(pixelBudget / max(1,bounds.width*bounds.height))))
        let pixels = CGSize(width: max(1,(bounds.width*density).rounded()),height: max(1,(bounds.height*density).rounded()))
        let resolutionChanged = canvas.drawableSize != pixels
        canvas.autoResizeDrawable = false
        if resolutionChanged { canvas.drawableSize = pixels }
        let shift = CGAffineTransform(translationX: -window.minX, y: -window.minY)
        let nextBoxes = docRects.mapValues { $0.applying(shift) }
        let sameGeometry = nextBoxes.count == boxes.count && nextBoxes.allSatisfy { index, rect in
            guard let old = boxes[index] else { return false }
            return abs(rect.minX-old.minX) < 0.001 && abs(rect.minY-old.minY) < 0.001 &&
                   abs(rect.width-old.width) < 0.001 && abs(rect.height-old.height) < 0.001
        }
        refreshSelectionOverlay()
        if sameGeometry && !geometryChanged && !resolutionChanged && !needsInkRefresh { return }
        needsInkRefresh = false
        boxes = nextBoxes
        mappings = docMappings.mapValues { $0.concatenating(shift) }
        canvas.clipRects = Array(boxes.values)
        let scale = mappings[current].map { hypot($0.a,$0.b) } ?? 1
        canvas.viewScale = scale
        var items: [InkRenderItem] = []
        for index in boxes.keys.sorted() {
            guard let mapping = mappings[index], let clip = boxes[index] else { continue }
            for stroke in pageInk(index).strokes {
                var mapped = stroke
                mapped.points = stroke.points.map { p in
                    var q = p; let v = p.cg.applying(mapping)
                    q.x = Double(v.x); q.y = Double(v.y); q.width *= Double(hypot(mapping.a,mapping.b)); return q
                }
                items.append(InkRenderItem(stroke: mapped, clip: clip))
            }
        }
        canvas.renderItems = items
        // Geometry and pixels must change in the same transaction on window recenter.
        if geometryChanged || resolutionChanged { canvas.draw() }
        trimPageCache()
    }

    private func pageInk(_ index: Int) -> InkPage {
        if let cached = pages[index] { return cached }
        var result = InkPage()
        if let record = store?.drawing(docSha: docSha, page: index) {
            if let decoded = InkPage.decode(record.data) { result = decoded }
            else if let old = try? PKDrawing(data: record.data) {
                result = InkPage(strokes: InkLegacyMigration.strokes(from: old, scale: CGFloat(max(1,record.scale))))
            }
        }
        pages[index] = result; return result
    }

    func commit(_ stroke: InkStroke) { commitStrokes([stroke]) }
    func commitStrokes(_ strokes: [InkStroke]) {
        guard !strokes.isEmpty else { return }
        commitGroup += 1
        var additions: [Int: [InkStroke]] = [:]
        for stroke in strokes where stroke.points.count >= 2 {
        var owner: Int?; var run: [InkPoint] = []
        func flush() {
            defer { run.removeAll() }
            guard let index = owner, !run.isEmpty, let map = mappings[index] else { return }
            var local = stroke; let inverse = map.inverted(); let scale = hypot(map.a,map.b)
            local.points = run.map { p in
                var q = p; let v = p.cg.applying(inverse)
                q.x = Double(v.x); q.y = Double(v.y); q.width /= Double(scale); return q
            }
            if local.points.count == 1 { local.points.append(local.points[0]) }
            additions[index,default: []].append(local)
        }
        for point in stroke.points {
            let next = boxes.first { $0.value.contains(point.cg) }?.key
            if next != owner { flush(); owner = next }
            if next != nil { run.append(point) }
        }
        flush()
        }
        for (index, strokes) in additions {
            let before = pageInk(index); var after = before; after.strokes.append(contentsOf: strokes)
            pages[index] = after
            undoStack.append(UndoEntry(group: commitGroup,page: index,before: before,after: after))
        }
        if !additions.isEmpty { redoStack.removeAll(); persist(Set(additions.keys)) }
    }

    func erase(at point: CGPoint) {
        let previous = lastEraserPoint ?? point; lastEraserPoint = point
        var changed = false
        for index in boxes.keys {
            guard let mapping = mappings[index] else { continue }
            let inverse = mapping.inverted()
            let before = pageInk(index)
            let result = InkEraser.erase(before.strokes, from: previous.applying(inverse), to: point.applying(inverse), radius: eraserRadius, whole: eraserWhole)
            if result.changed {
                if eraseBefore[index] == nil { eraseBefore[index] = before }
                pages[index] = InkPage(strokes: result.strokes); changed = true
            }
        }
        if changed { needsInkRefresh = true; scheduleRefresh() }
    }
    func finishErase() {
        lastEraserPoint = nil
        guard !eraseBefore.isEmpty else { return }
        commitGroup += 1
        let touched = Set(eraseBefore.keys)
        for (index,before) in eraseBefore {
            undoStack.append(UndoEntry(group: commitGroup,page: index,before: before,after: pages[index] ?? InkPage()))
        }
        eraseBefore.removeAll(); redoStack.removeAll(); persist(touched)
        DiagLog.log("metal ink: erase pages=\(touched.count)")
    }
    func undo() {
        clearInkSelection();finishErase()
        guard let group = undoStack.last?.group else { return }
        var moved: [UndoEntry] = []
        while let entry = undoStack.last, entry.group == group {
            undoStack.removeLast(); pages[entry.page] = entry.before; moved.append(entry)
        }
        redoStack.append(contentsOf: moved.reversed()); persist(Set(moved.map(\.page)))
    }
    func redo() {
        finishErase();clearInkSelection()
        guard let group = redoStack.last?.group else { return }
        var moved: [UndoEntry] = []
        while let entry = redoStack.last, entry.group == group {
            redoStack.removeLast(); pages[entry.page] = entry.after; moved.append(entry)
        }
        undoStack.append(contentsOf: moved.reversed()); persist(Set(moved.map(\.page)))
    }
    private func persist(_ indexes: Set<Int>) {
        needsInkRefresh = true
        if let oldestGroup = undoStack.last.map({ max(0,$0.group-63) }) { undoStack.removeAll { $0.group < oldestGroup } }
        for index in indexes { store?.save(docSha: docSha,page: index,data: (pages[index] ?? InkPage()).data(),scale: 1) }
        refresh()
    }
    func detach() {
        finishErase();canvas.handleCancelled();clearInkSelection()
        drawingEnabled=false;canvas.isDrawingEnabled=false
        if let pencilGrab { pdfView?.removeGestureRecognizer(pencilGrab) }
        pencilGrab=nil;observations.removeAll();observedScrollView=nil
        editing.removeFromSuperview();removeFromSuperview();isAttached=false
        canvas.releaseCachedResources()
    }
    deinit { if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) } }
    private func trimPageCache() {
        guard pages.count > 8, transformBefore.isEmpty, eraseBefore.isEmpty else { return }
        pages = pages.filter { boxes[$0.key] != nil || selected[$0.key] != nil }
    }
    func clearInkSelection() {
        if transforming { endInkTransform(cancelled:true) }
        selected.removeAll(); editPath.removeAll(); editing.selection = .null; editing.preview = []
    }
    private func viewport(_ p: InkPoint, page index: Int) -> CGPoint? {
        guard let map = mappings[index], let pdfView else { return nil }
        return canvas.convert(p.cg.applying(map),to:pdfView)
    }
    func selectInk(in polygon: [CGPoint]) {
        selected.removeAll()
        for index in boxes.keys {
            for (i,stroke) in pageInk(index).strokes.enumerated() {
                if InkEditGeometry.intersects(stroke.points.compactMap { viewport($0,page:index) },polygon:polygon) {
                    selected[index,default:[]].insert(i)
                }
            }
        }
        refreshSelectionOverlay()
    }
    var selectedInkCount: Int { selected.values.reduce(0) { $0+$1.count } }
    private func refreshSelectionOverlay() {
        guard let pdfView else { return }
        editing.frame = pdfView.bounds
        var points: [CGPoint] = []
        for (page, refs) in selected {
            let strokes = pageInk(page).strokes
            for i in refs where strokes.indices.contains(i) { points += strokes[i].points.compactMap { viewport($0,page:page) } }
        }
        editing.selection = points.isEmpty ? .null : InkEditGeometry.bounds(points).insetBy(dx:-8,dy:-8)
        editing.isHidden = !drawingEnabled
        if editing.superview === pdfView { pdfView.bringSubviewToFront(editing) }
    }
    func beginInkTransform() {
        guard !selected.isEmpty else { return }
        transforming = true; transformRefs = selected
        transformBefore = Dictionary(uniqueKeysWithValues:boxes.keys.map { ($0,pageInk($0)) })
    }
    func transformSelectedInk(_ transform: CGAffineTransform) {
        guard transforming, let pdfView else { return }
        var updated = transformBefore
        var refs: [Int:Set<Int>] = [:]
        for (page, indices) in transformRefs {
            guard var value = updated[page] else { continue }
            value.strokes = value.strokes.enumerated().filter { !indices.contains($0.offset) }.map { $0.element }
            updated[page] = value
        }
        for (page,indices) in transformRefs {
            guard let original = transformBefore[page] else { continue }
            for i in indices where original.strokes.indices.contains(i) {
                let stroke = original.strokes[i]
                var destinations: [(Int,InkPoint)] = []
                for p in stroke.points {
                    guard let v = viewport(p,page:page) else { return }
                    let moved = canvas.convert(v.applying(transform),from:pdfView)
                    guard let owner = boxes.first(where: { $0.value.contains(moved) })?.key, let map = mappings[owner] else { return }
                    let local = moved.applying(map.inverted())
                    var q = p; q.x = Double(local.x); q.y = Double(local.y)
                    q.width *= Double(sqrt(abs(transform.a*transform.d-transform.b*transform.c)))
                    destinations.append((owner,q))
                }
                var owner: Int?; var run: [InkPoint] = []
                func flush() {
                    guard let page = owner, !run.isEmpty else { return }
                    if run.count == 1 { run.append(run[0]) }
                    var piece = stroke; piece.points = run
                    var bucket = updated[page] ?? InkPage()
                    refs[page,default:[]].insert(bucket.strokes.count)
                    bucket.strokes.append(piece); updated[page] = bucket; run.removeAll()
                }
                for (page,p) in destinations {
                    if owner != page { flush(); owner = page }
                    run.append(p)
                }
                flush()
            }
        }
        for (page,value) in updated { pages[page] = value }
        selected = refs; needsInkRefresh = true; refresh()
    }
    func endInkTransform(cancelled: Bool) {
        guard transforming else { return }
        transforming = false
        let originals = transformBefore
        if cancelled { for (p,value) in originals { pages[p] = value }; selected = transformRefs }
        else {
            commitGroup += 1
            for (p,before) in originals {
                let after = pages[p] ?? InkPage()
                if before != after { undoStack.append(UndoEntry(group:commitGroup,page:p,before:before,after:after)) }
            }
            redoStack.removeAll()
        }
        transformBefore.removeAll(); transformRefs.removeAll()
        if cancelled { needsInkRefresh = true; refresh() } else { persist(Set(originals.keys)) }
    }
    func beginEdit(at point: CGPoint) {
        if activeTool == .lasso && editing.point(inside:point,with:nil) {
            editing.begin(at:point)
        } else { clearInkSelection(); editPath = [point];editEnd = point }
    }
    func moveEdit(to point: CGPoint) {
        if transforming { editing.move(to:point); return }
        guard let first = editPath.first else { return }
        editEnd=point
        if activeTool == .shape {
            editing.preview = InkEditGeometry.shape(shapeKind,from:first,to:point)
            editing.previewColor = canvas.inkColor
            editing.previewWidth = canvas.baseWidth * (pdfView?.scaleFactor ?? 1)
        } else {
            if let last = editPath.last, hypot(last.x-point.x,last.y-point.y)>2 { editPath.append(point) }
            editing.preview = [editPath]; editing.previewColor = .systemBlue; editing.previewWidth = 1.5
        }
    }
    func endEdit() {
        if transforming { editing.onEnd?(false); return }
        defer { editPath.removeAll();editEnd=nil; editing.preview = [] }
        if activeTool == .lasso { selectInk(in:editPath); return }
        guard let first = editPath.first, let last=editEnd, let pdfView,
              hypot(first.x-last.x,first.y-last.y)>2 else { return }
        var r: CGFloat=0,g: CGFloat=0,b: CGFloat=0,a: CGFloat=1
        canvas.inkColor.getRed(&r,green:&g,blue:&b,alpha:&a)
        let strokes = editing.preview.map { points in
            InkStroke(kind:.custom,r:Double(r),g:Double(g),b:Double(b),a:Double(a),points:points.map {
                let p = canvas.convert($0,from:pdfView)
                return InkPoint(x:Double(p.x),y:Double(p.y),width:Double(canvas.baseWidth*canvas.viewScale))
            })
        }
        commitStrokes(strokes)
    }
    private func cancelEdit() {
        if transforming { endInkTransform(cancelled:true) }
        editPath.removeAll(); editing.preview = []
    }

}
