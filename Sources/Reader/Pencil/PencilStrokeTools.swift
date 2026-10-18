import UIKit
import PencilKit

/// v0.20.0:跨页书写的笔迹工具 —— 按 y 切开一笔、整笔平移。
///
/// PencilKit 的每一页是独立画布,一笔写不出页边。做法:
/// 画布向下多留 `InkGeometry.bleed` 点"出血区",笔尖可以越过页底继续写;
/// 抬笔后把超出页底的部分切下来,平移到下一页画布的顶部(页面已设为无缝相接,坐标直接相减)。
enum PencilStrokeTools {

    /// 用一组点重建一笔(保留原笔的 ink 与 transform)
    static func makeStroke(points: [PKStrokePoint], template: PKStroke) -> PKStroke? {
        guard points.count >= 2 else { return nil }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKStroke(ink: template.ink, path: path, transform: template.transform, mask: nil)
    }

    /// 把一笔按 y 切成「页内 / 溢出」两段(阈值单位 = 画布坐标)
    static func split(_ stroke: PKStroke, atY threshold: CGFloat) -> (inside: [PKStrokePoint], outside: [PKStrokePoint]) {
        let points = Array(stroke.path)
        guard let firstOutside = points.firstIndex(where: { $0.location.y > threshold }) else {
            return (points, [])
        }
        return (Array(points[..<firstOutside]), Array(points[firstOutside...]))
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
        return makeStroke(points: Array(points), template: stroke)
    }
}
