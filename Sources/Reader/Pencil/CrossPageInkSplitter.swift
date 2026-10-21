import PencilKit
import CoreGraphics

/// v0.38.0:跨页墨迹切分器(纯几何,无状态,可单测)。
///
/// 与 `PencilStrokeTools` 的分工:
/// - 这里是**规范实现**:任意方向、带错误类型、共享边界插值点;
/// - 线上实际使用的是 `PencilOverlayProvider.settleOverflow` 里按排布轴调用的版本
///   (它还要处理横向排布与"两页真实页矩形对齐"),本类型用于测试与后续重构。
enum CrossPageInkSplitter {

    struct SplitResult {
        /// 页内那半段(坐标与输入一致)
        let top: PKStroke
        /// 越界那半段,**已平移**:y 全部减去 pageBoundaryY
        let bottom: PKStroke
        /// 精确交点(输入坐标系)
        let intersection: CGPoint
    }

    enum SplitError: Error, Equatable {
        case emptyPath          // 少于 2 个采样点
        case noCrossing         // 整笔都在边界一侧
        case degenerateSegment  // 退化段(零长度 / 非有限值)
    }

    /// 在 `pageBoundaryY` 处把一笔切成上下两段。
    ///
    /// 数学:`t = (boundary - a.y) / (b.y - a.y)`,对位置与全部笔画属性做同参数线性插值,
    /// 两段**共享同一个交点**,因此接缝处不会出现墨迹断层。
    ///
    /// - Important: `stroke` 必须已处于目标坐标系。若 `stroke.transform != .identity`,
    ///   先按其 transform 换算采样点,否则交点会落在错误位置。
    /// - Note: 一笔多次穿越边界时只切**第一次**;对 `bottom` 递归调用可继续收敛。
    static func splitStrokeAtBoundary(stroke: PKStroke,
                                      pageBoundaryY: CGFloat) -> Result<SplitResult, SplitError> {
        let points = Array(stroke.path)
        guard points.count >= 2 else { return .failure(.emptyPath) }
        guard pageBoundaryY.isFinite else { return .failure(.degenerateSegment) }

        for index in 1..<points.count {
            let a = points[index - 1]
            let b = points[index]
            let ay = a.location.y, by = b.location.y

            // 同侧 → 继续找
            if (ay <= pageBoundaryY && by <= pageBoundaryY) ||
               (ay > pageBoundaryY && by > pageBoundaryY) { continue }

            let dy = by - ay
            let crossing: PKStrokePoint
            if abs(dy) > 0.000_001 {
                let t = (pageBoundaryY - ay) / dy
                guard t.isFinite else { return .failure(.degenerateSegment) }
                crossing = interpolate(a, b, t: t, boundaryY: pageBoundaryY)
            } else {
                // 水平段恰好压在边界上:直接取前一点,避免除零
                crossing = a
            }
            return build(points: points, at: index, crossing: crossing,
                         boundary: pageBoundaryY, stroke: stroke)
        }
        return .failure(.noCrossing)
    }

    // MARK: - 私有

    /// 按参数 t 插值出一个采样点;y 直接吸附到边界,消除浮点误差。
    private static func interpolate(_ a: PKStrokePoint, _ b: PKStrokePoint,
                                    t: CGFloat, boundaryY: CGFloat) -> PKStrokePoint {
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return PKStrokePoint(
            location: CGPoint(x: mix(a.location.x, b.location.x), y: boundaryY),
            timeOffset: TimeInterval(mix(CGFloat(a.timeOffset), CGFloat(b.timeOffset))),
            size: CGSize(width: mix(a.size.width, b.size.width),
                         height: mix(a.size.height, b.size.height)),
            opacity: mix(a.opacity, b.opacity),
            force: mix(a.force, b.force),
            azimuth: mix(a.azimuth, b.azimuth),
            altitude: mix(a.altitude, b.altitude),
            secondaryScale: mix(a.secondaryScale, b.secondaryScale)
        )
    }

    private static func build(points: [PKStrokePoint], at index: Int,
                              crossing: PKStrokePoint, boundary: CGFloat,
                              stroke: PKStroke) -> Result<SplitResult, SplitError> {
        var topPoints = Array(points[0..<index])
        topPoints.append(crossing)

        var bottomPoints: [PKStrokePoint] = [translated(crossing, dy: -boundary)]
        for point in points[index...] {
            bottomPoints.append(translated(point, dy: -boundary))
        }
        guard topPoints.count >= 2, bottomPoints.count >= 2 else {
            return .failure(.degenerateSegment)
        }

        // 两段共享 creationDate:系统层面仍属"同一笔",
        // 整笔橡皮与跨页撤销都依赖这一点。
        let date = stroke.path.creationDate
        let top = PKStroke(ink: stroke.ink,
                           path: PKStrokePath(controlPoints: topPoints, creationDate: date),
                           transform: .identity, mask: nil)
        let bottom = PKStroke(ink: stroke.ink,
                              path: PKStrokePath(controlPoints: bottomPoints, creationDate: date),
                              transform: .identity, mask: nil)
        return .success(SplitResult(top: top, bottom: bottom, intersection: crossing.location))
    }

    private static func translated(_ p: PKStrokePoint, dy: CGFloat) -> PKStrokePoint {
        PKStrokePoint(location: CGPoint(x: p.location.x, y: p.location.y + dy),
                      timeOffset: p.timeOffset, size: p.size, opacity: p.opacity,
                      force: p.force, azimuth: p.azimuth, altitude: p.altitude,
                      secondaryScale: p.secondaryScale)
    }
}
