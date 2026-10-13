import SwiftUI
import Foundation

/// 悬浮词卡窗口(v0.6.1 引入;v0.6.2 缩放;v0.6.4 胶囊形态 + 迷你模式;用户要求"像 iPad 原生窗口"):
/// - 按住顶部拖条**自由拖动**;右下角手柄**自由改变大小**;
/// - **缩到最小时变成胶囊**:横排显示「单词 + 声音 + 翻译」基本信息(双击胶囊可切换迷你/完整);
/// - 位置与尺寸持久化(@AppStorage);
/// - **点空白清选区时随选区一起消失**(v0.6.4 用户要求);点 × 关闭;
/// - 形状:连续圆角 min(30, 高/2)——迷你时即标准胶囊;
/// - 拖动/缩放都用**全局坐标**(局部坐标会随窗口移动产生反馈抖动);
/// - 独立成视图:拖动/缩放只重绘窗口自身,不再牵动整页 PDF。
struct FloatingCardWindow: View {
    let content: ReaderCardContent
    let bounds: CGSize
    let onClose: () -> Void
    let onSelectWord: (String) -> Void

    @State private var position: CGPoint?
    @State private var size = CGSize(width: 320, height: 430)
    @State private var moveBase: CGPoint?
    @State private var moveStart: CGPoint?
    @State private var resizeBase: CGSize?
    @State private var resizeStart: CGPoint?
    @State private var sizeBeforeCompact: CGSize?
    @AppStorage("readerCardX") private var storedX: Double = -1
    @AppStorage("readerCardY") private var storedY: Double = -1
    @AppStorage("readerCardW") private var storedW: Double = -1
    @AppStorage("readerCardH") private var storedH: Double = -1

    /// 最小尺寸(可缩成胶囊)
    private let minSize = CGSize(width: 180, height: 48)
    /// 低于此高度切换为「胶囊迷你」布局
    private let compactThreshold: CGFloat = 140
    private let defaultSize = CGSize(width: 320, height: 430)

    private var isCompact: Bool { size.height < compactThreshold }
    /// 形状(v0.6.5):迷你态=真胶囊(半径=高/2);完整态=圆角矩形(30);120–160pt 之间连续过渡。
    private var cornerRadius: CGFloat {
        let capsule = size.height / 2
        guard size.height > 120 else { return capsule }
        let t = min(max((size.height - 120) / 40, 0), 1)
        return capsule * (1 - t) + 30 * t
    }

