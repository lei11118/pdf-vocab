import UIKit
import PencilKit

/// v0.20.0:跨页书写的笔迹工具 —— 按 y 切开一笔、整笔平移。
///
/// PencilKit 的每一页是独立画布,一笔写不出页边。做法:
/// 画布向下多留 `InkGeometry.bleed` 点"出血区",笔尖可以越过页底继续写;
/// 抬笔后把超出页底的部分切下来,平移到下一页画布的顶部(页面已设为无缝相接,坐标直接相减)。
///
/// v0.24.0:切分改成**插值桥接** —— 原来直接取"阈值外的第一个采样点",两半之间会留下
/// 一个采样间隔的缺口(慢写也有一两毫米、快写能到十几毫米),页缝处看起来就是断的。
/// 现在用相邻两点按 y 插值出一个边界点(位置/时间/笔宽/压力/角度全部插值),
/// 两半共享这同一个点,视觉上严丝合缝。
enum PencilStrokeTools {

    /// 用一组点重建一笔(保留原笔的 ink / transform / 创建时间)。
    ///
    /// v0.28.0:保留 `creationDate` —— 书法笔的整笔是共享同一 `creationDate` 的多段,
    /// 切页/吸附/部分擦除后用新日期会让"整笔橡皮"再也找不齐这条书法。
    static func makeStroke(points: [PKStrokePoint], template: PKStroke,
                           creationDate: Date? = nil) -> PKStroke? {
        guard points.count >= 2 else { return nil }
        let path = PKStrokePath(controlPoints: points,
                                creationDate: creationDate ?? template.path.creationDate)
        return PKStroke(ink: template.ink, path: path, transform: template.transform, mask: nil)
    }

    /// 两点之间按 t(0…1)插值一个采样点。除位置外,笔宽/压力/倾角也一起插值,
    /// 这样跨页接缝处的粗细不会突变。
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

    /// 把一笔按 y 切成「页内 / 溢出」两段(阈值单位 = 画布坐标)。
    /// 返回的 inside 末尾与 outside 开头是**同一个边界点**。
    static func split(_ stroke: PKStroke, atY threshold: CGFloat) -> (inside: [PKStrokePoint], outside: [PKStrokePoint]) {
        let points = Array(stroke.path)
        guard let first = points.first else { return ([], []) }
        // 整笔都在阈值以下:全部属于下一页
        if first.location.y > threshold { return ([], points) }
        guard let i = points.firstIndex(where: { $0.location.y > threshold }), i > 0 else {
            return (points, [])
        }
        let bridge = interpolate(points[i - 1], points[i], t: crossingT(points[i - 1], points[i], y: threshold))
        return (Array(points[..<i]) + [bridge], [bridge] + Array(points[i...]))
    }

    /// v0.23.2:向上越界专用 —— 笔从页内往上写,先遇到 y ≤ 阈值。
    /// 返回 (above: 页顶以上的段, below: 页内段);两段共享同一个边界点。
    static func splitUpward(_ stroke: PKStroke, atY threshold: CGFloat) -> (above: [PKStrokePoint], below: [PKStrokePoint]) {
        let points = Array(stroke.path)
        guard let first = points.first else { return ([], []) }
        // 整笔都在页顶以上:全部属于上一页
        if first.location.y <= threshold { return (points, []) }
        guard let i = points.firstIndex(where: { $0.location.y <= threshold }), i > 0 else {
            return ([], points)
        }
        let bridge = interpolate(points[i - 1], points[i], t: crossingT(points[i - 1], points[i], y: threshold))
        return ([bridge] + Array(points[i...]), Array(points[..<i]) + [bridge])
    }

    /// 整笔沿 y 平移(用于把溢出段搬到下一页)
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
        return makeStroke(points: Array(points), template: stroke,
                          creationDate: stroke.path.creationDate)
    }
}
