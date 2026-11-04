import SwiftUI

struct PencilArcMenu: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("toolArc.leftHanded") private var leftHanded = false
    @AppStorage("developer.arcGeometry") private var debugGeometry = false
    @ObservedObject var session: PencilToolSession
    let anchor: CGPoint
    let bounds: CGSize
    var marking = false
    var canUndo = false
    var canRedo = false
    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}
    var onScreenshot: () -> Void = {}
    var onMode: () -> Void = {}
    var onSelect: () -> Void = {}
    var onDismiss: () -> Void
    @State private var leftExtent: CGFloat = 0
    @State private var rightExtent: CGFloat = 0
    @State private var reset: Task<Void, Never>?
    @State private var appeared = false
    @State private var customizing = false
    @State private var showActions = true
    private var capacity: Int { ToolArcConfig.visibleToolCapacity(in:bounds) }
    private var tools: [PencilArcItem] { Array(session.arcItems.prefix(capacity)) }
    private var geometry: ToolArcGeometry { ToolArcGeometry(anchor: anchor, bounds: bounds, count: tools.count, leftHanded: leftHanded, upperCount:upper.count) }
    private var upper: [(String, String)] {
        marking ? [("arrow.uturn.backward", "撤销"), ("arrow.uturn.forward", "重做"), ("viewfinder", "知识图谱截图"), ("text.cursor", "切换到阅读模式"), ("slider.horizontal.3", "自定义工具")] : [("viewfinder", "知识图谱截图"), ("slider.horizontal.3", "自定义工具")]
    }
    private var visibleIndices: Range<Int> {
        let base = geometry.initialRange
        let start = max(0,base.lowerBound-Int(floor(leftExtent)))
        let end = min(tools.count,base.upperBound+Int(floor(rightExtent)))
        return start..<end
    }
    private func visible(_ index: Int) -> Bool { visibleIndices.contains(index) }
    var body: some View {
        ZStack {
            Color.black.opacity(0.001).ignoresSafeArea()
            lowerTrack.trim(from:trackTrim.lowerBound,to:trackTrim.upperBound).stroke(DS.background3.opacity(0.75),style:StrokeStyle(lineWidth:ToolArcConfig.diameter+12,lineCap:.round))
            if debugGeometry {
                Path { path in
                    let a = geometry.point(angle:geometry.mid-ToolArcConfig.sweep/2,radius:geometry.radius)
                    let b = geometry.point(angle:geometry.mid+ToolArcConfig.sweep/2,radius:geometry.radius)
                    path.move(to:a);path.addLine(to:b)
                    path.move(to:geometry.point(angle:geometry.mid,radius:0));path.addLine(to:a)
                    path.move(to:geometry.point(angle:geometry.mid,radius:0));path.addLine(to:b)
                }.stroke(Color.red.opacity(0.65),style:StrokeStyle(lineWidth:1,dash:[4,4])).allowsHitTesting(false)
                Circle().stroke(Color.red,lineWidth:2).frame(width:10,height:10).position(x:anchor.x+geometry.translation.width,y:anchor.y+geometry.translation.height).allowsHitTesting(false)
            }
            ForEach(Array(tools.enumerated()).filter { visible($0.offset) }, id: \.element.id) { index, tool in
                icon(tool.systemImage, label: tool.label, active: session.isActive(tool)) {
                    session.activate(tool); onSelect(); onDismiss()
                }.overlay(alignment:.bottomTrailing) {
                    if let preset = tool.preset {
                        Circle().fill(Color(uiColor:preset.state.currentUIColor)).frame(width:10,height:10).padding(3).allowsHitTesting(false)
                    }
                }.transition(.identity).opacity(appeared ? 1 : 0).position(geometry.position(index, count: tools.count, upper: false))
            }
            if showActions { ForEach(upper.indices, id: \.self) { index in
                icon(upper[index].0, label: upper[index].1, active: false) { activateUpper(index) }
                    .opacity(appeared ? (enabled(index) ? 1 : 0.3) : 0).position(geometry.position(index, count: upper.count, upper: true))
                    .animation(reduceMotion ? .easeOut(duration:0.15) : .spring(response:0.28,dampingFraction:0.82).delay(0.04),value:appeared)
            }
            }
            ArcInput(onHover: hover, onTap: { point, pencil in
                if showActions, let index = geometry.index(at: point, count: upper.count, upper: true) { activateUpper(index) }
                else if let index = geometry.index(at: point, count: tools.count, upper: false), visible(index) {
                    session.activate(tools[index]); onSelect(); onDismiss()
                } else { onDismiss() }
            }, onSqueeze: onDismiss).accessibilityHidden(true).allowsHitTesting(!customizing)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: ToolArcConfig.animation), value: leftExtent)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: ToolArcConfig.animation), value: rightExtent)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
        .readerPanel(isPresented:$customizing,title:"自定义手写工具") {
            PencilToolCustomization(session:session,onActivate:{ customizing = false; onSelect(); onDismiss() })
        }
        .onChange(of: bounds) { _, _ in onDismiss() }
        .onAppear { withAnimation(reduceMotion ? .easeOut(duration:0.15) : .spring(response:0.28,dampingFraction:0.82)) { appeared = true } }
        .onDisappear { reset?.cancel() }
    }
    private func icon(_ name: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 19, weight: .medium))
                .frame(width: ToolArcConfig.diameter, height: ToolArcConfig.diameter)
                .background(DS.background3, in: Circle())
                .overlay(Circle().stroke(active ? DS.accent : DS.foreground3.opacity(0.15), lineWidth: active ? 2 : 1))
                .shadow(color: .black.opacity(0.12), radius: 5, y: 3)
        }.accessibilityLabel(label)
    }
    private func track(_ index:Int,count:Int,upper:Bool) -> Path {
        let radius = geometry.radius+(upper ? ToolArcConfig.gap : 0)
        let angle = geometry.mid+(CGFloat(index)-CGFloat(count-1)/2)*geometry.pitch/radius
        var path = Path()
        for i in 0...8 {
            let p = geometry.point(angle:angle+(CGFloat(i)/8-0.5)*geometry.pitch/radius,radius:radius)
            if i == 0 { path.move(to:p) } else { path.addLine(to:p) }
        }
        return path
    }
    private var lowerTrack: Path {
        var path = Path()
        let half = fullTrackHalf
        let start = geometry.mid-half
        let end = geometry.mid+half
        for step in 0...80 {
            let point = geometry.point(angle:start+(end-start)*CGFloat(step)/80,radius:geometry.radius)
            if step == 0 { path.move(to:point) } else { path.addLine(to:point) }
        }
        return path
    }
    private var fullTrackHalf: CGFloat {
        max(ToolArcConfig.sweep/2,(max(geometry.toolMid,CGFloat(max(0,tools.count-1))-geometry.toolMid)*geometry.pitch+ToolArcConfig.diameter/2)/geometry.radius)
    }
    private var trackTrim: ClosedRange<CGFloat> {
        let middle = geometry.toolMid
        let left = max(ToolArcConfig.sweep/2,((middle-CGFloat(geometry.initialRange.lowerBound)+leftExtent)*geometry.pitch+ToolArcConfig.diameter/2)/geometry.radius)
        let right = max(ToolArcConfig.sweep/2,((CGFloat(geometry.initialRange.upperBound-1)+rightExtent-middle)*geometry.pitch+ToolArcConfig.diameter/2)/geometry.radius)
        return max(0,(fullTrackHalf-left)/(fullTrackHalf*2))...min(1,(fullTrackHalf+right)/(fullTrackHalf*2))
    }
    private func enabled(_ index: Int) -> Bool {
        return !marking || index > 1 || (index == 0 ? canUndo : canRedo)
    }
    private func activateUpper(_ index: Int) {
        if index == upper.count-1 { customizing = true; return }
        guard enabled(index) else { return }
        if !marking || index == 2 { onDismiss(); onScreenshot() }
        else if index == 0 { onUndo() }
        else if index == 1 { onRedo() }
        else { onMode(); onDismiss() }
    }
    private func hover(_ point: CGPoint?) {
        if let point {
            let polar = geometry.polar(point)
            if abs(polar.r - geometry.radius) <= ToolArcConfig.band {
                reset?.cancel(); reset = nil
                let units = geometry.delta(polar.angle) * geometry.radius / geometry.pitch
                let extent = max(0, abs(units) - 1.5)
                if units < 0 { leftExtent = min(CGFloat(geometry.initialRange.lowerBound),max(leftExtent,extent)) }
                else { rightExtent = min(CGFloat(tools.count-geometry.initialRange.upperBound),max(rightExtent,extent)) }
                return
            }
            if abs(polar.r - geometry.radius - ToolArcConfig.gap) <= ToolArcConfig.band {
                reset?.cancel(); reset = nil; showActions = true; return
            }
            if abs(polar.r - geometry.radius) < ToolArcConfig.band + ToolArcConfig.hysteresis { return }
        }
        guard reset == nil else { return }
        reset = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(ToolArcConfig.resetDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            leftExtent = 0; rightExtent = 0; showActions = true; reset = nil
        }
    }
}
private struct ArcInput: UIViewRepresentable {
    let onHover: (CGPoint?) -> Void
    let onTap: (CGPoint, Bool) -> Void
    let onSqueeze: () -> Void
    func makeUIView(context: Context) -> ArcInputView { ArcInputView() }
    func updateUIView(_ view: ArcInputView, context: Context) { view.onHover = onHover; view.onTap = onTap; view.onSqueeze = onSqueeze }
}
private final class ArcInputView: UIView, UIPencilInteractionDelegate {
    var onHover: ((CGPoint?) -> Void)?
    var onTap: ((CGPoint, Bool) -> Void)?
    var onSqueeze: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        let pencil = UIPencilInteraction(); pencil.delegate = self; addInteraction(pencil)
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        if squeeze.phase == .began, ReaderSqueezeGate.shared.accept() { onSqueeze?() }
    }
    @objc private func hover(_ gesture: UIHoverGestureRecognizer) {
        onHover?(gesture.state == .ended || gesture.state == .cancelled ? nil : gesture.location(in: self))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { if let touch = touches.first { onHover?(touch.location(in: self)) } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { if let touch = touches.first { onTap?(touch.location(in: self), touch.type == .pencil) } }
}