    var body: some View {
        ZStack {
            fullBody
                .opacity(isCompact ? 0 : 1)
                .allowsHitTesting(!isCompact)
            compactBody
                .opacity(isCompact ? 1 : 0)
                .allowsHitTesting(isCompact)
        }
        .animation(.easeInOut(duration: 0.25), value: isCompact)
        .frame(width: size.width, height: size.height)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .overlay {
            // v0.6.7:白色缩放手柄 = 窗口右下边缘的一段弧(半径随圆角连续变化,始终贴合)
            CornerGripArc(cornerRadius: cornerRadius)
                .stroke(
                    Color.white.opacity(resizeActive ? 1.0 : 0.9),
                    style: StrokeStyle(lineWidth: resizeActive ? 4.5 : 3.5, lineCap: .round)
                )
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: resizeActive)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) { resizeHitArea }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .offset(x: currentPosition.x, y: currentPosition.y)
        .onAppear {
            if storedW >= minSize.width, storedH >= minSize.height {
                size = CGSize(width: storedW, height: storedH)
            }
            size = clampedSize(size)
            if position == nil {
                position = currentPosition
            }
        }
        .onChange(of: bounds) { _, _ in
            size = clampedSize(size)
            if let p = position {
                position = clampedPosition(p)
            }
        }
    }

    // MARK: - 完整词卡

    private var fullBody: some View {
        VStack(spacing: 0) {
            dragStrip
            Divider()
            WordCardPanel(content: content, onClose: onClose, onSelectWord: onSelectWord)
        }
    }

    private var dragStrip: some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .contentShape(Rectangle())
        .gesture(moveGesture)
    }

    // MARK: - 胶囊迷你(单词 + 声音 + 翻译,横着排)

    private var compactBody: some View {
        CompactCardView(content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(moveGesture)
            .onTapGesture(count: 2) { toggleCompact() }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if moveBase == nil {
                    moveBase = currentPosition
                    moveStart = value.location
                }
                guard let base = moveBase, let start = moveStart else { return }
                position = clampedPosition(CGPoint(
                    x: base.x + value.location.x - start.x,
                    y: base.y + value.location.y - start.y
                ))
            }
            .onEnded { _ in
                moveBase = nil
                moveStart = nil
                persist()
            }
    }

    // MARK: - 缩放手柄(右下角,像原生窗口)

    /// 命中区(v0.6.7):右下角透明正方形;视觉由沿边缘的白色弧条 `CornerGripArc` 提供。
    private var resizeHitArea: some View {
        Color.clear
            .frame(width: gripSide, height: gripSide)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if resizeBase == nil {
                            resizeBase = size
                            resizeStart = value.location
                        }
                        guard let base = resizeBase, let start = resizeStart else { return }
                        size = clampedSize(CGSize(
                            width: base.width + value.location.x - start.x,
                            height: base.height + value.location.y - start.y
                        ))
                        if let p = position {
                            position = clampedPosition(p)
                        }
                    }
                    .onEnded { _ in
                        resizeBase = nil
                        resizeStart = nil
                        persist()
                    }
            )
    }

    private var resizeActive: Bool { resizeBase != nil }

    private let gripSide: CGFloat = 32

    // MARK: - 迷你/展开切换(双击胶囊)

    private func toggleCompact() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            if isCompact {
                size = clampedSize(sizeBeforeCompact ?? defaultSize)
                sizeBeforeCompact = nil
            } else {
                sizeBeforeCompact = size
                size = clampedSize(CGSize(width: size.width, height: minSize.height))
            }
            if let p = position {
                position = clampedPosition(p)
            }
        }
        persist()
    }

    // MARK: - 几何约束与持久化

    private var currentPosition: CGPoint {
        if let position {
            return clampedPosition(position)
        }
        if storedX >= 0, storedY >= 0 {
            return clampedPosition(CGPoint(x: storedX, y: storedY))
        }
        return clampedPosition(CGPoint(x: bounds.width - size.width - 16, y: 16))
    }

    private func clampedPosition(_ point: CGPoint) -> CGPoint {
        let maxX = max(8, bounds.width - size.width - 8)
        let maxY = max(8, bounds.height - size.height - 8)
        return CGPoint(x: min(max(point.x, 8), maxX), y: min(max(point.y, 8), maxY))
    }

    private func clampedSize(_ value: CGSize) -> CGSize {
        let maxW = max(minSize.width, bounds.width - 16)
        let maxH = max(minSize.height, bounds.height - 16)
        return CGSize(
            width: min(max(value.width, minSize.width), maxW),
            height: min(max(value.height, minSize.height), maxH)
        )
    }

    private func persist() {
        storedX = Double(currentPosition.x)
        storedY = Double(currentPosition.y)
        storedW = Double(size.width)
        storedH = Double(size.height)
    }
}

/// 窗口右下角的白色缩放手柄弧条(v0.6.7):**造型即窗口边缘的一段**——
/// 沿右下圆角画一段弧,半径随窗口圆角连续变化(胶囊态半圆、矩形态圆角),始终贴合边缘。
private struct CornerGripArc: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 24
        let startDeg = 14.0
        let endDeg = 76.0
        let r = max(cornerRadius - 2, 2)
        guard rect.width > cornerRadius + 6, rect.height > cornerRadius + 6 else { return path }
        let center = CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius)
        for i in 0...steps {
            let deg = startDeg + (endDeg - startDeg) * Double(i) / Double(steps)
            let a = deg * .pi / 180
            let point = CGPoint(
                x: center.x + r * CGFloat(cos(a)),
                y: center.y + r * CGFloat(sin(a))
            )
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}
