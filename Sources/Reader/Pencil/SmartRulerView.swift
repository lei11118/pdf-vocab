import UIKit
import PencilKit

/// v0.38.0:智能物理直尺(自研)。
///
/// 为什么自研:PencilKit 只公开 `PKCanvasView.isRulerActive`,**没有设置位置/角度的 API**
/// (Apple 文档与社区一致),它自带直尺活在画布坐标系里、会跟着页面滚。
///
/// 本实现把尺子做成一个**视口坐标里的窄条视图**(长 × 26pt):
/// - 位置/角度由用户拖动与双指旋转决定,滚动 PDF 不受影响(它不在画布坐标里);
/// - 关闭再开启才回到屏幕中心并归零角度;
/// - 命中区就是这条尺身,尺子以外的手指全部穿透给 PDFView。
final class SmartRulerView: UIView {

    // MARK: 配置

    /// 吸附目标(度)
    static let snapTargetsDegrees: [Double] = [0, 30, 45, 60, 90, 120, 135, 180]
    /// 吸附阈值(度)
    static let snapToleranceDegrees: Double = 3
    /// 尺身厚度
    static let barHeight: CGFloat = 26

    /// 是否显示
    var isOn: Bool = false {
        didSet {
            guard isOn != oldValue else { return }
            isHidden = !isOn
            if isOn { setNeedsDisplay() }
            DiagLog.log("ruler: \(isOn ? "on" : "off") angle=\(Int(angleDegrees))")
        }
    }

    /// 角度(弧度,归一化到 [0, π))
    private(set) var angle: CGFloat = 0
    /// 角度(度,只读,便于日志/调试)
    var angleDegrees: Double { Double(angle) * 180 / .pi }

    /// 尺身长度(视口点)
    let rulerLength: CGFloat

    private weak var hostView: UIView?
    private let impact = UIImpactFeedbackGenerator(style: .rigid)
    private var dragStartCenter: CGPoint?
    private var rotationStartAngle: CGFloat?

    // MARK: 初始化

    init(length: CGFloat, host: UIView) {
        self.rulerLength = max(160, length)
        self.hostView = host
        super.init(frame: CGRect(x: 0, y: 0, width: rulerLength, height: Self.barHeight))
        backgroundColor = .clear
        isOpaque = false
        isHidden = true
        isUserInteractionEnabled = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        // 只收手指:Pencil 落在尺子上也应该继续写字,不能被尺子抢走
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(pan)

        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        rotate.delegate = self
        rotate.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(rotate)

        pan.delegate = self
        cameraCenterToHost()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: 位置 / 开关

    /// 回到屏幕正中、角度归零(只有"关闭再开启"才会调用)
    func resetInHost() {
        cameraCenterToHost()
        angle = 0
        transform = .identity
        setNeedsDisplay()
    }

    private func cameraCenterToHost() {
        guard let host = hostView else { return }
        center = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
    }

    // MARK: 几何

    /// 尺子两端点(父视图坐标)
    func linePoints() -> (CGPoint, CGPoint) {
        let half = rulerLength / 2
        let dx = cos(angle) * half
        let dy = sin(angle) * half
        return (CGPoint(x: center.x - dx, y: center.y - dy),
                CGPoint(x: center.x + dx, y: center.y + dy))
    }

    /// 点到尺线的垂直距离(父视图坐标)
    func distanceToLine(from point: CGPoint) -> CGFloat {
        let (a, b) = linePoints()
        let vx = b.x - a.x, vy = b.y - a.y
        let len = hypot(vx, vy)
        guard len > 0.0001 else { return .greatestFiniteMagnitude }
        return abs(vy * (point.x - a.x) - vx * (point.y - a.y)) / len
    }

    /// 把点垂直投影到尺线上
    func projectOnLine(_ point: CGPoint) -> CGPoint {
        let (a, b) = linePoints()
        let vx = b.x - a.x, vy = b.y - a.y
        let len2 = vx * vx + vy * vy
        guard len2 > 0.0001 else { return a }
        let t = ((point.x - a.x) * vx + (point.y - a.y) * vy) / len2
        return CGPoint(x: a.x + vx * t, y: a.y + vy * t)
    }

    // MARK: 角度吸附

    /// 计算吸附后的角度。
    /// - Parameter current: 原始角度(弧度)
    /// - Returns: 吸附后的角度 + 是否吸附(用于触觉)
    static func calculateSnappedAngle(current: Double) -> (angle: Double, didSnap: Bool) {
        guard current.isFinite else { return (0, false) }
        let normalized = normalizedAngle(current)
        let degrees = normalized * 180 / .pi
        var best = Double.greatestFiniteMagnitude
        var bestTarget = 0.0
        for target in snapTargetsDegrees {
            var delta = abs(degrees - target)
            delta = min(delta, 360 - delta)   // 0° 与 360° 等价
            if delta < best { best = delta; bestTarget = target }
        }
        guard best <= snapToleranceDegrees else { return (normalized, false) }
        return (normalizedAngle(bestTarget * .pi / 180), true)
    }

    /// 归一化到 [0, π)
    static func normalizedAngle(_ radians: Double) -> Double {
        guard radians.isFinite else { return 0 }
        var r = radians.truncatingRemainder(dividingBy: .pi)
        if r < 0 { r += .pi }
        if r > .pi - 0.0001 { r = 0 }
        return r
    }

    private func applyAngle(_ raw: CGFloat, hapticOnChange: Bool) {
        let result = Self.calculateSnappedAngle(current: Double(raw))
        let newAngle = CGFloat(result.angle)
        if hapticOnChange, result.didSnap, abs(newAngle - angle) > 0.0001 {
            impact.prepare()
            impact.impactOccurred()
        }
        angle = newAngle
        transform = CGAffineTransform(rotationAngle: angle)
        setNeedsDisplay()
    }

    // MARK: 手势

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let host = hostView else { return }
        switch gesture.state {
        case .began:
            dragStartCenter = center
        case .changed:
            guard let start = dragStartCenter else { return }
            let t = gesture.translation(in: host)
            center = CGPoint(x: start.x + t.x, y: start.y + t.y)
        case .ended, .cancelled, .failed:
            dragStartCenter = nil
            clampIntoHost()
        default:
            break
        }
    }

