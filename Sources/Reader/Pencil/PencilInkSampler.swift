import UIKit
import PencilKit

/// v0.24.0:书法笔的原始采样点(UITouch 直读,不经 PencilKit 量化)。
///
/// 为什么不用 PencilKit 的 `PKInkingTool` 画书法:SDK 没有"笔锋角度"这个维度,
/// 只有固定笔宽 + 内部模型。Notability 的 calligraphy 是**用椭圆笔尖沿中心线做轮廓偏移**
/// (`copyByStrokingCalligraphyNib`),粗细由"书写方向与笔锋夹角"决定 —— 横细竖粗。
/// 这里用同一原理在 PKStroke 的每个点上直接写 `size`,让 PencilKit 负责渲染与存储。
struct InkSample {
    /// 画布坐标(已含 ×InkGeometry.scale)
    var location: CGPoint
    /// 归一化压力 0…1
    var force: CGFloat
    var azimuth: CGFloat
    var altitude: CGFloat
    var time: TimeInterval
}

/// 只读采样的手势(与 `PencilTouchObserver` 同思路:不替换任何系统 delegate,
/// 只在 touches 回调里抄一份原始数据)。
///
/// 为什么用"零时长长按"而不是 `UIPanGestureRecognizer`:pan 要移动 ~10pt 才进入 `.began`,
/// **点一下(书法里的"点"、i 上那一点)根本不会开始**,那一笔就整个丢了。
/// 长按把 `minimumPressDuration` 设 0、允许移动放到极大,等价于"从落笔到抬笔全程跟踪",
/// 点、短撇、长捺都能收全;状态机仍是 `.began / .changed / .ended`。
final class InkSampleGestureRecognizer: UILongPressGestureRecognizer {

    init() {
        super.init(target: nil, action: nil)
        minimumPressDuration = 0
        allowableMovement = 10_000
        numberOfTouchesRequired = 1
        cancelsTouchesInView = false
    }

    private(set) var samples: [InkSample] = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        samples.removeAll(keepingCapacity: true)
        collect(touches, event: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        collect(touches, event: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        collect(touches, event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        collect(touches, event: event)
    }

    private func collect(_ touches: Set<UITouch>, event: UIEvent?) {
        guard let touch = touches.first(where: { $0.type == .pencil }) ?? touches.first else { return }
        guard let view = view else { return }
        // 合并触摸(coalesced)= Pencil 的 240Hz 采样,比 change 回调密得多,笔锋才连贯
        let batch = event?.coalescedTouches(for: touch) ?? [touch]
        for point in batch {
            let maxForce = point.maximumPossibleForce
            let force = maxForce > 0.01 ? min(max(point.force / maxForce, 0.02), 1) : 0.5
            samples.append(InkSample(
                location: point.location(in: view),
                force: force,
                azimuth: point.azimuthAngle(in: view),
                altitude: point.altitudeAngle,
                time: point.timestamp
            ))
        }
        // 一笔写太久也不无限涨(4096 点 ≈ 17 秒 240Hz)
        if samples.count > 4096 {
            samples.removeFirst(samples.count - 4096)
        }
    }
}

/// v0.24.0:把原始采样点变成一笔**可变宽度**的 PKStroke。
enum CalligraphyInkBuilder {

    /// - Parameters:
    ///   - baseWidth: 画布坐标下的基准笔宽(页面点 × InkGeometry.scale)
    ///   - nibDegrees: 笔锋角度(度);0 = 笔尖水平
    ///   - smoothing: 稳定化(一阶低通)
    static func stroke(
        samples: [InkSample],
        color: UIColor,
        baseWidth: CGFloat,
        nibDegrees: CGFloat,
        smoothing: Bool
    ) -> PKStroke? {
        guard var points = stabilized(samples, smoothing: smoothing) else { return nil }
        if points.count == 1 {
            // 点一下 = 一个墨点:复制一个微偏移点让 PencilKit 能画出圆头
            var dot = points[0]
            dot.location.x += 0.35
            points.append(dot)
        }
        guard points.count >= 2 else { return nil }

        let nib = nibDegrees * .pi / 180
        let count = points.count
        let startTime = points[0].time
        var strokePoints: [PKStrokePoint] = []
        strokePoints.reserveCapacity(count)

        for i in 0..<count {
            let prev = points[max(i - 1, 0)]
            let next = points[min(i + 1, count - 1)]
            let dx = next.location.x - prev.location.x
            let dy = next.location.y - prev.location.y
            let theta = atan2(dy, dx)

            // ① 笔锋:方向与笔尖夹角越大越粗(横细竖粗)
            let chisel = CGFloat(abs(sin(Double(theta) - Double(nib))))
            // ② 压力:轻轻落笔细,压下去粗
            let pressure = 0.55 + 0.85 * points[i].force
            // ③ 速度:快写收锋(用相邻点位移/时间估,时间戳异常时按 1 处理)
            let dt = max(next.time - prev.time, 0.0001)
            let speed = Double(hypot(dx, dy)) / dt          // 画布点/秒
            let speedFactor = 1.0 - min(speed / 5200.0, 1.0) * 0.18
            // ④ 起收笔收锋:两端各 3 点做平滑锥形,写出来的字才有笔锋
            let edge = min(CGFloat(i), CGFloat(count - 1 - i))
            let taper = 0.42 + 0.58 * min(edge / 3, 1)

            var width = baseWidth * (0.18 + 0.82 * chisel) * pressure * CGFloat(speedFactor) * taper
            width = max(width, baseWidth * 0.16)

            strokePoints.append(PKStrokePoint(
                location: points[i].location,
                timeOffset: TimeInterval(points[i].time - startTime),
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: points[i].force,
                azimuth: points[i].azimuth,
                altitude: points[i].altitude,
                secondaryScale: 1
            ))
        }

        guard strokePoints.count >= 2 else { return nil }
        let path = PKStrokePath(controlPoints: strokePoints, creationDate: Date())
        return PKStroke(ink: PKInk(.pen, color: color), path: path, transform: .identity, mask: nil)
    }

    /// 稳定化 + 去重:低通让抖动收敛(慢写更稳),但保留原始点顺序与压力。
    private static func stabilized(_ samples: [InkSample], smoothing: Bool) -> [InkSample]? {
        guard let first = samples.first else { return nil }
        let alpha: CGFloat = smoothing ? 0.72 : 1.0
        var out: [InkSample] = []
        out.reserveCapacity(samples.count)
        var acc = first.location
        for sample in samples {
            acc.x += (sample.location.x - acc.x) * alpha
            acc.y += (sample.location.y - acc.y) * alpha
            var smoothed = sample
            smoothed.location = acc
            // 相邻点太近就不落点(否则 240Hz 会生成上千个无意义的点)
            if let last = out.last,
               hypot(smoothed.location.x - last.location.x, smoothed.location.y - last.location.y) < 0.45 {
                out[out.count - 1] = smoothed
            } else {
                out.append(smoothed)
            }
        }
        return out
    }
}
