import UIKit
import PencilKit

/// 切分轴:纵向连续排布沿 y 翻页,横向连续排布沿 x 翻页。
enum InkSplitAxis {
    case x
    case y
}

/// 笔迹几何工具(重建一笔 / 跨页切分)。
///
/// v0.32.0:跨页回到「抬笔后按页边切开、把越界段搬到邻页」;v0.30 的"只渲染不搬迁"
/// (PDFView 上叠镜像画布)会被 PDFKit 翻页重建的页视图压到下层,页缝处正好被裁成截断。
///
/// v0.33.0:**切分必须沿排布方向**。之前只按 y 切,横向排布(左右翻页)下会把越过页底的墨
/// 搬到"下一页"(其实在右边),真机上表现为图形跑到隔壁页、还被画布边界裁掉
/// (`stroke hit canvas edge (bleed exhausted)`)。
///
/// 切分一律**按页边插值出边界点**,两半共享同一个点,页缝两侧才不会留半个采样间隔的缺口。
enum PencilStrokeTools {

    /// 取某个轴上的比较值(画布坐标)
    static func value(_ point: PKStrokePoint, _ axis: InkSplitAxis) -> CGFloat {
        axis == .y ? point.location.y : point.location.x
    }

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
        func mix(_ v: CGFloat, _ w: CGFloat) -> CGFloat { v + (w - v) * k }
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

    /// a→b 这条边与阈值线的交点参数(0…1)
    private static func crossingT(_ a: PKStrokePoint, _ b: PKStrokePoint,
                                  threshold: CGFloat, axis: InkSplitAxis) -> CGFloat {
        let av = value(a, axis)
        let bv = value(b, axis)
        let d = bv - av
        guard abs(d) > 0.0001 else { return 0 }
        return min(max((threshold - av) / d, 0), 1)
    }

    /// 切掉「超过阈值」的那一半:
    /// inside = 值 ≤ 阈值(页内),outside = 值 > 阈值(越过页底/页右)。
    static func splitBeyond(_ stroke: PKStroke, threshold: CGFloat,
                            axis: InkSplitAxis) -> (inside: [PKStrokePoint], outside: [PKStrokePoint]) {
        let points = Array(stroke.path)
        guard let first = points.first else { return ([], []) }
        if value(first, axis) > threshold { return ([], points) }
        guard let i = points.firstIndex(where: { value($0, axis) > threshold }), i > 0 else {
            return (points, [])
        }
        let bridge = interpolate(points[i - 1], points[i],
                                 t: crossingT(points[i - 1], points[i], threshold: threshold, axis: axis))
        return (Array(points[..<i]) + [bridge], [bridge] + Array(points[i...]))
    }

    /// 切掉「低于阈值」的那一半:
    /// inside = 值 > 阈值(页内),outside = 值 ≤ 阈值(越过页顶/页左)。
    static func splitBefore(_ stroke: PKStroke, threshold: CGFloat,
                            axis: InkSplitAxis) -> (inside: [PKStrokePoint], outside: [PKStrokePoint]) {
        let points = Array(stroke.path)
        guard let first = points.first else { return ([], []) }
        if value(first, axis) <= threshold { return ([], points) }
        guard let i = points.firstIndex(where: { value($0, axis) <= threshold }), i > 0 else {
            return ([], points)
        }
        let bridge = interpolate(points[i - 1], points[i],
                                 t: crossingT(points[i - 1], points[i], threshold: threshold, axis: axis))
        return (Array(points[i...]), [bridge] + Array(points[..<i]))
    }

    /// 整笔平移(把越界段搬到邻页的画布坐标)
    static func shifted(_ stroke: PKStroke, dx: CGFloat, dy: CGFloat) -> PKStroke? {
        let points = stroke.path.map { point in
            PKStrokePoint(
                location: CGPoint(x: point.location.x + dx, y: point.location.y + dy),
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
