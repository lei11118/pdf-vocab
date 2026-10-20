import UIKit
import PencilKit
import PDFKit

/// v0.30.0:**跨页干墨层** —— 墨迹不再"抬笔后切给邻页",而是留在落笔的那一页,
/// 由这一层把「页面矩形之外」的那部分画到邻页上。
///
/// 为什么这样能根治断笔:
/// - 每页画布的出血区本来就允许写到页外(`InkGeometry.bleedX / bleedTop / bleed`),
///   但 PDFKit 的下一页页视图盖在上面,页缝外那段墨看不见。
/// - 旧方案(v0.20–v0.29)靠"抬笔后切分 + 找邻页 + 位移 + 写进邻页画布"补救:
///   任何一步失败(邻页没建叠层、版面换算差一点、目标页画布还没就绪),表现出来
///   就是页缝处断开。三种排布 × 不同页尺寸 × 缩放,失败面很大。
/// - 现在跨页只剩**渲染**问题:同一页的同一笔,页内由 PDFKit 画、页外用本层再画一遍。
///   两个画布尺寸/变换/渲染器完全一致,所以页缝两侧是同一笔、同一种纹理,天然连续。
///   没有切分、没有搬迁、没有邻页查找,也就没有"搬失败"这种状态。
///
/// 本层是 `PDFView` 的直接子视图(视口坐标),在页视图之上、湿墨层之下:
/// - 每个「有页外墨迹」的页一个只读 `PKCanvasView`;
/// - 画布里的 `layer.mask` 是「画布 − 页面矩形」(静态,不随滚动变化);
/// - 滚动/缩放只更新画布的仿射变换(页面本地 y 向下 → 视图坐标),开销是一次矩阵运算。
///
/// 墨迹归属页 = 落笔的那一页,因此撤销/擦除/存盘仍是"一页一笔",不再有跨页撤销组。
final class PencilDryInkHost: UIView {

    weak var pdfView: PDFView?
    /// 压在干墨层上面的兄弟视图(湿墨层)。置顶时插到它下面,避免把正在写的湿墨盖掉。
    weak var aboveView: UIView?

    /// 每页一个只读镜像画布。只有该页确实有页外墨迹时才创建,避免无谓内存。
    private final class Mirror {
        let canvas = PKCanvasView()
        let mask = CAShapeLayer()
        var pageSize: CGSize

        init(pageSize: CGSize) {
            self.pageSize = pageSize
            canvas.isUserInteractionEnabled = false
            canvas.isScrollEnabled = false
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            // 与真实页画布同一套超采样口径,墨色也不随深色模式漂移。
            canvas.overrideUserInterfaceStyle = .light
            canvas.layer.anchorPoint = .zero
            canvas.layer.position = .zero
            canvas.bounds = InkGeometry.canvasBounds(for: pageSize)
            canvas.contentSize = canvas.bounds.size

            mask.fillColor = UIColor.black.cgColor
            mask.fillRule = .evenOdd
            mask.frame = canvas.bounds
            canvas.layer.mask = mask
        }
    }

    private var mirrors: [Int: Mirror] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 内容同步

    /// 某页画布内容变化(落笔/擦除/撤销/清空/载入)。只保留「有页外墨迹」的页。
    func update(page index: Int, drawing: PKDrawing, pageSize: CGSize) {
        guard pageSize.width > 1, pageSize.height > 1 else { return }
        guard hasOutsideInk(drawing, pageSize: pageSize) else {
            if let mirror = mirrors.removeValue(forKey: index) {
                mirror.canvas.removeFromSuperview()
            }
            return
        }
        let mirror: Mirror
        if let existing = mirrors[index] {
            mirror = existing
            if abs(existing.pageSize.width - pageSize.width) > 0.01
                || abs(existing.pageSize.height - pageSize.height) > 0.01 {
                existing.pageSize = pageSize
                existing.canvas.bounds = InkGeometry.canvasBounds(for: pageSize)
                existing.canvas.contentSize = existing.canvas.bounds.size
                existing.mask.frame = existing.canvas.bounds
                applyMask(existing)
            }
        } else {
            mirror = Mirror(pageSize: pageSize)
            applyMask(mirror)
            addSubview(mirror.canvas)
            mirrors[index] = mirror
            DiagLog.log("pencil: dry mirror add page=\(index) size=\(Int(pageSize.width))x\(Int(pageSize.height))")
        }
        // PKDrawing 是写时复制,赋值几乎零成本。
        mirror.canvas.drawing = drawing
        layoutMirror(page: index, mirror: mirror)
    }

