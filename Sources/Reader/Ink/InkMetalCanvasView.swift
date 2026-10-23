import UIKit
import MetalKit
import PencilKit

/// v0.45.0:自研墨迹渲染 —— **Metal 解析式描边**(对照 Notability 逆向文档 §4.5)。
///
/// 与 PencilKit 的根本区别:这里画的是**几何轮廓**(中心线 + 每点笔宽),
/// 片元用 `fwidth` 做抗锯齿。所以分辨率永远等于设备像素,缩放不会把位图放大。
///
/// 边界规则(D2-A):采样点一旦离开页面矩形就丢弃,当前段立即提交 →
/// 页外永不产生墨迹,跨页一笔被页边切成两段(各留原位)。
final class InkMetalCanvasView: MTKView {

    // MARK: - 对外

    /// 当前页墨迹(页面坐标),由宿主注入
    var pageStrokes: [InkStroke] = [] { didSet { rebuildVertices() } }
    /// 页面坐标 → 视图坐标
    var pageTransform: CGAffineTransform = .identity { didSet { rebuildVertices() } }
    /// 允许落墨的页矩形(视图坐标),用于硬裁剪
    var clipRects: [CGRect] = [] { didSet { rebuildVertices() } }
    /// 落笔完成(页面坐标)
    var onStrokeCommitted: ((InkStroke) -> Void)?

    var inkColor: UIColor = .black { didSet { colorDirty = true } }
    /// 基础笔宽(页面点)
    var baseWidth: CGFloat = 3.0
    var isDrawingEnabled = false
    /// 管线编译成功才允许接管触摸 —— 否则会"吞掉所有输入但什么都不画"
    var isReady: Bool { pipeline != nil }

    // MARK: - Metal

    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    private var vertexCount = 0

    // MARK: - 输入

    private var liveRun: [InkPoint] = []
    private var liveStroke: InkStroke?
    private var lastTime: TimeInterval = 0
    private var colorDirty = true

    // MARK: - 初始化

