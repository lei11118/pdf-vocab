import UIKit
import PencilKit

/// 笔迹几何工具(重建一笔 / 跨页切分)。
///
/// v0.32.0:跨页重新回到「抬笔后按页边切开、把越界段搬到邻页」这一条路上。
/// v0.30 试过「只渲染不搬迁」(在 PDFView 上叠镜像画布),真机上那层会被 PDFKit
/// 翻页重建的页视图压到下层,页缝处正好被裁成截断 —— 不可行。
///
/// 切分一律**按页边插值出边界点**,两半共享同一个点,页缝两侧才不会留半个采样间隔的缺口。
enum PencilStrokeTools {

    /// 用一组点重建一笔(保留原笔的 ink / transform / 创建时间)。
    ///
    /// 保留 `creationDate` —— 一笔被部分擦除后仍是共享同一 `creationDate` 的多段,
    /// 换成新日期会让「整笔橡皮」再也找不齐同一笔的其它段。
    static func makeStroke(points: [PKStrokePoint], template: PKStroke,
                           creationDate: Date? = nil) -> PKStroke? {
        guard points.count >= 2 else { return nil }
        let path = PKStrokePath(controlPoints: points,
                                creationDate: creationDate ?? template.path.creationDate)
        return PKStroke(ink: template.ink, path: path, transform: template.transform, mask: nil)
    }

    /// 两点之间按 t(0…1)插值一个采样点;笔宽/压力/倾角一起插值,接缝处粗细不突变。
    static func interpolate(_ a: PKStrokePoint, _ b: PKStrokePoint, t: CGFloat) -> PKStrokePoint {
        let k = min(max(t, 0), 1)
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * k }
        return PKStrokePoint(
            location: CGPoint(x: mix(a.location.x, b.location.x), y: mix(a.location.y, b.location.y)),
            timeOffset: TimeInterval(mix(CGFloat(a.timeOffset), CGFloat(b.timeOffset))),
            size: CGSize(width: mix(a.size.width, b.size.width), height: mix(a.size.height, b.size.height)),
            opacity: mix(a.opacity, b.opacity),
            force: mix(a.force, b.force),
            azimuth: mix(a.azimuth, b.azimuth),
            altitude: mix(a.altitude, b.altitude),
            secondaryScale: mix(a.secondaryScale, b.secondaryScale)
        )
    }

    /// a→b 这条边与水平线 y 的交点参数(0…1)
    private static func crossingT(_ a: PKStrokePoint, _ b: PKStrokePoint, y threshold: CGFloat) -> CGFloat {
        let dy = b.location.y - a.location.y
        guard abs(dy) > 0.0001 else { return 0 }
        return min(max((threshold - a.location.y) / dy, 0), 1)
    }

    /// 向下越界:按 y 切成「页内 / 页外」两段(阈值 = 画布坐标的页底)。
    /// 返回的 inside 末尾与 outside 开头是**同一个边界点**。
    static func splitDown(_ stroke: PKStroke, atY threshold: CGFloat) -> (inside: [PKStrokePoint], outside: [PKStrokePoint]) {
        let points = Array(stroke.path)
        guard let first = points.first else { return ([], []) }
        if first.location.y > threshold { return ([], points) }   // 整笔都在页底以下
        guard let i = points.firstIndex(where: { $0.location.y > threshold }), i > 0 else {
            return (points, [])
        }
        let bridge = interpolate(points[i - 1], points[i], t: crossingT(points[i - 1], points[i], y: threshold))
        return (Array(points[..<i]) + [bridge], [bridge] + Array(points[i...]))
    }

    /// 向上越界:按 y 切成「页外(页顶以上)/ 页内」两段。两段共享同一个边界点。
    static func splitUp(_ stroke: PKStroke, atY threshold: CGFloat) -> (outside: [PKStrokePoint], inside: [PKStrokePoint]) {
        let points = Array(stroke.path)
        guard let first = points.first else { return ([], []) }
        if first.location.y <= threshold { return (points, []) }   // 整笔都在页顶以上
        guard let i = points.firstIndex(where: { $0.location.y <= threshold }), i > 0 else {
            return ([], points)
        }
        let bridge = interpolate(points[i - 1], points[i], t: crossingT(points[i - 1], points[i], y: threshold))
        return ([bridge] + Array(points[i...]), Array(points[..<i]) + [bridge])
    }

    /// 整笔沿 y 平移(把越界段搬到邻页的画布坐标)
    static func shifted(_ stroke: PKStroke, dy: CGFloat) -> PKStroke? {
        let points = stroke.path.map { point in
            PKStrokePoint(
                location: CGPoint(x: point.location.x, y: point.location.y + dy),
                timeOffset: point.timeOffset,
                size: point.size,
                opacity: point.opacity,
                force: point.force,
                azimuth: point.azimuth,
                altitude: point.altitude,
                secondaryScale: point.secondaryScale
            )
        }
        return makeStroke(points: Array(points), template: stroke)
    }
}
