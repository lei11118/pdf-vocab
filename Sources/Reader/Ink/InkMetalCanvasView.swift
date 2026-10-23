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
    var renderItems: [InkRenderItem] = [] { didSet { rebuildVertices() } }
    /// 允许落墨的页矩形(视图坐标);Pencil 落在这些矩形之外一律不落墨
    var clipRects: [CGRect] = []
    /// 一段墨提交(视图坐标)。跨页/越界时会被切成多段分别提交。
    var onStrokeCommitted: ((InkStroke) -> Void)?

    var inkColor: UIColor = .black { didSet { colorDirty = true } }
    /// 基础笔宽(**页面点**;实际笔宽 = baseWidth × viewScale × 压感 × 速度)
    var baseWidth: CGFloat = 3.0
    /// 页面点 → 视图点(宿主每次刷新告知)
    var viewScale: CGFloat = 1
    var isDrawingEnabled = false
    /// 管线编译成功才允许接管触摸 —— 否则会"吞掉所有输入但什么都不画"
    var isReady: Bool { pipeline != nil }

    // MARK: - Metal

    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    private var vertexCount = 0
    private var colorDirty = true

    // MARK: - 输入

    /// 当前正在写的一段(视图坐标)
    private var draft = InkStroke(kind: .pen, r: 0.04, g: 0.04, b: 0.04, a: 1, points: [])
    private var penDown = false
    private var lastTimestamp: TimeInterval = 0
    private var lastSampleTime: TimeInterval = 0

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
        commandQueue = dev?.makeCommandQueue()
        buildPipeline(device: dev)
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
                           constant VIn *v [[buffer(0)]],
                           constant float2 &size [[buffer(1)]]) {
            VOut o;
            float2 p = v[vid].pos;
            o.position = float4(p.x / size.x * 2.0 - 1.0, 1.0 - p.y / size.y * 2.0, 0.0, 1.0);
            o.d = v[vid].d; o.hw = v[vid].hw; o.clip = v[vid].clip; o.color = v[vid].color;
            return o;
        }
        fragment float4 f_main(VOut in [[stage_in]],
                               constant float2 &pxPerPoint [[buffer(2)]]) {
            float2 p = in.position.xy / max(pxPerPoint, float2(0.0001));
            if (p.x < in.clip.x || p.y < in.clip.y || p.x > in.clip.z || p.y > in.clip.w) {
                discard_fragment();
            }
            float aa = max(fwidth(in.d), 0.6);
            float cov = 1.0 - smoothstep(in.hw - aa, in.hw, abs(in.d));
            return float4(in.color.rgb, in.color.a * cov);
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
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .sourceAlpha
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            DiagLog.log("metal ink: pipeline failed \(error.localizedDescription)")
        }
    }

    // MARK: - 命中(v0.47.0:笔落墨、手指穿透给 PDFView 滚动)

    /// 只有 Pencil 才接管命中;手指直接返回 nil,让 PDFView 自己的滚动/捏合/选词照常工作。
    /// v0.46.0 无条件 `return super.hitTest` 会把手指也吞掉 —— 真机表现是"单指滑不动"。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isDrawingEnabled, isReady, let event else { return nil }
        let touches = event.allTouches ?? []
        guard touches.contains(where: { $0.type == .pencil }) else { return nil }
        return super.hitTest(point, with: event)
    }

    // MARK: - 输入

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isDrawingEnabled, let touch = touches.first, touch.type == .pencil else { return }
        begin(at: touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isDrawingEnabled, penDown, let touch = touches.first, touch.type == .pencil else { return }
        // 合并采样:优先 coalesced(真实历史点),否则用当前点
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        for t in samples where t.timestamp > lastSampleTime {
            appendSample(t)
        }
        // ⚠️ 预测点**只用于预览**,绝不能写回 draft ——
        // 否则"预测点越界 → 提交 → 预测点把已提交的笔复活"会无限重复提交同一笔。
        rebuildVertices(predicted: event?.predictedTouches(for: touch) ?? [])
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard penDown else { return }
        if let t = touches.first, t.type == .pencil { appendSample(t) }
        flushDraft()
        endStroke()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        flushDraft()
        endStroke()
    }

    private func endStroke() {
        penDown = false
        draft = InkStroke(kind: .pen, r: 0.04, g: 0.04, b: 0.04, a: 1, points: [])
        rebuildVertices()
    }

    private func begin(at touch: UITouch) {
        var stroke = InkStroke(kind: .pen, r: 0.04, g: 0.04, b: 0.04, a: 1, points: [])
        if let c = inkColor.cgColor.components, c.count >= 3 {
            stroke.r = Double(c[0]); stroke.g = Double(c[1]); stroke.b = Double(c[2])
            stroke.a = c.count >= 4 ? Double(c[3]) : 1
        }
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
        let viewPoint = touch.location(in: self)
        guard clipRects.contains(where: { $0.contains(viewPoint) }) else {
            // 页外:当前段到此为止(已在页面内的部分保留)
            flushDraft()
            lastTimestamp = touch.timestamp
            lastSampleTime = touch.timestamp
            return
        }
        let dt = max(0.001, touch.timestamp - lastTimestamp)
        lastTimestamp = touch.timestamp
        lastSampleTime = touch.timestamp

        let last = draft.points.last
        let dist = last.map { hypot(CGFloat(viewPoint.x) - CGFloat($0.x), CGFloat(viewPoint.y) - CGFloat($0.y)) } ?? 0
        if let last, dist < 0.35, draft.points.count > 1 {
            // 同一位置的重复采样(合并采样常见),只更新压力不新增顶点
            draft.points[draft.points.count - 1].force = Double(touch.force)
            return
        }
        let speed = dist / CGFloat(dt)
        let forceFactor = touch.type == .pencil
            ? max(0.35, min(1.6, touch.force > 0 ? Double(touch.force) * 2.0 : 0.8))
            : 0.8
        let speedFactor = max(0.45, min(1.35, 1.25 - Double(speed) * 0.02))
        let width = Double(baseWidth * viewScale) * forceFactor * speedFactor

        draft.points.append(InkPoint(x: Double(viewPoint.x), y: Double(viewPoint.y),
                                     width: width, force: Double(touch.force),
                                     altitude: Double(touch.altitudeAngle),
                                     azimuth: Double(touch.azimuthAngle(in: self)),
                                     time: touch.timestamp))
        if draft.points.count > 4000 { flushDraft() }
    }

    /// 把当前段交给宿主;不足两点直接丢弃(单点画不出东西)
    private func flushDraft() {
        guard draft.points.count >= 2 else { draft.points.removeAll(); return }
        let stroke = draft
        draft.points.removeAll()
        onStrokeCommitted?(stroke)
    }

    // MARK: - 顶点生成

    private func rebuildVertices(predicted: [UITouch] = []) {
        var verts: [Vertex] = []
        for item in renderItems { appendVertices(item.stroke, clip: item.clip, into: &verts) }
        if penDown, draft.points.count >= 1 {
            // 实时段:预览点只在这里参与,不进 draft
            var live = draft
            for t in predicted {
                let p = t.location(in: self)
                guard clipRects.contains(where: { $0.contains(p) }) else { continue }
                let last = live.points.last
                let d = last.map { hypot(CGFloat(p.x) - CGFloat($0.x), CGFloat(p.y) - CGFloat($0.y)) } ?? 0
                guard d > 0.35 else { continue }
                live.points.append(InkPoint(x: Double(p.x), y: Double(p.y),
                                            width: last?.width ?? Double(baseWidth * viewScale),
                                            force: Double(t.force),
                                            altitude: Double(t.altitudeAngle),
                                            azimuth: Double(t.azimuthAngle(in: self)),
                                            time: t.timestamp))
            }
            let clip = clipRects.first(where: { $0.contains(live.points[0].cg) }) ?? .zero
            if !clip.isEmpty { appendVertices(live, clip: clip, into: &verts) }
        }
        vertexCount = verts.count
        guard !verts.isEmpty, let device else {
            vertexBuffer = nil
            setNeedsDisplay()
            return
        }
        let length = MemoryLayout<Vertex>.stride * verts.count
        vertexBuffer = device.makeBuffer(bytes: verts, length: length, options: .storageModeShared)
        setNeedsDisplay()
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
        let pts = stroke.points
        guard pts.count >= 2 else { return }
        let color = SIMD4<Float>(Float(stroke.r), Float(stroke.g), Float(stroke.b), Float(stroke.a))
        let clipV = SIMD4<Float>(Float(clip.minX), Float(clip.minY), Float(clip.maxX), Float(clip.maxY))

        var halves = [CGFloat](repeating: 0.5, count: pts.count)
        for i in 0..<pts.count { halves[i] = max(0.35, CGFloat(pts[i].width) * 0.5) }

        // ① 每段一个四边形(带符号距离 d = ±半宽,片元里做 AA)
        for i in 0..<(pts.count - 1) {
            let a = pts[i].cg, b = pts[i + 1].cg
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
            guard shouldRound(at: i, in: pts) else { continue }
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
        let r = Float(max(0.4, radius))
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

    func draw(in view: MTKView) {
        guard let pipeline, let queue = commandQueue,
              let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor,
              let buffer = vertexBuffer, vertexCount > 0 else { return }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        var size = SIMD2<Float>(Float(max(1, bounds.width)), Float(max(1, bounds.height)))
        let px = SIMD2<Float>(Float(drawable.texture.width) / size.x,
                              Float(drawable.texture.height) / size.y)
        var pxBytes = px
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.setFragmentBytes(&pxBytes, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
