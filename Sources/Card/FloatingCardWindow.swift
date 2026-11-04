import SwiftUI
import Foundation
import UIKit

enum ReaderWindowGeometry {
    static func minimumWidth(height:CGFloat,allowsCompact:Bool) -> CGFloat {
        guard allowsCompact else { return 260 }
        // A narrow capsule must not jump by 80pt when its content switches at
        // 140pt. Broaden the reading measure continuously as height increases.
        let progress = min(1,max(0,(height-96)/124))
        return 180+80*progress
    }
}

/// 选区词卡可沿边拖动、从右下角缩放，并可缩成胶囊。
/// 移动和缩放使用全局坐标，窗口位置与大小分别持久化。
struct FloatingCardWindow: View {
    let content: ReaderCardContent
    let bounds: CGSize
    let onClose: () -> Void
    let onSelectWord: (String) -> Void
    var vocab: CardVocabBridge? = nil
    var translationRequest: SentenceTranslationRequest? = nil
    @StateObject private var sentenceTranslation = SentenceTranslationState()
    var body: some View {
        ReaderWindowSurface(bounds:bounds,onClose:onClose) {
            WordCardPanel(content:content,onClose:onClose,onSelectWord:onSelectWord,vocab:vocab)
                .environment(\.readerPanelClose, onClose)
                .environmentObject(sentenceTranslation)
        } compact: {
            CompactCardView(content:content,onClose:onClose,sentenceTranslation:sentenceTranslation.displayText)
        }
        .background {
            if let request = sentenceTranslation.currentRequest {
                if #available(iOS 18.0, *) {
                    SentenceTranslationTask(text:request.text,onResult:{ sentenceTranslation.finish($0, request:request) },
                                            onError:{ sentenceTranslation.fail($0, request:request) })
                        .id(request.id)
                }
            }
        }
        .onAppear { applyTranslationRequest(translationRequest) }
        .onChange(of:translationRequest) { _, request in applyTranslationRequest(request) }
        .onChange(of:content) { _, _ in
            sentenceTranslation.reset()
            applyTranslationRequest(translationRequest)
        }
    }
    private func applyTranslationRequest(_ request: SentenceTranslationRequest?) {
        guard let request, case .sentence(let text, _) = content, text == request.text else { return }
        sentenceTranslation.start(request)
    }
}

/// The identical shell, geometry and grip for words and reader functions.
struct ReaderWindowSurface<Expanded:View, Compact:View>: View {
    let bounds: CGSize
    let onClose: () -> Void
    var windowID = "word"
    var allowsCompact = true
    @ViewBuilder var expanded: () -> Expanded
    @ViewBuilder var compact: () -> Compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: CGPoint?
    @State private var size = CGSize(width: 320, height: 430)
    @State private var moveBase: CGPoint?
    @State private var resizeBase: CGSize?
    @State private var sizeBeforeCompact: CGSize?
    @GestureState private var moving = false
    private func storageKey(_ axis: String) -> String {
        windowID == "word" ? "readerCard" + axis : "readerWindow." + windowID + "." + axis
    }
    private func stored(_ axis: String) -> Double {
        (UserDefaults.standard.object(forKey: storageKey(axis)) as? Double) ?? -1
    }
    private var storedX: Double { stored("X") }
    private var storedY: Double { stored("Y") }
    private var storedW: Double { stored("W") }
    private var storedH: Double { stored("H") }

    /// 最小尺寸(可缩成胶囊)
    private var minSize: CGSize { CGSize(width: 180, height: allowsCompact ? 64 : 220) }
    /// 低于此高度切换为「胶囊迷你」布局
    private let compactThreshold: CGFloat = 140
    private var defaultSize: CGSize {
        windowID == "word" ? CGSize(width: 320, height: 430) : CGSize(width: 560, height: 600)
    }

