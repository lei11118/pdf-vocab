import UIKit
import MetalKit

/// 一条待渲染的墨迹 + 它所属页面的屏幕矩形。
///
/// v0.47.0:裁剪从"检查采样点"升级为**着色器里逐片元裁剪** ——
/// 一条笔画到页边的半个笔宽也不会溢出页面(用户要求:禁止任何墨迹生成在 PDF 页面之外)。
struct InkRenderItem {
    var stroke: InkStroke
    /// 该笔所属页在视图坐标里的矩形
    var clip: CGRect
}

/// v0.45.0:自研墨迹渲染 —— **Metal 解析式描边**(对照 Notability 逆向文档 §4.5)。
///
/// 与 PencilKit 的根本区别:这里画的是**几何轮廓**(中心线 + 每点笔宽),
/// 片元用 `fwidth` 做抗锯齿。所以分辨率永远等于设备像素,缩放不会把位图放大。
///
/// 坐标系:**一律用视图坐标**(调用方 `MetalInkHost` 负责页面坐标 ↔ 视图坐标换算)。
/// 笔宽同样是视图点,宿主在落库时再除以页面缩放。
///
/// v0.47.0 修复(真机 `diagnostics(7).log` 定位):
/// 1. **预测点不得写回 `liveStroke`** —— v0.46 的 `liveStroke = preview` 会让
///    "页外点触发提交 → 预测点把已提交的笔复活"循环,一次书写提交上百次,
///    屏幕上是一堆重叠重影(日志 `saved page 0 strokes=5…282`);
/// 2. **关节补丁不许画方块** —— v0.46 每点补一个轴对齐方块,真机上就是"笔迹由小方块组成";
///    改成按转角阈值生成**圆盘关节 + 圆头**,没有方块,也没有折角缺口;
/// 3. **页外裁剪交给片元着色器**(`clip` 逐顶点传入),笔宽溢出的半截墨不会留在页面外。
final class InkMetalCanvasView: MTKView {

    // MARK: - 对外

    /// 已落定的墨(视图坐标,由宿主每帧重映射)
    var renderItems: [InkRenderItem] = [] { didSet { renderRevision += 1; rebuildVertices() } }
    /// 允许落墨的页矩形(视图坐标);Pencil 落在这些矩形之外一律不落墨
    var clipRects: [CGRect] = []
    /// 一段墨提交(视图坐标)。跨页/越界时会被切成多段分别提交。
    var onStrokeCommitted: ((InkStroke) -> Void)?

    var inkKind: InkStroke.Kind = .pen
    var inkColor: UIColor = .black { didSet { colorDirty = true } }
    /// 基础笔宽(**页面点**;实际笔宽 = baseWidth × viewScale × 压感 × 速度)
    var baseWidth: CGFloat = 3.0
    /// 页面点 → 视图点(宿主每次刷新告知)
    var viewScale: CGFloat = 1
    var rasterScale: CGFloat = 2
    var isDrawingEnabled = false {
        willSet { if !newValue { handleCancelled() } }
    }
    /// Viewport point mapping, selected once at pen-down (e.g. a ruler edge).
    var strokeProjector: ((CGPoint) -> ((CGPoint) -> CGPoint)?)?
    private var activeProjector: ((CGPoint) -> CGPoint)?
    /// 管线编译成功才允许接管触摸 —— 否则会"吞掉所有输入但什么都不画"
    var isReady: Bool { pipeline != nil && compositePipeline != nil && grainTexture != nil }

    // MARK: - Metal

    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var compositePipeline: MTLRenderPipelineState?
    private var grainTexture: MTLTexture?
    private var coverageTexture: MTLTexture?
    private var dryTexture: MTLTexture?
    private var renderRevision = 0
    private var cachedRevision = -1
    private var dryBatchCount = 0
    private struct Batch { var buffer: MTLBuffer; var count: Int; var style: UInt32 }
    private var dryBatches: [Batch] = []
    private var verticesRevision = -1
    private let inFlight = DispatchSemaphore(value:2)
    private var batches: [Batch] = []
    private var colorDirty = true

