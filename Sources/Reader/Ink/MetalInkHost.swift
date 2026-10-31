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
            if !newValue { finishErase() }
            drawingEnabled = newValue
            canvas.isDrawingEnabled = newValue && canvas.isReady
        }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    func attach(to pdfView: PDFView, store: PencilInkStore?, docSha: String) {
        if self.docSha != docSha {
            pages.removeAll(); undoStack.removeAll(); redoStack.removeAll()
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
                [.pen, .pencil, .marker, .crayon, .eraser].contains(self.activeTool)
        }
        grab.onBegan = { [weak self] touch, _ in
            guard let self else { return }
            self.refresh()
            if self.activeTool == .eraser { self.erase(at: touch.location(in: self.canvas)) }
            else { self.canvas.handleBegan(touch) }
        }
        grab.onMoved = { [weak self] touches, event in
            guard let self else { return }
            if self.activeTool == .eraser, let touch = touches.first(where: { $0.type == .pencil }) {
                for sample in event?.coalescedTouches(for: touch) ?? [touch] { self.erase(at: sample.location(in: self.canvas)) }
            } else { self.canvas.handleMoved(touches, event: event) }
        }
        grab.onEnded = { [weak self] touches, event in
            guard let self else { return }
            if self.activeTool == .eraser {
                if let touch = touches.first(where: { $0.type == .pencil }) { self.erase(at: touch.location(in: self.canvas)) }
                self.finishErase()
            } else { self.canvas.handleEnded(touches, event: event) }
        }
        grab.onCancelled = { [weak self] in self?.finishErase(); self?.canvas.handleCancelled() }
        pdf.addGestureRecognizer(grab); pencilGrab = grab
    }

    private func observeScroll() {
        guard let pdfView, let scroll = pdfView.documentView?.superview as? UIScrollView else { return }
        guard observedScrollView !== scroll else { return }
        observedScrollView = scroll
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

    func applyTool(kind: PencilToolKind, color: UIColor, baseWidth: CGFloat, eraserRadius: CGFloat, whole: Bool) {
        finishErase(); canvas.handleCancelled()
        activeTool = kind; self.eraserRadius = eraserRadius; eraserWhole = whole
        canvas.inkKind = InkStroke.Kind(rawValue: kind.rawValue) ?? .pen
        canvas.inkColor = color; canvas.baseWidth = max(0.8, baseWidth)
        DiagLog.log("metal ink: tool=\(kind.rawValue) whole=\(whole) radius=\(eraserRadius)")
    }

    func refresh() {
        guard let pdfView, let document = pdfView.document, let docView = pdfView.documentView,
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
        if frame.width > 1 && (frame.contains(visible) || canvas.hasActiveStroke || lastEraserPoint != nil) {
            window = frame
        } else {
            window = visible.insetBy(dx: -visible.width/2, dy: -visible.height/2)
        }
        let geometryChanged = frame != window
        if geometryChanged { frame = window; canvas.frame = bounds }
        let origin = docView.convert(CGPoint.zero, to: pdfView)
        let unit = docView.convert(CGPoint(x: 1,y: 0), to: pdfView)
        let screenDensity = UIScreen.main.scale * hypot(unit.x-origin.x,unit.y-origin.y)
        let density = min(screenDensity,4096 / max(bounds.width,bounds.height))
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

    private func commit(_ stroke: InkStroke) {
        guard stroke.points.count >= 2 else { return }
        commitGroup += 1
        var additions: [Int: [InkStroke]] = [:]
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
        for (index, strokes) in additions {
            let before = pageInk(index); var after = before; after.strokes.append(contentsOf: strokes)
            pages[index] = after
            undoStack.append(UndoEntry(group: commitGroup,page: index,before: before,after: after))
        }
        if !additions.isEmpty { redoStack.removeAll(); persist(Set(additions.keys)) }
    }

    private func erase(at point: CGPoint) {
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
        if changed { needsInkRefresh = true; refresh() }
    }
    private func finishErase() {
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
        finishErase()
        guard let group = undoStack.last?.group else { return }
        var moved: [UndoEntry] = []
        while let entry = undoStack.last, entry.group == group {
            undoStack.removeLast(); pages[entry.page] = entry.before; moved.append(entry)
        }
        redoStack.append(contentsOf: moved.reversed()); persist(Set(moved.map(\.page)))
    }
    func redo() {
        guard let group = redoStack.last?.group else { return }
        var moved: [UndoEntry] = []
        while let entry = redoStack.last, entry.group == group {
            redoStack.removeLast(); pages[entry.page] = entry.after; moved.append(entry)
        }
        undoStack.append(contentsOf: moved.reversed()); persist(Set(moved.map(\.page)))
    }
    private func persist(_ indexes: Set<Int>) {
        needsInkRefresh = true
        for index in indexes { store?.save(docSha: docSha,page: index,data: (pages[index] ?? InkPage()).data(),scale: 1) }
        refresh()
    }
}