    private var isCompact: Bool { allowsCompact && size.height < compactThreshold }
    /// 形状(v0.6.5):迷你态=真胶囊(半径=高/2);完整态=圆角矩形(30);120–160pt 之间连续过渡。
    private var cornerRadius: CGFloat {
        let capsule = size.height / 2
        guard size.height > 120 else { return capsule }
        let t = min(max((size.height - 120) / 40, 0), 1)
        return capsule * (1 - t) + 30 * t
    }

    var body: some View {
        ZStack {
            fullBody.opacity(isCompact ? 0 : 1).allowsHitTesting(!isCompact).accessibilityHidden(isCompact)
            compactBody.opacity(isCompact ? 1 : 0).allowsHitTesting(isCompact).accessibilityHidden(!isCompact)
        }
        .frame(width: size.width, height: size.height)
        .background(DS.background3)   // v0.14.1:纸感卡面(替换毛玻璃材质)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // v0.8.0:整窗触摸判定 = 窗口形状——形状之外一律不拦截(交给下层 PDF),杜绝"摸到窗口外的空气也能拖动"
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay { edgeDragAreas }
        .overlay {
            // v0.6.7:白色缩放手柄 = 窗口右下边缘的一段弧(半径随圆角连续变化,始终贴合)
            CornerGripArc(cornerRadius: cornerRadius)
                .stroke(
                    Color.white.opacity(resizeActive ? 1.0 : 0.9),
                    style: StrokeStyle(lineWidth: resizeActive ? 4.5 : 3.5, lineCap: .round)
                )
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                .animation(reduceMotion ? nil : DS.Motion.spring, value: resizeActive)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) { resizeHitArea }
        .overlay(alignment: .topTrailing) {
            Button(action:onClose) {
                Image(systemName:"xmark")
                    .font(.system(size:16, weight:.medium))
                    .foregroundStyle(DS.foreground2)
                    .frame(width:44,height:44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭窗口")
            .padding(.trailing,isCompact ? gripZone : 0)
        }
        .background(DSReliefSurface(radius: cornerRadius))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .offset(x: currentPosition.x, y: currentPosition.y)
        .onAppear {
            if storedW >= minSize.width, storedH >= 0 {
                size = CGSize(width: storedW, height: max(storedH, minSize.height))
            } else {
                size = defaultSize
            }
            size = clampedSize(size)
            if position == nil {
                position = currentPosition
            }
        }
        .onChange(of:moving) { _,active in if !active { moveBase = nil; persist() } }
        .onChange(of: bounds) { _, _ in
            size = clampedSize(size)
            if let p = position {
                position = clampedPosition(p)
            }
        }
    }

    // MARK: - 完整词卡

    private var fullBody: some View {
        expanded().frame(width:size.width,height:size.height,alignment:.topLeading)
    }

    private var edgeDragAreas: some View {
        let edge: CGFloat = 16
        return ZStack {
            VStack(spacing:0) {
                Color.clear.frame(height:edge).contentShape(Rectangle()).gesture(moveGesture)
                Spacer(minLength:0)
                Color.clear.frame(height:edge).contentShape(Rectangle()).gesture(moveGesture)
            }
            HStack(spacing:0) {
                Color.clear.frame(width:edge).contentShape(Rectangle()).gesture(moveGesture)
                Spacer(minLength:0)
                Color.clear.frame(width:edge).contentShape(Rectangle()).gesture(moveGesture)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - 胶囊迷你

    private var compactBody: some View {
        compact()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // v0.6.9:触摸判定 = 胶囊形状本身(每时每刻随圆角变化,形状之外不拦截触摸)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onTapGesture(count: 2) { toggleCompact() }
            .simultaneousGesture(moveGesture)
    }

    private var moveGesture: some Gesture {
        // v0.10.0:同样改为"起手位置 + 总位移"——不做逐帧增量,坐标系重置也不会跳。
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .updating($moving) { _,state,_ in state = true }
            .onChanged { value in
                if moveBase == nil {
                    moveBase = currentPosition
                }
                guard let base = moveBase else { return }
                position = clampedPosition(CGPoint(
                    x: base.x + value.translation.width,
                    y: base.y + value.translation.height
                ))
            }
            .onEnded { _ in
                moveBase = nil
                persist()
            }
    }

    // MARK: - 缩放手柄(右下角,像原生窗口)

    /// Persistent 44pt UIKit target; the compact body cannot replace or cancel it.
    private var resizeHitArea: some View {
        WindowResizeGrip(onChanged: { translation in
            if resizeBase == nil { resizeBase = size }
            guard let base = resizeBase else { return }
            // Keep the top-left fixed while the grip follows the pointer. Moving
            // the window to fit the enlarged size changes the drag's own origin.
            let origin = position ?? currentPosition
            let candidate = clampedSize(CGSize(width:base.width+translation.width,height:base.height+translation.height))
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                size = CGSize(width:min(candidate.width,max(minSize.width,bounds.width-origin.x-8)),
                              height:min(candidate.height,max(minSize.height,bounds.height-origin.y-8)))
            }
        }, onEnded: {
            resizeBase = nil; persist()
        })
            .frame(width: gripZone, height: gripZone)
            .accessibilityLabel("调整窗口大小")
    }

    /// 缩放拖拽(v0.10.0):以**手势开始时的尺寸**为基准 + 手势**总位移**(translation)计算——
    /// 严禁逐帧增量累加,坐标系重置/事件冒泡都不会再产生"瞬移"。
    private var resizeActive: Bool { resizeBase != nil }

    /// 缩放手柄最小热区(≥44×44,人机指南;v0.10.0 Bug 1.1)
    private let gripZone: CGFloat = 44

    // MARK: - 迷你/展开切换(双击胶囊)

    private func toggleCompact() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86)) {
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
            width:min(max(value.width,ReaderWindowGeometry.minimumWidth(height:value.height,allowsCompact:allowsCompact)),maxW),
            height: min(max(value.height, minSize.height), maxH)
        )
    }

    private func persist() {
        UserDefaults.standard.set(Double(currentPosition.x), forKey: storageKey("X"))
        UserDefaults.standard.set(Double(currentPosition.y), forKey: storageKey("Y"))
        UserDefaults.standard.set(Double(size.width), forKey: storageKey("W"))
        UserDefaults.standard.set(Double(size.height), forKey: storageKey("H"))
    }
}

/// A persistent UIKit recognizer retains the same touch across capsule/card
/// layout thresholds and when the pointer travels beyond the moving 44pt grip.
struct WindowResizeGrip: UIViewRepresentable {
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void
    func makeUIView(context:Context) -> WindowResizeGripView { WindowResizeGripView() }
    func updateUIView(_ view:WindowResizeGripView,context:Context) {
        view.onChanged = onChanged; view.onEnded = onEnded
    }
}
final class WindowResizeGripView: UIView {
    var onChanged: ((CGSize)->Void)?
    var onEnded: (()->Void)?
    override init(frame:CGRect) {
        super.init(frame:frame)
        backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target:self,action:#selector(drag(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        accessibilityIdentifier = "window-resize-grip"
        isAccessibilityElement = true
        accessibilityLabel = "调整窗口大小"
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc private func drag(_ pan:UIPanGestureRecognizer) {
        let delta = pan.translation(in:window)
        switch pan.state {
        case .began,.changed: onChanged?(CGSize(width:delta.x,height:delta.y))
        case .ended: onChanged?(CGSize(width:delta.x,height:delta.y)); onEnded?()
        case .cancelled,.failed: onEnded?()
        default: break
        }
    }
}

/// 窗口右下角的白色缩放手柄弧条(v0.6.7):**造型即窗口边缘的一段**——
/// 沿右下圆角画一段弧,半径随窗口圆角连续变化(胶囊态半圆、矩形态圆角),始终贴合边缘。
struct CornerGripArc: Shape {
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

/// v0.6.9 的 `CornerHitShape`(形状∩弧线裁剪)已废弃——v0.10.0 起命中区改为 44×44 实心方块,
/// 不做形状裁剪(手指抓得住的优先级 > "形状之外不拦截")。
