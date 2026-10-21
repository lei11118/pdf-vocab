import UIKit

/// v0.35.0:**屏幕固定的自绘直尺**。
///
/// 为什么不用 PencilKit 自带的直尺:PencilKit 只暴露 `PKCanvasView.isRulerActive`,
/// **没有任何可以设定位位置的公开 API**(Apple 文档 + 社区一致)。它的直尺活在画布坐标系里,
/// 跟着页面一起滚——用户要求"固定在屏幕中间、移动视角不动",只能自己画一把。
///
/// 本层挂在 `PDFView` 上(视口坐标),不参与命中(`isUserInteractionEnabled = false`),
/// 所以不会抢笔、不会挡选词。位置永远是视口中线:滚动、缩放、旋转都不影响;
/// 关闭再打开也不会跳位置 —— 它本来就没有位置状态。
final class InkRulerOverlay: UIView {

    /// 是否显示(由工具会话的 `rulerActive` 驱动)
    var isOn: Bool = false {
        didSet {
            guard isOn != oldValue else { return }
            isHidden = !isOn
            setNeedsDisplay()
            DiagLog.log("ruler: \(isOn ? "on" : "off") y=\(Int(guideY))")
        }
    }

    /// 尺子中线在视口里的 y
    var guideY: CGFloat { bounds.midY }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard isOn, let ctx = UIGraphicsGetCurrentContext(), bounds.width > 1 else { return }
        let y = guideY
        let ink = UIColor.black

        // 主尺线:1.5pt,半透明,纸面固定暖白所以不需要跟随深浅色
        ctx.setStrokeColor(ink.withAlphaComponent(0.32).cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: 0, y: y))
        ctx.addLine(to: CGPoint(x: bounds.width, y: y))
        ctx.strokePath()

        // 刻度:每 60pt 一小格,两端各再画一条端标,让它一眼能认出是"尺子"
        ctx.setStrokeColor(ink.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1)
        var x: CGFloat = 40
        while x < bounds.width {
            ctx.move(to: CGPoint(x: x, y: y - 5))
            ctx.addLine(to: CGPoint(x: x, y: y + 5))
            x += 60
        }
        ctx.move(to: CGPoint(x: 12, y: y - 9))
        ctx.addLine(to: CGPoint(x: 12, y: y + 9))
        ctx.move(to: CGPoint(x: bounds.width - 12, y: y - 9))
        ctx.addLine(to: CGPoint(x: bounds.width - 12, y: y + 9))
        ctx.strokePath()
    }
}
