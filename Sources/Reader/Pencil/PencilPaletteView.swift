import SwiftUI

/// v0.15.0:Notability 式**双列竖向工具托盘**(参照 references/assets/ui-tool-tray-colors-sizes.png):
/// - 左列:钢笔 / 铅笔 / 荧光笔 / 橡皮 | 撤销 / 重做 | 折叠;
/// - 右列:颜色网格(6 色 / 荧光 5 色)+ 5 档尺寸圆点 + 当前笔画预览;
/// - 橡皮选中时:右列切换为「局部 / 整笔」模式选择;
/// - 白色卡片、圆角 20、轻阴影;可拖动(位置记忆);长按工具图标可隐藏,「⋯」恢复。
struct PencilPaletteView: View {
    @ObservedObject var session: PencilToolSession
    var onUndo: () -> Void
    var onRedo: () -> Void

    @State private var expanded = true
    @State private var dragStart: CGPoint?
    @AppStorage("pencilPaletteX") private var offsetX: Double = 0
    @AppStorage("pencilPaletteY") private var offsetY: Double = 0

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            toolsColumn
            if expanded {
                dividerV
                styleColumn
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .padding(DS.Space.x2s)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.comfy, style: .continuous)
                .fill(DS.background3)
                .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 6)
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

    // MARK: - 左列:工具

    private var toolsColumn: some View {
        VStack(spacing: 2) {
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.foreground3)
                        .frame(width: 40, height: 36)
                        .contentShape(Rectangle())
                }
            }

            dividerH

            iconButton("arrow.uturn.backward", label: "撤销", action: onUndo)
            iconButton("arrow.uturn.forward", label: "重做", action: onRedo)

            dividerH

            Button {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                    expanded.toggle()
                }
            } label: {
                Image(systemName: expanded ? "chevron.left" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.foreground3)
                    .frame(width: 40, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "收起选项" : "展开选项")
        }
        .frame(width: 40)
    }

    private func toolButton(_ tool: PencilToolKind) -> some View {
        let selected = session.kind == tool
        return Button {
            session.select(kind: tool)
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(selected ? DS.accent : DS.foreground2)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                        .fill(selected ? DS.accentContainer : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.label)
    }

    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DS.foreground2)
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - 右列:颜色 / 尺寸 / 预览

    private var styleColumn: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            LazyVGrid(columns: [GridItem(.fixed(26), spacing: 8), GridItem(.fixed(26), spacing: 8)], spacing: 8) {
                ForEach(Array(session.swatches.enumerated()), id: \.offset) { pair in
                    colorDot(index: pair.offset, color: pair.element)
                }
            }

            dividerH

            if session.kind == .eraser {
                eraserModeRow
            } else {
                sizeDots
                strokePreview
            }
        }
        .padding(.leading, DS.Space.x2s)
        .padding(.vertical, DS.Space.x3s)
        .frame(width: 108, alignment: .leading)
    }

    private func colorDot(index: Int, color: UIColor) -> some View {
        let selected = session.kind == .marker
            ? session.markerColorIndex == index
            : session.colorIndex == index
        return Button {
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

    /// 5 档尺寸圆点(直径递增,选中有描边环)
    private var sizeDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { index in
                let selected = session.widthIndex == index
                let diameter = CGFloat(7 + index * 4)
                Button {
                    session.setWidth(index)
                } label: {
                    Circle()
                        .fill(selected ? DS.accent : DS.foreground4)
                        .frame(width: diameter, height: diameter)
                        .frame(width: 18, height: 22)
                        .overlay(
                            Circle()
                                .strokeBorder(selected ? DS.accent.opacity(0.35) : Color.clear, lineWidth: 2)
                                .frame(width: diameter + 6, height: diameter + 6)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("笔宽 \(index + 1)")
            }
        }
    }

    /// 当前笔画预览(颜色 + 粗细)
    private var strokePreview: some View {
        Canvas { context, size in
            var path = Path()
            let midY = size.height / 2
            path.move(to: CGPoint(x: 2, y: midY))
            path.addCurve(
                to: CGPoint(x: size.width - 2, y: midY),
                control1: CGPoint(x: size.width * 0.32, y: midY - 9),
                control2: CGPoint(x: size.width * 0.68, y: midY + 9)
            )
            let lineWidth = min(max(session.width * 0.9, 1.2), 8)
            context.stroke(
                path,
                with: .color(session.swatchColor),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
        }
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    /// 橡皮双模式:局部(bitmap)/ 整笔(vector)
    private var eraserModeRow: some View {
        HStack(spacing: 4) {
            eraserChip("局部", on: !session.eraserWhole) {
                if session.eraserWhole { session.toggleEraserWhole() }
            }
            eraserChip("整笔", on: session.eraserWhole) {
                if !session.eraserWhole { session.toggleEraserWhole() }
            }
        }
    }

    private func eraserChip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.Fonts.caption2)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(on ? DS.accentContainer : Color.clear, in: Capsule())
                .foregroundStyle(on ? DS.accent : DS.foreground2)
                .overlay(Capsule().strokeBorder(DS.foreground1.opacity(on ? 0 : 0.12), lineWidth: 0.8))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分隔线

    private var dividerV: some View {
        Rectangle()
            .fill(DS.foreground1.opacity(0.08))
            .frame(width: 1)
            .padding(.vertical, DS.Space.x3s)
    }

    private var dividerH: some View {
        Rectangle()
            .fill(DS.foreground1.opacity(0.08))
            .frame(width: 28, height: 1)
            .padding(.vertical, 3)
    }
}