    @objc private func handleRotate(_ gesture: UIRotationGestureRecognizer) {
        switch gesture.state {
        case .began:
            rotationStartAngle = angle
        case .changed:
            guard let start = rotationStartAngle else { return }
            applyAngle(start + gesture.rotation, hapticOnChange: true)
        case .ended, .cancelled, .failed:
            guard let start = rotationStartAngle else { return }
            applyAngle(start + gesture.rotation, hapticOnChange: true)
            rotationStartAngle = nil
        default:
            break
        }
    }

    /// 拖动后把尺子夹在可见范围内(不拉出屏幕)
    private func clampIntoHost() {
        guard let host = hostView else { return }
        let halfW = abs(cos(angle)) * rulerLength / 2 + abs(sin(angle)) * Self.barHeight / 2
        let halfH = abs(sin(angle)) * rulerLength / 2 + abs(cos(angle)) * Self.barHeight / 2
        center.x = min(max(center.x, halfW), host.bounds.width - halfW)
        center.y = min(max(center.y, halfH), host.bounds.height - halfH)
    }

    // MARK: 绘制

    override func draw(_ rect: CGRect) {
        guard isOn, let ctx = UIGraphicsGetCurrentContext(), bounds.width > 1 else { return }
        let bar = bounds.insetBy(dx: 0, dy: 0)
        let path = UIBezierPath(roundedRect: bar.insetBy(dx: 0.5, dy: 3), cornerRadius: 8)
        UIColor.white.withAlphaComponent(0.62).setFill()
        path.fill()
        UIColor.black.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 0.8
        path.stroke()

        // 刻度:每 10pt 一格,5 格为主刻度(带数字)
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.34).cgColor)
        var x: CGFloat = 6
        var index = 0
        while x <= bounds.width - 6 {
            let isMajor = index % 5 == 0
            let tick: CGFloat = isMajor ? 10 : (index % 2 == 0 ? 6 : 4)
            ctx.setLineWidth(isMajor ? 1.1 : 0.7)
            ctx.move(to: CGPoint(x: x, y: 4))
            ctx.addLine(to: CGPoint(x: x, y: 4 + tick))
            ctx.strokePath()
            if isMajor {
                let label = "\(Int(x))"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .medium),
                    .foregroundColor: UIColor.black.withAlphaComponent(0.40)
                ]
                (label as NSString).draw(at: CGPoint(x: x + 1.5, y: bounds.height - 11), withAttributes: attrs)
            }
            x += 10
            index += 1
        }
    }

    // 只命中尺身本身,其余穿透
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -6).contains(point)
    }
}

extension SmartRulerView: UIGestureRecognizerDelegate {
    /// 拖动与双指旋转同时进行
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
