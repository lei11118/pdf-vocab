import SwiftUI
import UIKit

/// v0.16.0:Notability 式**悬浮书写工具条**。
///
/// 设计原则:
/// - 默认只占一条胶囊的高度,尽量不挡纸面;点右侧 chevron 才展开颜色与笔宽;
/// - 工具“选中即写”,笔/铅笔/荧光笔/套索/橡皮一目了然;
/// - 颜色、五档笔宽、笔画预览都放在展开层,避免长期占据画布;
/// - 橡皮局部/整笔、用完自动回笔,均是 Notability 的手写辅助细节。
struct PencilPaletteView: View {
    @ObservedObject var session: PencilToolSession
    var onUndo: () -> Void
    var onRedo: () -> Void
    /// v0.16.0:从书写回到选词阅读;nil 时不显示退出入口。
    var onExitWriting: (() -> Void)? = nil
    /// v0.24.0:工具条自由拖动 —— 按住左侧握把拖动(位移在屏幕坐标系里算,避免跟手回环)。
    var onDockDragChanged: ((CGSize) -> Void)? = nil
    var onDockDragEnded: (() -> Void)? = nil
    var onDockReset: (() -> Void)? = nil

    @State private var expanded = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: DS.Space.xs) {
            if expanded {
                stylePanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            compactBar
        }
        .animation(DS.Motion.spring, value: expanded)
        .accessibilityElement(children: .contain)
    }

    // MARK: - 常驻胶囊

    private var compactBar: some View {
        // v0.16.1:去掉 ViewThatFits(测量不确定,曾怀疑与选工具卡死有关);
        // 常规宽度直接用 HStack 收成一颗胶囊,窄分屏(compact)才横向滚动。
        // v0.24.0:左侧多一个握把(拖它移动整条工具带),握把不参与横向滚动。
        HStack(spacing: 0) {
            if let dragChanged = onDockDragChanged {
                dockGrip(onChanged: dragChanged)
            }
            Group {
                if sizeClass == .compact {
                    ScrollView(.horizontal, showsIndicators: false) {
                        barContent
                    }
                } else {
                    barContent
                }
            }
        }
        .dsFloatingPanel(radius: DS.Radius.pill)
    }

    /// v0.24.0:拖动握把 —— 长按/拖动移动工具条,双击复位到底部居中。
    private func dockGrip(onChanged: @escaping (CGSize) -> Void) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(DS.foreground4)
            .frame(width: 26, height: 38)
            .contentShape(Rectangle())
            .padding(.leading, DS.Space.x3s)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in onChanged(value.translation) }
                    .onEnded { _ in onDockDragEnded?() }
            )
            .onTapGesture(count: 2) { onDockReset?() }
            .accessibilityLabel("拖动工具条(双击复位)")
    }

    private var barContent: some View {
        HStack(spacing: 2) {
            ForEach(session.visibleKinds) { tool in
                toolButton(tool)
            }

            rulerButton

            divider

            Button {
                DiagLog.log("palette: expand -> \(!expanded)")
                withAnimation(DS.Motion.spring) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(session.kind == .eraser ? DS.foreground3 : session.swatchColor)
                        .frame(width: 13, height: 13)
                        .overlay(Circle().strokeBorder(DS.foreground1.opacity(0.12), lineWidth: 0.7))
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.foreground3)
                }
                .frame(width: 48, height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(DSPressableButtonStyle())
            .accessibilityLabel(expanded ? "收起笔刷选项" : "展开颜色与笔宽")

            divider

            if let onExitWriting {
                compactIcon("text.cursor", label: "回到选词阅读", action: onExitWriting)
                divider
            }

            compactIcon("arrow.uturn.backward", label: "撤销", action: onUndo)
            compactIcon("arrow.uturn.forward", label: "重做", action: onRedo)
        }
        .padding(.horizontal, DS.Space.x3s)
        .padding(.vertical, 5)
    }

    private var divider: some View {
        Rectangle()
            .fill(DS.foreground1.opacity(0.08))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 3)
    }

    private func toolButton(_ tool: PencilToolKind) -> some View {
        let selected = session.kind == tool
        return Button {
            DiagLog.log("palette: tap tool=\(tool.rawValue) selected=\(selected)")
            if selected {
                // Notability:点当前工具 = 展开/收起风格托盘;点其他工具 = 立即切换去写。
                withAnimation(DS.Motion.spring) { expanded.toggle() }
            } else {
                session.select(kind: tool)
                withAnimation(DS.Motion.spring) { expanded = false }
            }
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(selected ? DS.accent : DS.foreground2)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                        .fill(selected ? DS.accentContainer : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(DSPressableButtonStyle())
        .contextMenu {
            if session.visibleKinds.count > 1 {
                Button(role: .destructive) {
                    session.hide(tool)
                } label: {
                    Label("隐藏\(tool.label)", systemImage: "eye.slash")
                }
            }
        }
        .accessibilityLabel(tool.label)
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
    }

    private var rulerButton: some View {
        Button {
            DiagLog.log("palette: ruler -> \(!session.rulerActive)")
            session.toggleRuler()
        } label: {
            Image(systemName: "ruler")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(session.rulerActive ? DS.accent : DS.foreground2)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                        .fill(session.rulerActive ? DS.accentContainer : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(DSPressableButtonStyle())
        .accessibilityLabel(session.rulerActive ? "关闭直尺" : "打开直尺")
        .accessibilityAddTraits(session.rulerActive ? .isSelected : AccessibilityTraits())
    }

    private func compactIcon(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.foreground2)
                .frame(width: 34, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(DSPressableButtonStyle())
        .accessibilityLabel(label)
    }

    // MARK: - 展开层

    private var stylePanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            header

            switch session.kind {
            case .eraser:
                eraserPanel
            case .lasso:
                lassoPanel
            case .shape:
                shapePanel
            case .laser:
                laserPanel
            case .calligraphy:
                calligraphyPanel
            case .pen, .pencil, .marker, .crayon:
                inkPanel
            }

            if session.rulerActive {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "ruler")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("直尺已开启")
                            .font(DS.Fonts.caption)
                            .foregroundStyle(DS.foreground1)
                        Text("拖动直尺对准边缘,沿尺边画直线;再点尺子关闭。")
                            .font(DS.Fonts.micro)
                            .foregroundStyle(DS.foreground3)
                    }
                    Spacer(minLength: 0)
                    Button("关闭") { session.rulerActive = false }
                        .font(DS.Fonts.caption2)
                        .foregroundStyle(DS.accent)
                }
                .padding(DS.Space.xs)
                .background(DS.background1, in: RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
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
                    Label("已隐藏 \(session.hiddenKinds.count) 个工具", systemImage: "eye.slash")
                        .font(DS.Fonts.caption2)
                        .foregroundStyle(DS.foreground3)
                }
            }
        }
        .padding(DS.Space.s)
        .frame(width: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.comfy, style: .continuous)
                .fill(DS.background2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.comfy, style: .continuous)
                .strokeBorder(DS.foreground1.opacity(0.08), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.13), radius: 20, x: 0, y: 10)
    }

    private var header: some View {
        HStack(spacing: DS.Space.xs) {
            Text(session.kind.label)
                .font(DS.Fonts.headline)
                .foregroundStyle(DS.foreground1)
            Text(headerHint)
                .font(DS.Fonts.caption2)
                .foregroundStyle(DS.foreground3)
            Spacer(minLength: 0)
        }
    }

    private var headerHint: String {
        switch session.kind {
        case .pen, .pencil: return "颜色 · 笔宽"
        case .calligraphy: return "笔锋角度 · 稳定化"
        case .marker: return "半透明 · 五档宽度"
        case .crayon: return "蜡质纹理 · 五档宽度"
        case .eraser: return session.eraserWhole ? "整笔擦除" : "局部擦除"
        case .lasso: return "圈选后可移动 / 删除"
        case .shape: return "拖动生成规整图形"
        case .laser: return "不落墨 · 抬手淡出"
        }
    }

    private var inkPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.xs) {
                ForEach(Array(session.swatches.enumerated()), id: \.offset) { pair in
                    colorDot(index: pair.offset, color: pair.element)
                }
                Spacer(minLength: 0)
            }

            // v0.17.0:任意取色(Notability 的取色器);选中后 colorIndex = -1
            HStack(spacing: DS.Space.xs) {
                ColorPicker("", selection: customColorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 28, height: 28)
                Text(session.kind == .marker ? "自定义荧光色" : "自定义墨色")
                    .font(DS.Fonts.micro)
                    .foregroundStyle(DS.foreground3)
                Spacer(minLength: 0)
            }

            HStack(spacing: DS.Space.s) {
                sizeDots
                Spacer(minLength: 0)
                strokePreview
                    .frame(width: 92)
            }
        }
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(uiColor: session.kind == .marker ? session.customMarkerColor : session.customInkColor)
            },
            set: { session.setCustomColor($0) }
        )
    }

    private var eraserPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.xs) {
                modeChip("局部", detail: "擦过即断", on: !session.eraserWhole) {
                    if session.eraserWhole { session.toggleEraserWhole() }
                }
                modeChip("整笔", detail: "整条消失", on: session.eraserWhole) {
                    if !session.eraserWhole { session.toggleEraserWhole() }
                }
            }

            // v0.22.0:自研橡皮大小(五档)
            HStack(spacing: DS.Space.xs) {
                Text("大小")
                    .font(DS.Fonts.caption2)
                    .foregroundStyle(DS.foreground3)
                HStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { index in
                        let selected = session.eraserSizeIndex == index
                        let diameter = CGFloat(6 + index * 4)
                        Button {
                            session.setEraserSize(index)
                        } label: {
                            Circle()
                                .fill(selected ? DS.accent : DS.foreground4)
                                .frame(width: diameter, height: diameter)
                                .frame(width: 24, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(DSPressableButtonStyle())
                        .accessibilityLabel("橡皮大小 \(index + 1)")
                        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
                    }
                }
                Spacer(minLength: 0)
                Text("\(Int(session.eraserRadius)) pt")
                    .font(DS.Fonts.micro.monospacedDigit())
                    .foregroundStyle(DS.foreground3)
            }

            Toggle(isOn: $session.useCustomEraser) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("可调大小(自研橡皮)")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(DS.foreground1)
                    Text("关掉则用系统橡皮,圆圈会随高清画布变小")
                        .font(DS.Fonts.micro)
                        .foregroundStyle(DS.foreground3)
                }
            }
            .tint(DS.accent)
        }
    }

    /// v0.23.0:形状工具 —— 选形状 + 颜色/笔宽
    private var shapePanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: 4) {
                ForEach(PencilShapeKind.allCases) { shape in
                    let selected = session.shapeKind == shape
                    Button {
                        session.shapeKind = shape
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: shape.systemImage)
                                .font(.system(size: 14, weight: .semibold))
                            Text(shape.label)
                                .font(DS.Fonts.micro)
                        }
                        .foregroundStyle(selected ? DS.accent : DS.foreground2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                                .fill(selected ? DS.accentContainer : DS.background1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(DSPressableButtonStyle())
                    .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
                }
            }
            inkPanel
        }
    }

    /// v0.24.0:书法笔 —— 笔锋角度(横细竖粗)+ 稳定化 + 墨色/笔宽
    private var calligraphyPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.x2s) {
                Text("笔锋")
                    .font(DS.Fonts.caption2)
                    .foregroundStyle(DS.foreground3)
                ForEach(0..<PencilToolSession.nibAngles.count, id: \.self) { index in
                    let selected = session.nibAngleIndex == index
                    let degrees = PencilToolSession.nibAngles[index]
                    Button {
                        session.nibAngleIndex = index
                    } label: {
                        Image(systemName: "pencil.tip")
                            .font(.system(size: 15, weight: .semibold))
                            .rotationEffect(.degrees(Double(degrees)))
                            .foregroundStyle(selected ? DS.accent : DS.foreground2)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.sharp, style: .continuous)
                                    .fill(selected ? DS.accentContainer : DS.background1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(DSPressableButtonStyle())
                    .accessibilityLabel("笔锋 \(Int(degrees)) 度")
                    .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
                }
                Spacer(minLength: 0)
                Text("\(Int(session.nibAngle))°")
                    .font(DS.Fonts.micro.monospacedDigit())
                    .foregroundStyle(DS.foreground3)
            }

            nibPreview
                .frame(height: 30)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            Toggle(isOn: $session.calligraphySmoothing) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("稳定化")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(DS.foreground1)
                    Text("收敛手抖,写字更顺;关掉更贴笔尖")
                        .font(DS.Fonts.micro)
                        .foregroundStyle(DS.foreground3)
                }
            }
            .tint(DS.accent)

            inkPanel
        }
    }

    /// 笔锋预览:同一个正弦路径,按当前角度算"横细竖粗",和真笔一致。
    private var nibPreview: some View {
        Canvas { context, size in
            let nib = Double(session.nibAngle) * .pi / 180
            let steps = 56
            var prev = CGPoint(x: 4, y: size.height * 0.5)
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let x = 4 + (size.width - 8) * t
                let y = Double(size.height) * 0.5 + sin(Double(t) * .pi * 2) * Double(size.height) * 0.28
                let point = CGPoint(x: x, y: CGFloat(y))
                let theta = atan2(Double(point.y - prev.y), Double(point.x - prev.x))
                let chisel = CGFloat(abs(sin(theta - nib)))
                let lineWidth = 1.2 + 4.6 * chisel
                var path = Path()
                path.move(to: prev)
                path.addLine(to: point)
                context.stroke(
                    path,
                    with: .color(session.swatchColor.opacity(0.86)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
                prev = point
            }
        }
    }

    /// v0.23.0:激光笔说明(不留墨,不需要颜色/宽度)
    private var laserPanel: some View {
        Text("激光笔不落墨:走过的轨迹是红色光点,抬手后自动淡出。适合讲解时指示,不会写进笔记。")
            .font(DS.Fonts.caption2)
            .foregroundStyle(DS.foreground2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var lassoPanel: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "lasso")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DS.accent)
                .frame(width: 46, height: 46)
                .background(DS.accentContainer, in: RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("圈住笔迹再拖动")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.foreground1)
                Text("选中后可整体移动、缩放或按删除键清除。")
                    .font(DS.Fonts.micro)
                    .foregroundStyle(DS.foreground3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                .frame(width: 25, height: 25)
                .overlay(Circle().strokeBorder(DS.foreground1.opacity(0.12), lineWidth: 0.8))
                .overlay(
                    Circle()
                        .strokeBorder(selected ? DS.accent : Color.clear, lineWidth: 2.4)
                        .padding(-3)
                )
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(DSPressableButtonStyle())
        .accessibilityLabel("颜色 \(index + 1)")
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
    }

    private var sizeDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<5, id: \.self) { index in
                let selected = session.widthIndex == index
                let diameter = CGFloat(5 + index * 3)
                Button {
                    session.setWidth(index)
                } label: {
                    Circle()
                        .fill(selected ? DS.accent : DS.foreground4)
                        .frame(width: diameter, height: diameter)
                        .frame(width: 24, height: 30)
                        .overlay(
                            Circle()
                                .strokeBorder(selected ? DS.accent.opacity(0.26) : Color.clear, lineWidth: 2)
                                .frame(width: diameter + 6, height: diameter + 6)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(DSPressableButtonStyle())
                .accessibilityLabel("笔宽 \(index + 1)")
                .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
            }
        }
    }

    private var strokePreview: some View {
        Canvas { context, size in
            var path = Path()
            let midY = size.height / 2
            path.move(to: CGPoint(x: 3, y: midY + 3))
            path.addCurve(
                to: CGPoint(x: size.width - 3, y: midY - 3),
                control1: CGPoint(x: size.width * 0.30, y: midY - 11),
                control2: CGPoint(x: size.width * 0.68, y: midY + 10)
            )
            let lineWidth = min(max(session.width * 0.82, 1.2), 10)
            context.stroke(
                path,
                with: .color(session.swatchColor.opacity(session.kind == .marker ? 0.62 : 1)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }

    private func modeChip(
        _ title: String,
        detail: String,
        on: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DS.Fonts.caption)
                Text(detail)
                    .font(DS.Fonts.micro)
                    .opacity(0.72)
            }
            .foregroundStyle(on ? DS.accent : DS.foreground2)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                    .fill(on ? DS.accentContainer : DS.background1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                    .strokeBorder(on ? DS.accent.opacity(0.20) : DS.foreground1.opacity(0.06), lineWidth: 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(DSPressableButtonStyle())
    }
}
