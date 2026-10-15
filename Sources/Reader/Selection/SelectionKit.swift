import UIKit
import PDFKit

// MARK: - 拖柄几何常量(唯一出处;绘制 / 摆放 / 菜单避让都读这里)

/// 拖柄几何(v0.6.10:对齐原生)。所有与拖柄相关的数字集中于此,避免"绘制一套、避让又一套"。
enum HandleMetrics {
    /// 圆点直径
    static let dotDiameter: CGFloat = 14
    /// 竖线宽度(v0.6.11:2.5 → 4,加粗;小柄本身即选区边缘)
    static let lineWidth: CGFloat = 4
    /// 竖线端头与圆点的交叠量(消除接缝,让圆点"长在"线圈上)
    static let dotLineOverlap: CGFloat = 2
    /// 圆点伸出选区(行矩形)外的距离 = 直径 − 交叠(菜单避让据此计算包络)
    static var dotProtrusion: CGFloat { dotDiameter - dotLineOverlap }
    /// 拖柄视图宽度(= 圆点直径,竖线居中)
    static var handleWidth: CGFloat { dotDiameter }
    /// 最小拖动热区(短边不小于它,以"圆点 + 竖线"整体为中心)
    static let hitMinimum: CGFloat = 44
}

// MARK: - 拖动柄(原生同款:竖线 = 行高,圆点紧贴竖线外端;v0.6.10)

/// 选区拖柄:**一根与首/末行选区等高的竖线**沿选区边缘,圆点紧贴竖线外端——
/// 起点柄:竖线沿首行**左**边缘,圆点在竖线**上端**(位于选区外、上方);
/// 终点柄:竖线沿末行**右**边缘,圆点在竖线**下端**(位于选区外、下方)。
/// 视图尺寸由外部按行高设置:高 = 行高 + dotProtrusion,宽 = handleWidth;两端共用同一几何函数。
final class SelectionHandleView: UIView {
    let isStart: Bool
    private let dot = UIView()
    private let stem = UIView()

    init(isStart: Bool) {
        self.isStart = isStart
        super.init(frame: CGRect(x: 0, y: 0, width: HandleMetrics.handleWidth, height: 44))
        backgroundColor = .clear
        stem.backgroundColor = .systemBlue
        stem.layer.cornerRadius = HandleMetrics.lineWidth / 2
        addSubview(stem)
        dot.backgroundColor = .systemBlue
        dot.layer.cornerRadius = HandleMetrics.dotDiameter / 2
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.15
        dot.layer.shadowRadius = 2
        dot.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(dot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 竖线(局部坐标;两端共用同一函数,左右对称)——起点在局部 y=dotProtrusion 处(圆点下方),终点在 y=0 处(圆点上方)。
    private func lineFrame(lineHeight: CGFloat) -> CGRect {
        CGRect(
            x: (bounds.width - HandleMetrics.lineWidth) / 2,
            y: isStart ? HandleMetrics.dotProtrusion : 0,
            width: HandleMetrics.lineWidth,
            height: lineHeight
        )
    }

    /// 圆点(局部坐标;紧贴竖线外端,与竖线交叠 dotLineOverlap 消除接缝)。
    private func dotFrame(lineHeight: CGFloat) -> CGRect {
        let d = HandleMetrics.dotDiameter
        let y = isStart
            ? 0                                                       // 上端:圆点在竖线之上(选区外)
            : lineHeight + HandleMetrics.dotProtrusion - d            // 下端:圆点在竖线之下(选区外)
        return CGRect(x: (bounds.width - d) / 2, y: y, width: d, height: d)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 视图高 = 行高 + 圆点伸出距离;竖线 = 行高
        let lineHeight = max(bounds.height - HandleMetrics.dotProtrusion, 1)
        stem.frame = lineFrame(lineHeight: lineHeight)
        dot.frame = dotFrame(lineHeight: lineHeight)
    }

    /// 拖动热区 ≥ hitMinimum × hitMinimum,以"圆点 + 竖线"整体(即视图 bounds)为中心。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (HandleMetrics.hitMinimum - bounds.width) / 2)
        let dy = max(0, (HandleMetrics.hitMinimum - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

// MARK: - 系统放大镜(iOS 17+,任意视图可用)

/// `UITextLoupeSession` 薄封装:与原生拖动手感一致的放大镜。
final class LoupeController {
    private var session: UITextLoupeSession?

    var isActive: Bool { session != nil }

    /// 开始(或移动到)指定位置。widget 传"选区把手视图"时,系统从它开始动画;传 nil 从触点开始。
    func begin(at point: CGPoint, widget: UIView?, in view: UIView) {
        if session == nil {
            session = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: widget, in: view)
            DiagLog.log("loupe: begin")
        } else {
            move(to: point)
        }
    }

    func move(to point: CGPoint) {
        session?.move(to: point, withCaretRect: .null, trackingCaret: false)
    }

    func end() {
        guard session != nil else { return }
        session?.invalidate()
        session = nil
        DiagLog.log("loupe: end")
    }
}

// MARK: - 感知 Pencil 的拖动手势

/// 记录首触点类型的 pan 手势(用于"放大镜只对指尖显示、不对 Pencil 显示")。
final class PencilAwarePanGestureRecognizer: UIPanGestureRecognizer {
    private(set) var isPencilDriven = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first {
            isPencilDriven = (touch.type == .pencil)
        }
        super.touchesBegan(touches, with: event)
    }
}

// MARK: - 几何与合法性(全部集中于此,避免散落)

enum SelectionGeometry {

    static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    /// 页面坐标 y 向上:先按行(容差 6pt),同行按 x 排序,保证 from 在 to 之前。
    static func ordered(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
        if abs(a.y - b.y) < 6 { return a.x <= b.x ? (a, b) : (b, a) }
        return a.y > b.y ? (a, b) : (b, a)
    }

    static func isSane(_ selection: PDFSelection, maxPages: Int, maxChars: Int) -> Bool {
        guard !selection.pages.isEmpty, selection.pages.count <= maxPages else { return false }
        guard let text = selection.string, !text.isEmpty, text.count <= maxChars else { return false }
        return true
    }

    static func isValid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.width < 10_000 && rect.height < 10_000
    }

    static func logSnippet(_ s: String) -> String {
        String(s.replacingOccurrences(of: "\n", with: " ").prefix(16))
    }
}
