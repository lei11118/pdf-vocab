import SwiftUI

/// v0.15.0:Pencil Pro 挤压**弧形工具盘**(参照 references/assets/ui-squeeze-arc-menu.png):
/// 围绕笔尖出现一段白色扇环,沿弧线排列 [撤销 / 钢笔 / 铅笔 / 荧光笔 / 橡皮];
/// 点按扇区即切换工具并收起;点空白处或再挤压收起。
/// 设计依据:把"工具切换"从另一只手/屏幕边缘搬到**笔本身**——手不离纸。
struct PencilArcMenu: View {
    @ObservedObject var session: PencilToolSession
    /// 笔尖位置(阅读页坐标)
    let anchor: CGPoint
    /// 可用空间(用于钳制,防止弧盘出屏)
    let bounds: CGSize
    var onUndo: () -> Void
    var onDismiss: () -> Void

    private let radius: CGFloat = 132
    private let thickness: CGFloat = 70

    /// 弧盘圆心:略低于笔尖(扇环开口朝下,包住笔尖)
    private var center: CGPoint {
        CGPoint(
            x: min(max(anchor.x, 200), max(bounds.width - 200, 200)),
            y: min(max(anchor.y, 150), max(bounds.height - 20, 150))
        )
    }

    private struct ArcEntry: Identifiable {
        let id: Int
        /// nil = 撤销
        let tool: PencilToolKind?
    }

    private var entries: [ArcEntry] {
        let tools = session.visibleKinds
        var list: [ArcEntry] = [ArcEntry(id: 0, tool: nil)]
        for (offset, tool) in tools.enumerated() {
            list.append(ArcEntry(id: offset + 1, tool: tool))
        }
        return list
    }

    var body: some View {
        ZStack {
            // 捕获外部点击(透明层)
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            arcShape
                .fill(DS.background3)
                .shadow(color: .black.opacity(0.20), radius: 24, x: 0, y: 10)

            ForEach(entries) { entry in
                arcButton(entry)
                    .position(position(for: entry.id, count: entries.count))
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pencil 工具盘")
    }

    // MARK: - 弧环

    private var arcShape: Path {
        var path = Path()
        let start = Double.pi + 0.18
        let end = 2 * Double.pi - 0.18
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .radians(start),
            endAngle: .radians(end),
            clockwise: false
        )
        return path.strokedPath(StrokeStyle(lineWidth: thickness, lineCap: .round))
    }

    // MARK: - 按钮布局

    private func position(for index: Int, count: Int) -> CGPoint {
        let start = Double.pi + 0.34
        let end = 2 * Double.pi - 0.34
        let t = count <= 1 ? 0.5 : Double(index) / Double(count - 1)
        let angle = start + (end - start) * t
        return CGPoint(
            x: center.x + CGFloat(cos(angle)) * radius,
            y: center.y + CGFloat(sin(angle)) * radius
        )
    }

    private func arcButton(_ entry: ArcEntry) -> some View {
        Button {
            activate(entry)
        } label: {
            Group {
                if let tool = entry.tool {
                    Image(systemName: tool.systemImage)
                        .foregroundStyle(session.kind == tool ? DS.accent : DS.foreground2)
                } else {
                    Image(systemName: "arrow.uturn.backward")
                        .foregroundStyle(DS.foreground2)
                }
            }
            .font(.system(size: 21, weight: .medium))
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.tool?.label ?? "撤销")
    }

    private func activate(_ entry: ArcEntry) {
        if let tool = entry.tool {
            session.select(kind: tool)
        } else {
            onUndo()
        }
        PencilHaptics.selectionCompleted(at: anchor)
        dismiss()
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.16)) {
            onDismiss()
        }
    }
}
