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

        // v0.37.0:做成"尺身"而不是一条线 —— 半透明条 + 长短刻度 + 每 150pt 一个数字,
        // 形状与 Notability 那把一致,但完全自绘、固定在视口中线。
        let barHeight: CGFloat = 22
        let bar = CGRect(x: 0, y: y - barHeight / 2, width: bounds.width, height: barHeight)
        let path = UIBezierPath(roundedRect: bar, cornerRadius: 6)
        UIColor.white.withAlphaComponent(0.55).setFill()
        path.fill()
        ink.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 0.8
        path.stroke()

        ctx.setStrokeColor(ink.withAlphaComponent(0.34).cgColor)
        var x: CGFloat = 0
        var index = 0
        while x <= bounds.width {
            let kind = index % 5      // 0 = 长刻度(带数字)
            let tick: CGFloat = kind == 0 ? 11 : (kind == 2 ? 7 : 4)
            ctx.setLineWidth(kind == 0 ? 1.1 : 0.8)
            ctx.move(to: CGPoint(x: x, y: y - barHeight / 2 + 1))
            ctx.addLine(to: CGPoint(x: x, y: y - barHeight / 2 + 1 + tick))
            ctx.strokePath()

            if kind == 0, x > 6 {
                let label = "\(Int(x))"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
                    .foregroundColor: ink.withAlphaComponent(0.42)
                ]
                let size = (label as NSString).size(withAttributes: attrs)
                (label as NSString).draw(at: CGPoint(x: x + 2, y: y + barHeight / 2 - size.height - 1),
                                         withAttributes: attrs)
            }
            x += 30
            index += 1
        }

        // 两端的握把记号,让它一眼看出是"一把尺子"
        ctx.setStrokeColor(ink.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(1.4)
        for ex in [CGFloat(10), bounds.width - 10] {
            ctx.move(to: CGPoint(x: ex, y: y - 5))
            ctx.addLine(to: CGPoint(x: ex, y: y + 5))
        }
        ctx.strokePath()
    }
}