    /// 滚动/缩放/换排布后重算每页镜像画布的位置与缩放。
    func refresh() {
        guard !mirrors.isEmpty else { return }
        ensureOnTop()
        for (index, mirror) in mirrors {
            layoutMirror(page: index, mirror: mirror)
        }
    }

    func removeAll() {
        for (_, mirror) in mirrors {
            mirror.canvas.removeFromSuperview()
        }
        mirrors.removeAll()
    }

    // MARK: - 内部

    /// 画布坐标里是否有任何墨迹越出页面矩形(含笔画宽度,留 2 个画布点的余量)。
    private func hasOutsideInk(_ drawing: PKDrawing, pageSize: CGSize) -> Bool {
        guard !drawing.strokes.isEmpty else { return false }
        var b = CGRect.null
        for stroke in drawing.strokes {
            b = b.union(stroke.renderBounds)
        }
        guard !b.isNull, !b.isEmpty else { return false }
        let rect = InkGeometry.pageRectInCanvas(pageSize: pageSize)
        let eps: CGFloat = 2
        return b.minX < rect.minX - eps || b.maxX > rect.maxX + eps
            || b.minY < rect.minY - eps || b.maxY > rect.maxY + eps
    }

    /// 遮罩 = 整个画布 − 页面矩形(奇偶填充),静态:坐标都在画布自己的空间里。
    private func applyMask(_ mirror: Mirror) {
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: InkGeometry.canvasSize(for: mirror.pageSize)))
        path.addRect(InkGeometry.pageRectInCanvas(pageSize: mirror.pageSize))
        mirror.mask.path = path
    }

    /// 页面本地 y 向下坐标 → 视图坐标的仿射变换(含缩放/滚动/页旋转)。
    /// 用 CropBox 的三个基点求,不假设页面未旋转。
    private func layoutMirror(page index: Int, mirror: Mirror) {
        guard let pdfView, let document = pdfView.document,
              index >= 0, index < document.pageCount,
              let page = document.page(at: index) else {
            mirror.canvas.isHidden = true
            return
        }
        let box = page.bounds(for: pdfView.displayBox)
        let origin = pdfView.convert(CGPoint(x: box.minX, y: box.maxY), from: page)
        let xTip = pdfView.convert(CGPoint(x: box.minX + 1, y: box.maxY), from: page)
        let yTip = pdfView.convert(CGPoint(x: box.minX, y: box.maxY - 1), from: page)
        let a = xTip.x - origin.x
        let b = xTip.y - origin.y
        let c = yTip.x - origin.x
        let d = yTip.y - origin.y
        // 页面还没落版时 convert 可能返回退化值 —— 先藏起来,下一次滚动/缩放再算。
        guard abs(a) + abs(b) > 0.01, abs(c) + abs(d) > 0.01 else {
            mirror.canvas.isHidden = true
            return
        }
        mirror.canvas.isHidden = false
        // 画布坐标 = 页面坐标 × scale + 出血偏移,所以显示变换 = 页面变换 / scale。
        mirror.canvas.transform = CGAffineTransform(
            a: a / InkGeometry.scale, b: b / InkGeometry.scale,
            c: c / InkGeometry.scale, d: d / InkGeometry.scale,
            tx: 0, ty: 0
        )
        // anchorPoint = .zero:position 就是画布左上角(画布坐标 (0,0))在视图里的位置。
        // 画布坐标 (0,0) 对应页面本地坐标 (-bleedX, -bleedTop)。
        mirror.canvas.layer.position = CGPoint(
            x: origin.x - a * InkGeometry.bleedX - c * InkGeometry.bleedTop,
            y: origin.y - b * InkGeometry.bleedX - d * InkGeometry.bleedTop
        )
    }

    /// v0.30.0:PDFKit 翻页/切排布会重建层级,可能把本层压到页视图下面。
    /// 若湿墨层在同一个父视图里,就始终插在它下面。
    private func ensureOnTop() {
        guard let superview else { return }
        if let above = aboveView, above.superview === superview {
            if superview.subviews.last !== above {
                superview.bringSubviewToFront(above)
            }
            superview.insertSubview(self, belowSubview: above)
            return
        }
        if superview.subviews.last !== self {
            superview.bringSubviewToFront(self)
        }
    }
}
