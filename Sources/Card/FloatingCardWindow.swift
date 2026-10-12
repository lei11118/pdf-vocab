import SwiftUI

/// 悬浮词卡窗口(v0.6.1 引入,v0.6.2 增加缩放;用户要求"像 iPad 原生窗口"):
/// - 按住顶部拖条**自由拖动**;右下角手柄**自由改变大小**;
/// - 位置与尺寸持久化(@AppStorage),重开仍在原处;
/// - 点 × 才关闭;始终约束在阅读区内(最小 240×220,四周留 8pt,防出屏);
/// - 拖动/缩放都用**全局坐标**(局部坐标会随窗口移动产生反馈抖动——"抽风"修复);
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
    @AppStorage("readerCardX") private var storedX: Double = -1
    @AppStorage("readerCardY") private var storedY: Double = -1
    @AppStorage("readerCardW") private var storedW: Double = -1
    @AppStorage("readerCardH") private var storedH: Double = -1

    private let minSize = CGSize(width: 240, height: 220)

    var body: some View {
        VStack(spacing: 0) {
            dragStrip
            Divider()
            WordCardPanel(content: content, onClose: onClose, onSelectWord: onSelectWord)
        }
        .frame(width: size.width, height: size.height)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .overlay(alignment: .bottomTrailing) { resizeGrip }
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

    // MARK: - 拖动条(移动窗口)

    private var dragStrip: some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .contentShape(Rectangle())
        .gesture(
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
        )
    }

    // MARK: - 缩放手柄(右下角,像原生窗口)

    private var resizeGrip: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 34)
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
