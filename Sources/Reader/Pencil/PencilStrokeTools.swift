import UIKit
import PencilKit

/// v0.20.0:跨页书写的笔迹工具 —— 按页边切开一笔、整笔平移。
///
/// PencilKit 的每一页是独立画布,一笔写不出页边。做法:
/// 画布四周多留出血区(`InkGeometry.bleedX / bleedTop / bleed`),笔尖可以越过页边继续写;
/// 抬笔后把越界的那一段切下来,按两页的实际版面位移平移到相邻页(v0.29.0:上下左右四边)。
///
/// v0.24.0:切分改成**插值桥接** —— 原来直接取"阈值外的第一个采样点",两半之间会留下
/// 一个采样间隔的缺口(慢写也有一两毫米、快写能到十几毫米),页缝处看起来就是断的。
/// 现在用相邻两点按 y 插值出一个边界点(位置/时间/笔宽/压力/角度全部插值),
/// 两半共享这同一个点,视觉上严丝合缝。
enum PencilStrokeTools {

    /// 用一组点重建一笔(保留原笔的 ink / transform / 创建时间)。
    ///
    /// 保留 `creationDate` —— 一笔被切页/吸附/部分擦除后仍是共享同一 `creationDate` 的多段,
    /// 换成新日期会让"整笔橡皮"再也找不齐同一笔的其它段。
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

    /// 一笔被页边切开后的三段(按笔画顺序):页内侧 A · 溢出段 · 页内侧 B。
    /// - 两个内侧段与溢出段共享**同一个插值边界点**,页缝处严丝合缝。
    /// - 只取**连续**的溢出段:笔跨出页边又折回页内时,折回的那一截仍留在本页,
    ///   不会被错误地搬到邻页(旧实现取"第一个越界点之后的全部",会把这截也搬走)。
    struct Parts {
        var prefix: [PKStrokePoint]
        var outside: [PKStrokePoint]
        var suffix: [PKStrokePoint]
    }

    /// a→b 这条边与水平线 y 的交点参数(0…1)
    private static func crossingT(_ a: PKStrokePoint, _ b: PKStrokePoint, y threshold: CGFloat) -> CGFloat {
        let dy = b.location.y - a.location.y
        guard abs(dy) > 0.0001 else { return 0 }
        return min(max((threshold - a.location.y) / dy, 0), 1)
    }

    /// a→b 这条边与竖直线 x 的交点参数(0…1)
    private static func crossingT(_ a: PKStrokePoint, _ b: PKStrokePoint, x threshold: CGFloat) -> CGFloat {
        let dx = b.location.x - a.location.x
        guard abs(dx) > 0.0001 else { return 0 }
        return min(max((threshold - a.location.x) / dx, 0), 1)
    }

    /// 通用切分:按 `isOutside` 找**第一段连续越界点**,两端各插一个边界点。
    private static func splitRun(_ stroke: PKStroke,
                                 isOutside: (PKStrokePoint) -> Bool,
                                 bridge: (PKStrokePoint, PKStrokePoint) -> PKStrokePoint) -> Parts {
        let points = Array(stroke.path)
        guard !points.isEmpty else { return Parts(prefix: [], outside: [], suffix: []) }
        guard let firstOutside = points.firstIndex(where: isOutside) else {
            return Parts(prefix: points, outside: [], suffix: [])
        }
        // 只取**紧接**第一越界点的那一段连续越界点;后面再次越界的另一段属于后续 hop,
        // 不能并进来(否则中间折回页内的那段会被一起搬走)。
        var lastOutside = firstOutside
        var cursor = firstOutside + 1
        while cursor < points.count, isOutside(points[cursor]) {
            lastOutside = cursor
            cursor += 1
        }

        // 整笔都在界外:本页不留任何东西
        if firstOutside == 0 && lastOutside == points.count - 1 {
            return Parts(prefix: [], outside: points, suffix: [])
        }

        var prefix = Array(points[..<firstOutside])
        var outside: [PKStrokePoint] = []
        var suffix: [PKStrokePoint] = []
        if firstOutside > 0 {
            let edge = bridge(points[firstOutside - 1], points[firstOutside])
            prefix.append(edge)
            outside.append(edge)
        }
        outside.append(contentsOf: points[firstOutside...lastOutside])
        if lastOutside + 1 < points.count {
            let edge = bridge(points[lastOutside], points[lastOutside + 1])
            outside.append(edge)
            suffix.append(edge)
            suffix.append(contentsOf: points[(lastOutside + 1)...])
        }
        return Parts(prefix: prefix, outside: outside, suffix: suffix)
    }

    /// 越过页底(y > 阈值)的段
    static func splitBelow(_ stroke: PKStroke, atY threshold: CGFloat) -> Parts {
        splitRun(stroke, isOutside: { $0.location.y > threshold },
                 bridge: { interpolate($0, $1, t: crossingT($0, $1, y: threshold)) })
    }

    /// 越过页顶(y < 阈值)的段
    static func splitAbove(_ stroke: PKStroke, atY threshold: CGFloat) -> Parts {
        splitRun(stroke, isOutside: { $0.location.y < threshold },
                 bridge: { interpolate($0, $1, t: crossingT($0, $1, y: threshold)) })
    }

    /// 越过页右(x > 阈值)的段
    static func splitRight(_ stroke: PKStroke, atX threshold: CGFloat) -> Parts {
        splitRun(stroke, isOutside: { $0.location.x > threshold },
                 bridge: { interpolate($0, $1, t: crossingT($0, $1, x: threshold)) })
    }

    /// 越过页左(x < 阈值)的段
    static func splitLeft(_ stroke: PKStroke, atX threshold: CGFloat) -> Parts {
        splitRun(stroke, isOutside: { $0.location.x < threshold },
                 bridge: { interpolate($0, $1, t: crossingT($0, $1, x: threshold)) })
    }

    /// v0.29.0:整笔平移(横纵两个方向;跨页搬运按实际页位算 dx/dy)。
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
        return makeStroke(points: Array(points), template: stroke,
                          creationDate: stroke.path.creationDate)
    }
}
