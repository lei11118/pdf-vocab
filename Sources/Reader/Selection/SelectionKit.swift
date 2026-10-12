import UIKit
import PDFKit

// MARK: - 拖动柄(原生同款不对称布局)

/// 选区拖柄:实心蓝圆点 + 指向文字的短柄。
/// 起点柄:圆点在选区**上方**、短柄朝下;终点柄:圆点在选区**下方**、短柄朝上
/// (与真机参考截图——iPadOS 26 原生选择——逐像素一致)。
final class SelectionHandleView: UIView {
    let isStart: Bool
    private let dot = UIView()
    private let stem = UIView()

    init(isStart: Bool) {
        self.isStart = isStart
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        backgroundColor = .clear
        dot.backgroundColor = .systemBlue
        dot.layer.cornerRadius = 7
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.15
        dot.layer.shadowRadius = 2
        dot.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(dot)
        stem.backgroundColor = .systemBlue
        stem.layer.cornerRadius = 1.25
        addSubview(stem)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let d: CGFloat = 14
        if isStart {
            // 起点柄:圆点在选区上方,短柄朝下指向首行(真机参考:iPadOS 26 原生)
            dot.frame = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2 - 6, width: d, height: d)
            stem.frame = CGRect(x: bounds.width / 2 - 1.25, y: dot.frame.maxY, width: 2.5, height: 6)
        } else {
            // 终点柄:圆点在选区下方,短柄朝上指向末行
            dot.frame = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2 + 6, width: d, height: d)
            stem.frame = CGRect(x: bounds.width / 2 - 1.25, y: dot.frame.minY - 6, width: 2.5, height: 6)
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -14, dy: -14).contains(point)
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