    // MARK: - 输入

    /// 当前正在写的一段(视图坐标)
    private var draft = InkStroke(kind: .pen, r: 0.04, g: 0.04, b: 0.04, a: 1, points: [])
    private var penDown = false
    var hasActiveStroke: Bool { penDown }
    private var lastTimestamp: TimeInterval = 0
    private var lastSampleTime: TimeInterval = 0
    private var warnedEmptyClips = false

    // MARK: - 初始化

    init() {
        let dev = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: dev)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        isOpaque = false
        backgroundColor = .clear
        layer.isOpaque = false
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        isMultipleTouchEnabled = true
        // v0.47.1:纯渲染层,不接触摸(手指滚动/笔的落点都不靠命中判定)
        isUserInteractionEnabled = false
        commandQueue = dev?.makeCommandQueue()
        buildPipeline(device: dev)
        if let dev {
            if let image=UIImage(named:"ink-grain-v1")?.cgImage {
                grainTexture=try? MTKTextureLoader(device:dev).newTexture(cgImage:image,options:[.SRGB:false])
            }
            if grainTexture == nil {
                let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1,height:1,mipmapped:false)
                grainTexture=dev.makeTexture(descriptor:desc)
                let pixel:[UInt8]=[128,128,128,255]
                pixel.withUnsafeBytes { grainTexture?.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:4) }
                DiagLog.log("metal ink: using fallback grain")
            }
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 管线

    private func buildPipeline(device: MTLDevice?) {
        guard let device, commandQueue != nil else {
            DiagLog.log("metal ink: no device"); return
        }
        // ⚠️ MSL 保留字:`half`/`float`/`int` 等是类型名,不能当字段名(v0.46 的
        // `float half` 直接编译失败 → 整条渲染管线为 nil → 一个字都不画)。
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct VIn  { float2 pos; float d; float hw; float4 clip; float4 color; };
        struct VOut { float4 position [[position]]; float d; float hw; float4 clip; float4 color; };
        vertex VOut v_main(uint vid [[vertex_id]],
                           device const VIn *v [[buffer(0)]],
                           constant float2 &size [[buffer(1)]]) {
            VOut o;
            float2 p = v[vid].pos;
            o.position = float4(p.x / size.x * 2.0 - 1.0, 1.0 - p.y / size.y * 2.0, 0.0, 1.0);
            o.d = v[vid].d; o.hw = v[vid].hw; o.clip = v[vid].clip; o.color = v[vid].color;
            return o;
        }
        fragment float4 f_main(VOut in [[stage_in]],
                               constant float2 &pxPerPoint [[buffer(2)]],
                               constant uint &style [[buffer(3)]], constant float4 *papers [[buffer(4)]], constant uint &paperCount [[buffer(5)]], texture2d<float> grainMap [[texture(0)]]) {
            float2 p = in.position.xy / max(pxPerPoint, float2(0.0001));
            if (p.x < in.clip.x || p.y < in.clip.y || p.x > in.clip.z || p.y > in.clip.w) {
                discard_fragment();
            }
            if (paperCount>0) {
                bool inside=false;
                for (uint i=0;i<paperCount;i++) { float4 r=papers[i];inside=inside || (p.x>=r.x && p.y>=r.y && p.x<=r.z && p.y<=r.w); }
                if (!inside) discard_fragment();
            }
            float aa = max(fwidth(in.d), 0.65 / max(pxPerPoint.x, pxPerPoint.y));
            float cov = 1.0 - smoothstep(in.hw - aa, in.hw, abs(in.d));
            float grain = 1.0;
            if (style > 0) {
                constexpr sampler paper(coord::normalized,filter::linear,address::repeat);
                float2 uv=(p-in.clip.xy)/(style==1 ? 96.0 : 160.0);
                float fleck=1.0-grainMap.sample(paper,uv).r;
                grain=style==1 ? 0.18+0.82*smoothstep(0.01,0.5,fleck)
                              : 0.4+0.6*smoothstep(0.01,0.35,fleck);
            }
            float alpha = in.color.a * cov * grain;
            return float4(in.color.rgb * alpha, alpha);
        }
        struct QOut { float4 position [[position]]; float2 uv; };
        vertex QOut q_main(uint vid [[vertex_id]]) {
            float2 p = vid == 0 ? float2(-1,-1) : (vid == 1 ? float2(3,-1) : float2(-1,3));
            QOut o; o.position = float4(p,0,1); o.uv = float2((p.x+1)*0.5,(1-p.y)*0.5); return o;
        }
        fragment float4 q_fragment(QOut in [[stage_in]], texture2d<float> ink [[texture(0)]]) {
            constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);
            return ink.sample(s,in.uv);
        }
        """
        do {
            let lib = try device.makeLibrary(source: src, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "v_main")
            desc.fragmentFunction = lib.makeFunction(name: "f_main")
            let att = desc.colorAttachments[0]!
            att.pixelFormat = .bgra8Unorm
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .max
            att.alphaBlendOperation = .max
            att.sourceRGBBlendFactor = .one
            att.destinationRGBBlendFactor = .one
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .one
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            let composite = MTLRenderPipelineDescriptor()
            composite.vertexFunction = lib.makeFunction(name: "q_main")
            composite.fragmentFunction = lib.makeFunction(name: "q_fragment")
            let output = composite.colorAttachments[0]!
            output.pixelFormat = .bgra8Unorm
            output.isBlendingEnabled = true
            output.sourceRGBBlendFactor = .one
            output.sourceAlphaBlendFactor = .one
            output.destinationRGBBlendFactor = .oneMinusSourceAlpha
            output.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            compositePipeline = try device.makeRenderPipelineState(descriptor: composite)
        } catch {
            DiagLog.log("metal ink: pipeline failed \(error.localizedDescription)")
        }
    }

    // MARK: - 输入(v0.47.1:由 `InkPencilGrabRecognizer` 从 PDFView 上抓笔后转进来)

    /// 本视图**完全不接触摸**:它是纯渲染层。通过 `isUserInteractionEnabled = false`
    /// 让所有触摸穿透给 PDFView → 手指滚动/缩放/选词永远是原生行为;
    /// 笔的落点由挂在 PDFView 上的 `InkPencilGrabRecognizer` 转进来。
    func handleBegan(_ touch: UITouch) {
        guard isDrawingEnabled, isReady, touch.type == .pencil else { return }
        DiagLog.log("metal ink: begin kind=\(inkKind.rawValue) force=\(touch.force) maxForce=\(touch.maximumPossibleForce) pixels=\(drawableSize) GPUBytes=\(device?.currentAllocatedSize ?? 0)")
        begin(at: touch)
    }

    func handleMoved(_ touches: Set<UITouch>, event: UIEvent?) {
        guard isDrawingEnabled, penDown, let touch = touches.first(where: { $0.type == .pencil }) else { return }
        // 合并采样:优先 coalesced(真实历史点),否则用当前点
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        for t in samples where t.timestamp > lastSampleTime {
            appendSample(t)
        }
        // ⚠️ 预测点**只用于预览**,绝不能写回 draft ——
        // 否则"预测点越界 → 提交 → 预测点把已提交的笔复活"会无限重复提交同一笔。
        rebuildVertices(predicted: event?.predictedTouches(for: touch) ?? [])
    }

    func handleEnded(_ touches: Set<UITouch>, event: UIEvent?) {
        guard penDown else { return }
        if let t = touches.first(where: { $0.type == .pencil }), t.timestamp > lastSampleTime {
            appendSample(t)
        }
        flushDraft()
        endStroke()
    }

    func handleCancelled() {
        guard penDown || !draft.points.isEmpty else { return }
        flushDraft()
        endStroke()
    }

    private func endStroke() {
        penDown = false
        activeProjector = nil
        draft = InkStroke(kind: .pen, r: 0.04, g: 0.04, b: 0.04, a: 1, points: [])
        rebuildVertices()
    }

    private func begin(at touch: UITouch) {
        activeProjector = strokeProjector?(touch.location(in: self))
        var stroke = InkStroke(kind: inkKind, r: 0.04, g: 0.04, b: 0.04, a: 1, points: [])
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        inkColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        stroke.r = Double(r); stroke.g = Double(g); stroke.b = Double(b); stroke.a = InkBrush.opacity(kind: inkKind, colorAlpha: Double(a))
        stroke.strokeID=UUID()
        draft = stroke
        penDown = true
        lastTimestamp = touch.timestamp
        lastSampleTime = touch.timestamp - 0.001
        appendSample(touch)
        rebuildVertices()
    }

    /// 采一点;点落到所有页面矩形之外时**结束当前段**(不提交页外墨),等回到页面再另起一段。
    private func appendSample(_ touch: UITouch) {
        guard penDown else { return }
        guard touch.timestamp > lastSampleTime else { return }
        let raw = touch.location(in: self)
        let viewPoint = activeProjector?(raw) ?? raw
        // 兜底:宿主还没算过页矩形时用画布范围裁剪 —— 宁可暂时不裁,也不能一个字都不出
        let clips = clipRects
        if clips.isEmpty, !warnedEmptyClips {
            warnedEmptyClips = true
            DiagLog.log("metal ink: no clip rects yet canvas=\(Int(bounds.width))x\(Int(bounds.height))")
        }
        // Crossing a page boundary never ends the logical stroke. Paper clips
        // apply in the renderer and precise page intersections are persisted later.
        lastSampleTime = touch.timestamp

        let last = draft.points.last
        let dist = last.map { hypot(CGFloat(viewPoint.x) - CGFloat($0.x), CGFloat(viewPoint.y) - CGFloat($0.y)) } ?? 0
        if last != nil, dist < 0.25 / max(1,rasterScale), draft.points.count > 1 {
            // 同一位置的重复采样(合并采样常见),只更新压力不新增顶点
            draft.points[draft.points.count - 1].force = Double(touch.force)
            return
        }
        let normalizedForce = InkBrush.normalizedPressure(force:Double(touch.force),maximum:Double(touch.maximumPossibleForce))
        var rawWidth = InkBrush.width(kind: inkKind, base: Double(baseWidth * viewScale),
                                      force: normalizedForce, altitude: Double(touch.altitudeAngle))
        if inkKind == .pen {
            let dt=max(0.001,touch.timestamp-lastTimestamp)
            let speed=Double(dist/max(0.001,viewScale))/dt
            rawWidth *= max(0.72,1-min(0.28,speed/3000))
        }
        let width = draft.points.last.map { $0.width * 0.12 + rawWidth * 0.88 } ?? rawWidth*0.45

        lastTimestamp = touch.timestamp
        draft.points.append(InkPoint(x: Double(viewPoint.x), y: Double(viewPoint.y),
                                     width: width, force: Double(touch.force),
                                     altitude: Double(touch.altitudeAngle),
                                     azimuth: Double(touch.azimuthAngle(in: self)),
                                     time: touch.timestamp))
        if draft.points.count>20000,let anchor=draft.points.last { flushDraft();draft.points=[anchor] }
    }

    /// 把当前段交给宿主;不足两点直接丢弃(单点画不出东西)
    private func flushDraft() {
        guard !draft.points.isEmpty else { return }
        // A tap is a dot, represented by two coincident control points.
        if draft.points.count == 1 { draft.points.append(draft.points[0]) }
        var stroke = draft
        if inkKind == .pen, stroke.points.count > 4 {
            for offset in 0..<min(4,stroke.points.count) {
                stroke.points[stroke.points.count-1-offset].width *= 0.25+0.75*Double(offset)/4
            }
        }
        draft.points.removeAll()
        onStrokeCommitted?(stroke)
    }

    // MARK: - 顶点生成

    private func rebuildVertices(predicted: [UITouch] = []) {
        func makeBatch(_ stroke: InkStroke, clip: CGRect) -> Batch? {
            var verts: [Vertex] = []
            appendVertices(stroke,clip:clip,into:&verts)
            guard !verts.isEmpty, let device else { return nil }
            let length=MemoryLayout<Vertex>.stride*verts.count
            guard length <= device.maxBufferLength,
                  let buffer=device.makeBuffer(bytes:verts,length:length,options:.storageModeShared) else {
                DiagLog.log("metal ink: vertex allocation failed bytes=\(length)"); return nil
            }
            let style:UInt32=stroke.kind == .pencil ? 1 : (stroke.kind == .crayon ? 2 : 0)
            return Batch(buffer:buffer,count:verts.count,style:style)
        }
        if verticesRevision != renderRevision {
            dryBatches=renderItems.compactMap { makeBatch($0.stroke,clip:$0.clip) }
            verticesRevision=renderRevision
        }
        batches=dryBatches; dryBatchCount=batches.count
        if penDown, draft.points.count >= 1 {
            // 实时段:预览点只在这里参与,不进 draft
            var live = draft
            for t in predicted {
                let raw = t.location(in: self)
                let p = activeProjector?(raw) ?? raw
                let allowed = clipRects
                guard allowed.contains(where: { $0.contains(p) }) else { continue }
                let last = live.points.last
                let d = last.map { hypot(CGFloat(p.x) - CGFloat($0.x), CGFloat(p.y) - CGFloat($0.y)) } ?? 0
                guard d > 0.25 / max(1,rasterScale) else { continue }
                live.points.append(InkPoint(x: Double(p.x), y: Double(p.y),
                                            width: last?.width ?? Double(baseWidth * viewScale),
                                            force: Double(t.force),
                                            altitude: Double(t.altitudeAngle),
                                            azimuth: Double(t.azimuthAngle(in: self)),
                                            time: t.timestamp))
            }
            let clip=clipRects.reduce(CGRect.null) { $0.union($1) }
            if !clip.isEmpty, let batch=makeBatch(live,clip:clip) { batches.append(batch) }
        }
        setNeedsDisplay()
    }

    func translateLiveStroke(by delta: CGPoint) {
        guard penDown else { return }
        draft.points=draft.points.map { p in var q=p;q.x+=Double(delta.x);q.y+=Double(delta.y);return q }
    }
    func releaseCachedResources() {
        coverageTexture=nil;dryTexture=nil;dryBatches.removeAll();batches.removeAll()
        verticesRevision = -1;cachedRevision = -1
    }

    /// 顶点布局必须与 MSL 的 `VIn` 逐字节一致:float2 | float | float | float4 | float4 = 48
    private struct Vertex {
        var pos: SIMD2<Float>
        var d: Float
        var hw: Float
        var clip: SIMD4<Float>
        var color: SIMD4<Float>
    }

    private func appendVertices(_ stroke: InkStroke, clip: CGRect, into verts: inout [Vertex]) {
        let pts = stroke.kind == .marker || stroke.kind == .custom ? stroke.points : InkBrush.smoothed(stroke.points)
        guard pts.count >= 2 else { return }
        let color = SIMD4<Float>(Float(stroke.r), Float(stroke.g), Float(stroke.b), Float(stroke.a))
        let visibleClip=clip.intersection(bounds)
        guard !visibleClip.isNull else { return }
        let clipV = SIMD4<Float>(Float(clip.minX), Float(clip.minY), Float(clip.maxX), Float(clip.maxY))

        var halves = [CGFloat](repeating: 0.5, count: pts.count)
        for i in 0..<pts.count { halves[i] = max(0.05, CGFloat(pts[i].width) * 0.5) }

        // ① 每段一个四边形(带符号距离 d = ±半宽,片元里做 AA)
        for i in 0..<(pts.count - 1) {
            let a = pts[i].cg, b = pts[i + 1].cg
            let reach=max(halves[i],halves[i+1])+1
            guard CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:max(0.001,abs(a.x-b.x)),height:max(0.001,abs(a.y-b.y))).insetBy(dx:-reach,dy:-reach).intersects(visibleClip) else { continue }
            let dx = b.x - a.x, dy = b.y - a.y
            let len = hypot(dx, dy)
            guard len > 0.001 else { continue }
            let nx = -dy / len, ny = dx / len
            let wa = halves[i], wb = halves[i + 1]
            let a1 = SIMD2<Float>(Float(a.x + nx * wa), Float(a.y + ny * wa))
            let a2 = SIMD2<Float>(Float(a.x - nx * wa), Float(a.y - ny * wa))
            let b1 = SIMD2<Float>(Float(b.x + nx * wb), Float(b.y + ny * wb))
            let b2 = SIMD2<Float>(Float(b.x - nx * wb), Float(b.y - ny * wb))
            let fa = Float(wa), fb = Float(wb)
            verts.append(Vertex(pos: a1, d: fa, hw: fa, clip: clipV, color: color))
            verts.append(Vertex(pos: a2, d: -fa, hw: fa, clip: clipV, color: color))
            verts.append(Vertex(pos: b1, d: fb, hw: fb, clip: clipV, color: color))
            verts.append(Vertex(pos: a2, d: -fa, hw: fa, clip: clipV, color: color))
            verts.append(Vertex(pos: b2, d: -fb, hw: fb, clip: clipV, color: color))
            verts.append(Vertex(pos: b1, d: fb, hw: fb, clip: clipV, color: color))
        }

        // ② 圆头与圆角关节(只在该补的地方补:两端 + 转角明显的点)
        for i in 0..<pts.count {
            if stroke.kind == .marker, i == 0 || i == pts.count - 1,
               hypot(pts.last!.x-pts[0].x,pts.last!.y-pts[0].y) > 0.001 { continue }
            guard visibleClip.insetBy(dx:-halves[i],dy:-halves[i]).contains(pts[i].cg),shouldRound(at: i, in: pts) else { continue }
            appendDisc(center: pts[i].cg, radius: halves[i], clip: clipV, color: color, into: &verts)
        }
    }

    /// 端点必补(圆头);中间点只在转角 > 20° 时补圆盘,避免退化小方块与无谓顶点
    private func shouldRound(at index: Int, in pts: [InkPoint]) -> Bool {
        if index == 0 || index == pts.count - 1 { return true }
        let a = pts[index - 1].cg, b = pts[index].cg, c = pts[index + 1].cg
        let d1 = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let d2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
        let l1 = hypot(d1.x, d1.y), l2 = hypot(d2.x, d2.y)
        guard l1 > 0.001, l2 > 0.001 else { return true }
        let dot = (d1.x * d2.x + d1.y * d2.y) / (l1 * l2)
        return dot < 0.94   // cos(20°) ≈ 0.94
    }

    private func appendDisc(center: CGPoint, radius: CGFloat, clip: SIMD4<Float>,
                            color: SIMD4<Float>, into verts: inout [Vertex]) {
        let r = Float(max(0.05, radius))
        let c = SIMD2<Float>(Float(center.x), Float(center.y))
        let segments = 10
        for s in 0..<segments {
            let t0 = Float(s) / Float(segments) * 2 * .pi
            let t1 = Float(s + 1) / Float(segments) * 2 * .pi
            let p0 = SIMD2<Float>(c.x + r * cos(t0), c.y + r * sin(t0))
            let p1 = SIMD2<Float>(c.x + r * cos(t1), c.y + r * sin(t1))
            verts.append(Vertex(pos: c, d: 0, hw: r, clip: clip, color: color))
            verts.append(Vertex(pos: p0, d: r, hw: r, clip: clip, color: color))
            verts.append(Vertex(pos: p1, d: r, hw: r, clip: clip, color: color))
        }
    }
}

extension InkMetalCanvasView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Per-stroke max coverage prevents segment/join/self-intersection alpha buildup.
    /// The premultiplied result is composited exactly once over earlier strokes.
    @discardableResult
    func encodeFrame(to target: MTLTexture, commandBuffer: MTLCommandBuffer) -> Bool {
        guard let pipeline, let compositePipeline, let device else { return false }
        if verticesRevision != renderRevision { rebuildVertices() }
        if coverageTexture?.width != target.width || coverageTexture?.height != target.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                         width: target.width, height: target.height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            coverageTexture = device.makeTexture(descriptor: desc)
            dryTexture = device.makeTexture(descriptor: desc)
            cachedRevision = -1
        }
        guard let coverageTexture, let dryTexture else { return false }
        func pass(_ texture: MTLTexture, clear: Bool) -> MTLRenderPassDescriptor {
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = texture
            p.colorAttachments[0].loadAction = clear ? .clear : .load
            p.colorAttachments[0].storeAction = .store
            p.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
            return p
        }
        func clear(_ texture: MTLTexture) -> Bool {
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass(texture,clear: true)) else { return false }
            enc.endEncoding(); return true
        }
        func composite(_ texture: MTLTexture, into output: MTLTexture) -> Bool {
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass(output,clear: false)) else { return false }
            enc.setRenderPipelineState(compositePipeline)
            enc.setFragmentTexture(texture,index: 0)
            enc.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
            enc.endEncoding(); return true
        }
        var size = SIMD2<Float>(Float(max(1,bounds.width)),Float(max(1,bounds.height)))
        var px = SIMD2<Float>(Float(target.width)/size.x,Float(target.height)/size.y)
        func encode(_ batch: Batch, into output: MTLTexture) -> Bool {
            guard let mask = commandBuffer.makeRenderCommandEncoder(descriptor: pass(coverageTexture,clear: true)) else { return false }
            var style = batch.style
            mask.setRenderPipelineState(pipeline)
            mask.setFragmentTexture(grainTexture,index:0)
            mask.setVertexBuffer(batch.buffer,offset: 0,index: 0)
            mask.setVertexBytes(&size,length: MemoryLayout<SIMD2<Float>>.stride,index: 1)
            mask.setFragmentBytes(&px,length: MemoryLayout<SIMD2<Float>>.stride,index: 2)
            mask.setFragmentBytes(&style,length: MemoryLayout<UInt32>.stride,index: 3)
            var papers=clipRects.prefix(64).map { SIMD4<Float>(Float($0.minX),Float($0.minY),Float($0.maxX),Float($0.maxY)) }
            var count=UInt32(papers.count)
            if papers.isEmpty { papers=[.zero] }
            papers.withUnsafeBytes { mask.setFragmentBytes($0.baseAddress!,length:$0.count,index:4) }
            mask.setFragmentBytes(&count,length:MemoryLayout<UInt32>.stride,index:5)
            mask.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: batch.count)
            mask.endEncoding()
            return composite(coverageTexture,into: output)
        }
        // Reuse settled ink while only the predicted/live tail changes.
        if cachedRevision != renderRevision {
            guard clear(dryTexture) else { return false }
            for batch in batches.prefix(dryBatchCount) {
                guard encode(batch,into: dryTexture) else { return false }
            }
            cachedRevision = renderRevision
        }
        guard clear(target), composite(dryTexture,into: target) else { return false }
        for batch in batches.dropFirst(dryBatchCount) {
            guard encode(batch,into: target) else { return false }
        }
        return true
    }

    func draw(in view: MTKView) {
        guard inFlight.wait(timeout:.now()) == .success else {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.016) { [weak self] in self?.setNeedsDisplay() }; return
        }
        guard let drawable=currentDrawable,let command=commandQueue?.makeCommandBuffer(),
              encodeFrame(to:drawable.texture,commandBuffer:command) else { inFlight.signal(); return }
        let gate=inFlight
        command.addCompletedHandler { buffer in
            if let error=buffer.error { DiagLog.log("metal ink: GPU failure \(error.localizedDescription)") }
            gate.signal()
        }
        command.present(drawable);command.commit()
    }
}
