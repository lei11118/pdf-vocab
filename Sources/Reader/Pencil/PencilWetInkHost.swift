import UIKit
import PDFKit

/// v0.28.0:**全局湿墨层**(对应逆向文档 §4.6 的 wet ink)。
///
/// 为什么需要它:PDFKit 的每页叠层是本页视图的子视图,下一页的页视图会把它盖住。
/// 因此书写过程中越过页缝的墨在抬笔前看不见(旧实现只能等抬笔再搬到邻页)。
/// 这个视图是 `PDFView` 的直接子视图,固定在视口坐标里,永远盖在所有页之上:
/// 常规笔只画「当前页矩形之外」的那一段(页内仍由 PencilKit 画),
/// 书法/形状则整段预览都画在这里(激光仍留在页内叠层,不做跨页处理)。
///
/// 所有输入路径都用**页面本地坐标(y 向下)**,与墨迹库一致;
/// 显示时按当前页的 CropBox 现算 page → view 仿射变换,所以滚动/缩放时只需重绘一次。
final class PencilWetInkHost: UIView {

    weak var pdfView: PDFView?

    private let shapeLayer = CAShapeLayer()
    private let maskLayer = CAShapeLayer()
    private let linkTarget = WeakDisplayLinkTarget()
    private var displayLink: CADisplayLink?
    private var stroke: PencilWetStroke?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.strokeColor = UIColor.clear.cgColor
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        layer.addSublayer(shapeLayer)
        linkTarget.host = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        displayLink?.invalidate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.frame = bounds
        redraw()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 离开窗口时停掉显示链接,避免持有 CADisplayLink 空转。
        if window == nil { clear() }
    }

    /// 显示/更新一笔湿墨。重复调用只替换内容,不重置显示链接。
    func show(_ stroke: PencilWetStroke) {
        self.stroke = stroke
        startLink()
        redraw()
    }

    func clear() {
        stroke = nil
        shapeLayer.path = nil
        shapeLayer.mask = nil
        stopLink()
    }

    func refresh() {
        redraw()
    }

    // MARK: - 绘制

    private func startLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: linkTarget, selector: #selector(WeakDisplayLinkTarget.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func redraw() {
        guard let stroke, let pdfView, let pdfPage = page(at: stroke.pageIndex) else {
            shapeLayer.path = nil
            shapeLayer.mask = nil
            return
        }
        var transform = pageToViewTransform(page: pdfPage, pdfView: pdfView)
        guard let path = stroke.path.cgPath.copy(using: &transform) else {
            shapeLayer.path = nil
            return
        }
        shapeLayer.frame = bounds
        shapeLayer.path = path

        if stroke.filled {
            shapeLayer.fillColor = stroke.color.cgColor
            shapeLayer.strokeColor = UIColor.clear.cgColor
            shapeLayer.lineWidth = 0
        } else {
            shapeLayer.fillColor = UIColor.clear.cgColor
            shapeLayer.strokeColor = stroke.color.cgColor
            // 路径已经变换到 view 坐标,线宽也要按同一比例放大。
            shapeLayer.lineWidth = max(stroke.lineWidth * scaleFactor(transform), 0.5)
            shapeLayer.lineDashPattern = stroke.dashed
                ? [NSNumber(value: 5), NSNumber(value: 4)]
                : nil
        }

        if stroke.clipOutsidePage {
            let pageRect = pdfView.convert(pdfPage.bounds(for: pdfView.displayBox), from: pdfPage)
            let combined = CGMutablePath()
            combined.addRect(bounds)
            combined.addRect(pageRect)
            maskLayer.frame = bounds
            maskLayer.path = combined
            maskLayer.fillRule = .evenOdd
            maskLayer.fillColor = UIColor.black.cgColor
            shapeLayer.mask = maskLayer
        } else {
            shapeLayer.mask = nil
        }
    }

    /// 页面本地坐标(y 向下)→ PDFView 视图坐标的仿射变换。
    /// 用 CropBox 的三个基点求变换,旋转页也能正确跟随。
    private func pageToViewTransform(page: PDFPage, pdfView: PDFView) -> CGAffineTransform {
        let box = page.bounds(for: pdfView.displayBox)
        let origin = pdfView.convert(CGPoint(x: box.minX, y: box.maxY), from: page)
        let xBasis = pdfView.convert(CGPoint(x: box.minX + 1, y: box.maxY), from: page)
        let yBasis = pdfView.convert(CGPoint(x: box.minX, y: box.maxY - 1), from: page)
        return CGAffineTransform(
            a: xBasis.x - origin.x, b: xBasis.y - origin.y,
            c: yBasis.x - origin.x, d: yBasis.y - origin.y,
            tx: origin.x, ty: origin.y
        )
    }

    private func scaleFactor(_ t: CGAffineTransform) -> CGFloat {
        sqrt(abs(t.a * t.d - t.b * t.c))
    }

    private func page(at index: Int) -> PDFPage? {
        guard let document = pdfView?.document, index >= 0, index < document.pageCount else { return nil }
        return document.page(at: index)
    }
}

/// 一笔湿墨的描述。坐标为**页面本地**(y 向下),线宽为页面点。
struct PencilWetStroke {
    var pageIndex: Int
    var path: UIBezierPath
    var color: UIColor
    var lineWidth: CGFloat
    /// true = 用填充多边形(书法预览);false = 用描边折线(常规笔/激光/形状)
    var filled: Bool
    /// true = 只画当前页矩形之外的部分(常规笔;页内仍由 PencilKit 负责)
    var clipOutsidePage: Bool
    /// 形状预览用虚线;其余为实线
    var dashed: Bool = false
}

/// 打断 CADisplayLink → host 的强引用环。
private final class WeakDisplayLinkTarget: NSObject {
    weak var host: PencilWetInkHost?
    @objc func tick() { host?.refresh() }
}
