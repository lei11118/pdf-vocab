import SwiftUI

/// v0.15.0:Pencil Pro 挤压**弧形工具盘**(参照 references/assets/ui-squeeze-arc-menu.png):
/// 围绕笔尖出现一段白色扇环,沿弧线排列 [直尺 / 钢笔 / 铅笔 / 荧光笔 / 套索 / 橡皮];
/// 点按扇区即切换工具并收起;点空白处或再挤压收起。
/// 设计依据:把"工具切换"从另一只手/屏幕边缘搬到**笔本身**——手不离纸。
/// v0.16.2:去掉原来的「撤销」扇区 —— 弧盘贴着笔尖弹出,误触一次撤销会让整页笔迹回退
/// (真机日志抓到 30 笔 → 10 笔);撤销仍保留在工具条按钮与双指轻点。
struct PencilArcMenu: View {
    @ObservedObject var session: PencilToolSession
    /// 笔尖位置(阅读页坐标)
    let anchor: CGPoint
    /// 可用空间(用于钳制,防止弧盘出屏)
    let bounds: CGSize
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
        /// nil = 直尺扇区
        let tool: PencilToolKind?
        var ruler = false
    }

    private var entries: [ArcEntry] {
        var list: [ArcEntry] = [ArcEntry(id: 0, tool: nil, ruler: true)]
        for (offset, tool) in session.visibleKinds.enumerated() {
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
                if entry.ruler {
                    Image(systemName: "ruler")
                        .foregroundStyle(session.rulerActive ? DS.accent : DS.foreground2)
                } else if let tool = entry.tool {
                    Image(systemName: tool.systemImage)
                        .foregroundStyle(session.kind == tool ? DS.accent : DS.foreground2)
                } else {
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(DS.foreground3)
                }
            }
            .font(.system(size: 21, weight: .medium))
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.ruler ? (session.rulerActive ? "关闭直尺" : "打开直尺") : (entry.tool?.label ?? "工具"))
    }

    private func activate(_ entry: ArcEntry) {
        if entry.ruler {
            session.toggleRuler()
            DiagLog.log("arc: ruler -> \(session.rulerActive ? 1 : 0)")
        } else if let tool = entry.tool {
            session.select(kind: tool)
            DiagLog.log("arc: tool=\(tool.rawValue)")
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
