import SwiftUI

/// v0.14.0:Notability 风格浮动工具带。
/// - 首层:钢笔 / 铅笔 / 荧光笔 / 橡皮 + 墨色圆点 + 笔宽 + 撤销 / 重做;
/// - 点墨色圆点展开调色盘(渐进披露);
/// - 可拖动(位置持久记忆),随标记模式出现/消失(短动画,不干扰书写)。
struct PencilPaletteView: View {
    @ObservedObject var session: PencilToolSession
    var onUndo: () -> Void
    var onRedo: () -> Void

    @State private var expanded = false
    @State private var dragStart: CGPoint?
    @AppStorage("pencilPaletteX") private var offsetX: Double = 0
    @AppStorage("pencilPaletteY") private var offsetY: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if expanded {
                colorPanel
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            bar
        }
        .padding(DS.Space.x2s)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.comfy, style: .continuous)
                .fill(DS.background3)
                .shadow(color: .black.opacity(0.16), radius: 16, x: 0, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.comfy, style: .continuous)
                .strokeBorder(DS.foreground1.opacity(0.08), lineWidth: 0.8)
        )
        .offset(x: offsetX, y: offsetY)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = CGPoint(x: offsetX, y: offsetY)
                    }
                    guard let start = dragStart else { return }
                    offsetX = start.x + value.translation.width
                    offsetY = start.y + value.translation.height
                }
                .onEnded { _ in dragStart = nil }
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: expanded)
    }

    // MARK: - 工具带

    private var bar: some View {
        HStack(spacing: DS.Space.x4s) {
            ForEach(session.visibleKinds) { tool in
                toolButton(tool)
                    .contextMenu {
                        Button(role: .destructive) {
                            session.hide(tool)
                        } label: {
                            Label("隐藏\(tool.label)", systemImage: "eye.slash")
                        }
                    }
            }

            if !session.hiddenKinds.isEmpty {
                Menu {
                    ForEach(session.hiddenKinds) { tool in
                        Button {
                            session.unhide(tool)
                        } label: {
                            Label("显示\(tool.label)", systemImage: "eye")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.foreground3)
                        .frame(width: 30, height: 36)
                        .contentShape(Rectangle())
                }
            }

            divider

            // 墨色(点开调色盘)
            Button {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                    expanded.toggle()
                }
            } label: {
                Circle()
                    .fill(session.swatchColor)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 2))
                    .overlay(Circle().strokeBorder(DS.foreground1.opacity(0.12), lineWidth: 0.8))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("墨色")

            // 笔宽(三档循环,三条粗细线作指示)
            Button {
                session.cycleWidth()
            } label: {
                HStack(alignment: .center, spacing: 2.5) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(index == session.widthIndex ? DS.accent : DS.foreground3)
                            .frame(width: 2.5, height: CGFloat(7 + index * 4))
                    }
                }
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("笔宽")

            divider

            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DS.foreground2)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("撤销")

            Button(action: onRedo) {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DS.foreground2)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("重做")
        }
        .padding(.horizontal, DS.Space.x2s)
    }

    private func toolButton(_ tool: PencilToolKind) -> some View {
        let selected = session.kind == tool
        return Button {
            session.select(kind: tool)
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? DS.accent : DS.foreground2)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                        .fill(selected ? DS.accentContainer : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.label)
    }

    private var divider: some View {
        Rectangle()
            .fill(DS.foreground1.opacity(0.10))
            .frame(width: 1, height: 22)
    }

    // MARK: - 调色盘

    private var colorPanel: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(Array(session.swatches.enumerated()), id: \.offset) { pair in
                let index = pair.offset
                let color = pair.element
                let selected = session.kind == .marker
                    ? session.markerColorIndex == index
                    : session.colorIndex == index
                Button {
                    session.selectColor(index)
                } label: {
                    Circle()
                        .fill(Color(uiColor: color))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(DS.foreground1.opacity(0.10), lineWidth: 0.8))
                        .overlay(
                            Circle()
                                .strokeBorder(selected ? DS.accent : Color.clear, lineWidth: 2.5)
                                .padding(-3)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("颜色 \(index + 1)")
            }
        }
        .padding(.horizontal, DS.Space.x2s)
        .padding(.top, DS.Space.x4s)
    }
}
