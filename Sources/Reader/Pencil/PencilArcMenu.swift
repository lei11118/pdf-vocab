import SwiftUI

struct PencilArcMenu: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("toolArc.leftHanded") private var leftHanded = false
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
    private var tools: [PencilToolKind] { session.visibleKinds }
    private var geometry: ToolArcGeometry { ToolArcGeometry(anchor: anchor, bounds: bounds, count: tools.count, leftHanded: leftHanded) }
    private var upper: [(String, String)] {
        marking ? [("arrow.uturn.backward", "撤销"), ("arrow.uturn.forward", "重做"), ("viewfinder", "知识图谱截图"), ("text.cursor", "切换到阅读模式")] : [("viewfinder", "知识图谱截图")]
    }
    private func alpha(_ index: Int) -> Double {
        let offset = CGFloat(index) - CGFloat(tools.count - 1) / 2
        let initial = CGFloat(geometry.initialCount - 1) / 2
        let limit = initial + (offset < 0 ? leftExtent : rightExtent)
        return Double(max(0.25, min(1, 1 - (abs(offset) - limit) / 1.25)))
    }
    var body: some View {
        ZStack {
            Color.black.opacity(0.001).ignoresSafeArea()
            ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                icon(tool.systemImage, label: tool.label, active: session.kind == tool) {
                    session.select(kind: tool); onSelect(); onDismiss()
                }.opacity(alpha(index)).position(geometry.position(index, count: tools.count, upper: false))
            }
            ForEach(upper.indices, id: \.self) { index in
                icon(upper[index].0, label: upper[index].1, active: false) { activateUpper(index) }
                    .opacity(enabled(index) ? 1 : 0.3).position(geometry.position(index, count: upper.count, upper: true))
            }
            ArcInput(onHover: hover, onTap: { point, pencil in
                if let index = geometry.index(at: point, count: upper.count, upper: true) { activateUpper(index) }
                else if let index = geometry.index(at: point, count: tools.count, upper: false), !pencil || alpha(index) >= 0.85 {
                    session.select(kind: tools[index]); onSelect(); onDismiss()
                } else { onDismiss() }
            }).accessibilityHidden(true)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: ToolArcConfig.animation), value: leftExtent)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: ToolArcConfig.animation), value: rightExtent)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
        .onChange(of: bounds) { _, _ in onDismiss() }
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
    private func enabled(_ index: Int) -> Bool { !marking || index > 1 || (index == 0 ? canUndo : canRedo) }
    private func activateUpper(_ index: Int) {
        guard enabled(index) else { return }
        if !marking || index == 2 { onDismiss(); onScreenshot() }
        else if index == 0 { onUndo() }
        else if index == 1 { onRedo() }
        else { onMode(); onDismiss() }
    }
    private func hover(_ point: CGPoint?) {
        if let point {
            let polar = geometry.polar(point)
            if abs(polar.r - ToolArcConfig.radius) <= ToolArcConfig.band {
                reset?.cancel(); reset = nil
                let units = (polar.angle - geometry.mid) * ToolArcConfig.radius / geometry.pitch
                let extent = max(0, abs(units) - CGFloat(geometry.initialCount - 1) / 2 + 1.25)
                if units < 0 { leftExtent = max(leftExtent, extent) } else { rightExtent = max(rightExtent, extent) }
                return
            }
            if abs(polar.r - ToolArcConfig.radius) < ToolArcConfig.band + ToolArcConfig.hysteresis { return }
        }
        guard reset == nil else { return }
        reset = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(ToolArcConfig.resetDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            leftExtent = 0; rightExtent = 0; reset = nil
        }
    }
}
private struct ArcInput: UIViewRepresentable {
    let onHover: (CGPoint?) -> Void
    let onTap: (CGPoint, Bool) -> Void
    func makeUIView(context: Context) -> ArcInputView { ArcInputView() }
    func updateUIView(_ view: ArcInputView, context: Context) { view.onHover = onHover; view.onTap = onTap }
}
private final class ArcInputView: UIView {
    var onHover: ((CGPoint?) -> Void)?
    var onTap: ((CGPoint, Bool) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func hover(_ gesture: UIHoverGestureRecognizer) {
        onHover?(gesture.state == .ended || gesture.state == .cancelled ? nil : gesture.location(in: self))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { if let touch = touches.first { onHover?(touch.location(in: self)) } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { if let touch = touches.first { onTap?(touch.location(in: self), touch.type == .pencil) } }
}
