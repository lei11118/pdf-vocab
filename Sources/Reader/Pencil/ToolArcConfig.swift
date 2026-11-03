import CoreGraphics
import Foundation

enum ToolArcConfig {
    static let sweep = CGFloat(108) * .pi / 180
    static let tilt = CGFloat(53) * .pi / 180
    static let radius: CGFloat = 340
    static func effectiveRadius(in bounds: CGSize) -> CGFloat { min(radius,max(50,(min(bounds.width,bounds.height)-2*safeMargin-2*gap)/2)) }
    static let gap: CGFloat = 64
    static let diameter: CGFloat = 44
    static let pitch: CGFloat = 52
    static let band: CGFloat = 34
    static let hysteresis: CGFloat = 12
    static let resetDelay = 0.18
    static let hoverDelay: UInt64 = 200_000_000
    static let animation = 0.24
    static let safeMargin: CGFloat = 28
}

struct ToolArcGeometry {
    let anchor: CGPoint
    let bounds: CGSize
    let count: Int
    var leftHanded = false
    // Tangent/chord tilt is measured from the screen horizontal, as requested.
    var mid: CGFloat { -ToolArcConfig.tilt }
    var radius: CGFloat { ToolArcConfig.effectiveRadius(in:bounds) }
    var center: CGPoint {
        let distance = radius * cos(ToolArcConfig.sweep / 2)
        return CGPoint(x: anchor.x - sin(mid) * distance * (leftHanded ? -1 : 1), y: anchor.y + cos(mid) * distance)
    }
    var pitch: CGFloat { radius * ToolArcConfig.sweep / 4 }
    var initialCount: Int { min(4, count) }
    var initialRange: Range<Int> {
        let start = max(0, (count - initialCount) / 2)
        return start..<(start + initialCount)
    }
    var toolMid: CGFloat { CGFloat(initialRange.lowerBound + initialRange.upperBound - 1) / 2 }
    func delta(_ angle: CGFloat) -> CGFloat { atan2(sin(angle-mid), cos(angle-mid)) }
    func rawPosition(_ index: Int, count: Int, upper: Bool) -> CGPoint {
        let radius = self.radius + (upper ? ToolArcConfig.gap : 0)
        let angle = mid + (CGFloat(index) - (count == self.count ? toolMid : CGFloat(count-1)/2)) * pitch / radius
        return CGPoint(x: center.x + sin(angle) * radius * (leftHanded ? -1 : 1), y: center.y - cos(angle) * radius)
    }
    var translation: CGSize {
        var rect = CGRect.null
        let half = max(ToolArcConfig.sweep/2, (CGFloat(max(count-1,0))*pitch+ToolArcConfig.diameter)/radius/2)
        for step in 0...72 {
            let angle = mid-half + CGFloat(step)/72*half*2
            for r in [radius, radius+ToolArcConfig.gap] {
                let p = CGPoint(x:center.x+sin(angle)*r*(leftHanded ? -1 : 1),y:center.y-cos(angle)*r)
                rect = rect.union(CGRect(x:p.x,y:p.y,width:1,height:1))
            }
        }
        let inset = ToolArcConfig.safeMargin
        return CGSize(width: max(inset - rect.minX, min(0, bounds.width - inset - rect.maxX)),
                      height: max(inset - rect.minY, min(0, bounds.height - inset - rect.maxY)))
    }
    func position(_ index: Int, count: Int, upper: Bool) -> CGPoint {
        let p = rawPosition(index, count: count, upper: upper), t = translation
        return CGPoint(x: p.x + t.width, y: p.y + t.height)
    }
    func point(angle:CGFloat,radius:CGFloat) -> CGPoint {
        let t = translation
        return CGPoint(x:center.x+sin(angle)*radius*(leftHanded ? -1 : 1)+t.width,y:center.y-cos(angle)*radius+t.height)
    }
    func polar(_ p: CGPoint) -> (r: CGFloat, angle: CGFloat) {
        let t = translation
        let dx = (p.x - center.x - t.width) * (leftHanded ? -1 : 1), dy = p.y - center.y - t.height
        return (hypot(dx, dy), atan2(dx, -dy))
    }
    func index(at p: CGPoint, count: Int, upper: Bool) -> Int? {
        guard count > 0 else { return nil }
        let polar = polar(p), radius = self.radius + (upper ? ToolArcConfig.gap : 0)
        guard abs(polar.r - radius) <= ToolArcConfig.diameter / 2 else { return nil }
        let delta = delta(polar.angle)
        let value = delta * radius / pitch + (count == self.count ? toolMid : CGFloat(count-1)/2)
        let index = Int(value.rounded())
        guard (0..<count).contains(index), abs(value - CGFloat(index)) * pitch <= ToolArcConfig.diameter / 2 else { return nil }
        return index
    }
}