    init() {
        let dev = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: dev)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        isOpaque = false
        backgroundColor = .clear
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
        guard let device, let queue = commandQueue else {
            DiagLog.log("metal ink: no device"); return
        }
        _ = queue
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct VIn  { float2 pos; float d; float hw; float4 color; };
        struct VOut { float4 position [[position]]; float d; float hw; float4 color; };
        vertex VOut v_main(uint vid [[vertex_id]],
                           constant VIn *v [[buffer(0)]],
                           constant float2 &size [[buffer(1)]]) {
            VOut o;
            float2 p = v[vid].pos;
            o.position = float4(p.x / size.x * 2.0 - 1.0, 1.0 - p.y / size.y * 2.0, 0.0, 1.0);
            o.d = v[vid].d; o.hw = v[vid].hw; o.color = v[vid].color;
            return o;
        }
        fragment float4 f_main(VOut in [[stage_in]]) {
            float aa = max(fwidth(in.d), 0.75);
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

    // MARK: - 输入

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isDrawingEnabled, let touch = touches.first, touch.type == .pencil else { return }
        beginStroke(at: touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isDrawingEnabled, let touch = touches.first, touch.type == .pencil else { return }
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        for t in coalesced { append(t) }
        // 预测点:只画不落库,减少跟手延迟
        if let predicted = event?.predictedTouches(for: touch), !predicted.isEmpty,
           var preview = liveStroke {
            for t in predicted { appendPoint(from: t, into: &preview) }
            liveStroke = preview
        }
        rebuildVertices()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isDrawingEnabled else { return }
        if let t = touches.first { append(t) }
        commitLiveRun()
        liveStroke = nil
        rebuildVertices()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        liveRun.removeAll(); liveStroke = nil; rebuildVertices()
    }

    private func beginStroke(at touch: UITouch) {
        liveRun.removeAll()
        lastTime = touch.timestamp
        var stroke = InkStroke(kind: .pen, r: 0.04, g: 0.04, b: 0.04, a: 1, points: [])
        if let c = inkColor.cgColor.components, c.count >= 3 {
            stroke.r = Double(c[0]); stroke.g = Double(c[1]); stroke.b = Double(c[2])
            stroke.a = c.count >= 4 ? Double(c[3]) : 1
        }
        appendPoint(from: touch, into: &stroke)
        liveStroke = stroke
        rebuildVertices()
    }

    private func append(_ touch: UITouch) {
        guard var stroke = liveStroke else { return }
        appendPoint(from: touch, into: &stroke)
        liveStroke = stroke
    }

    /// 把触摸点转成页面坐标;页外点被丢弃并结束当前段(硬裁剪)
    private func appendPoint(from touch: UITouch, into stroke: inout InkStroke) {
        let viewPoint = touch.location(in: self)
        guard let rect = clipRects.first(where: { $0.contains(viewPoint) }) else {
            commitLiveRun()
            if var s = liveStroke { s.points.removeAll(); liveStroke = s }
            return
        }
        let pagePoint = viewPoint.applying(pageTransform.inverted())
        let dt = max(0.001, touch.timestamp - lastTime)
        lastTime = touch.timestamp

        // 速度 → 笔宽(2-A:每点宽度,速度越快越细,压感加粗)
        let last = stroke.points.last
        let dist = last.map { hypot(CGFloat(pagePoint.x) - CGFloat($0.x), CGFloat(pagePoint.y) - CGFloat($0.y)) } ?? 0
        let speed = dist / CGFloat(dt)
        let forceFactor = touch.type == .pencil ? max(0.35, min(1.6, touch.force > 0 ? Double(touch.force) * 2.0 : 0.8)) : 0.8
        let speedFactor = max(0.45, min(1.35, 1.25 - Double(speed) * 0.02))
        let width = Double(baseWidth) * forceFactor * speedFactor

        _ = rect
        stroke.points.append(InkPoint(x: Double(pagePoint.x), y: Double(pagePoint.y),
                                      width: width, force: Double(touch.force),
                                      altitude: Double(touch.altitudeAngle),
                                      azimuth: Double(touch.azimuthAngle(in: self)),
                                      time: touch.timestamp))
        if stroke.points.count > 2000 { commitLiveRun() }
    }

    private func commitLiveRun() {
        guard var stroke = liveStroke, stroke.points.count >= 2 else { return }
        stroke.points.removeAll { $0.width <= 0 }
        if stroke.points.count >= 2 { onStrokeCommitted?(stroke) }
        liveStroke = nil
    }

    // MARK: - 顶点生成

    private func rebuildVertices() {
        var verts: [Vertex] = []
        for stroke in pageStrokes { appendVertices(for: stroke, into: &verts) }
        if let live = liveStroke { appendVertices(for: live, into: &verts) }
        vertexCount = verts.count
        guard !verts.isEmpty, let device else { vertexBuffer = nil; setNeedsDisplay(); return }
        vertexBuffer = device.makeBuffer(bytes: verts,
                                         length: MemoryLayout<Vertex>.stride * verts.count,
                                         options: .storageModeShared)
        setNeedsDisplay()
    }

    private struct Vertex { var pos: SIMD2<Float>; var d: Float; var hw: Float; var color: SIMD4<Float> }

    private func appendVertices(for stroke: InkStroke, into verts: inout [Vertex]) {
        guard stroke.points.count >= 2 else { return }
        let c = SIMD4<Float>(Float(stroke.r), Float(stroke.g), Float(stroke.b), Float(stroke.a))
        for i in 0..<(stroke.points.count - 1) {
            let a0 = stroke.points[i], b0 = stroke.points[i + 1]
            let a = a0.cg.applying(pageTransform), b = b0.cg.applying(pageTransform)
            let wa = max(0.4, CGFloat(a0.width) * scaleFactor()), wb = max(0.4, CGFloat(b0.width) * scaleFactor())
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(0.0001, hypot(dx, dy))
            let nx = -dy / len, ny = dx / len

            let a1 = SIMD2<Float>(Float(a.x + nx * wa), Float(a.y + ny * wa))
            let a2 = SIMD2<Float>(Float(a.x - nx * wa), Float(a.y - ny * wa))
            let b1 = SIMD2<Float>(Float(b.x + nx * wb), Float(b.y + ny * wb))
            let b2 = SIMD2<Float>(Float(b.x - nx * wb), Float(b.y - ny * wb))
            let fa = Float(wa), fb = Float(wb)
            // 两三角形:a1,a2,b1 / a2,b2,b1
            verts.append(Vertex(pos: a1, d: fa, hw: fa, color: c))
            verts.append(Vertex(pos: a2, d: -fa, hw: fa, color: c))
            verts.append(Vertex(pos: b1, d: fb, hw: fb, color: c))
            verts.append(Vertex(pos: a2, d: -fa, hw: fa, color: c))
            verts.append(Vertex(pos: b2, d: -fb, hw: fb, color: c))
            verts.append(Vertex(pos: b1, d: fb, hw: fb, color: c))
        }
        // 关节补丁:每点画一个小方块,避免折角缺口
        for p in stroke.points.dropLast() {
            let v = p.cg.applying(pageTransform)
            let w = Float(max(0.4, CGFloat(p.width) * scaleFactor()))
            let c0 = SIMD2<Float>(Float(v.x) - w, Float(v.y) - w)
            let c1 = SIMD2<Float>(Float(v.x) + w, Float(v.y) - w)
            let c2 = SIMD2<Float>(Float(v.x) - w, Float(v.y) + w)
            let c3 = SIMD2<Float>(Float(v.x) + w, Float(v.y) + w)
            verts.append(Vertex(pos: c0, d: -w, hw: w, color: c))
            verts.append(Vertex(pos: c1, d: -w, hw: w, color: c))
            verts.append(Vertex(pos: c3, d: w, hw: w, color: c))
            verts.append(Vertex(pos: c0, d: -w, hw: w, color: c))
            verts.append(Vertex(pos: c3, d: w, hw: w, color: c))
            verts.append(Vertex(pos: c2, d: w, hw: w, color: c))
        }
    }

    /// 页面点 → 视图点的缩放系数
    private func scaleFactor() -> CGFloat { sqrt(abs(pageTransform.a * pageTransform.d - pageTransform.b * pageTransform.c)) }
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
        var size = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
