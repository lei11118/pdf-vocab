import UIKit

/// Brush policies inspired by the supplied design document, not copied assets.
enum InkBrush {
    static func width(kind: InkStroke.Kind, base: Double, force: Double, altitude: Double) -> Double {
        let f = min(1, max(0, force))
        switch kind {
        case .brush: return base * (0.08 + 1.92 * pow(f, 1.4))
        case .pen: return base * (0.75 + 0.5 * f)
        case .marker: return base
        case .pencil: return base * (0.4 + 0.6 * f) * (1 + 0.65 * (1 - sin(altitude)))
        case .crayon: return base * (0.75 + 0.25 * f)
        default: return base * (0.16 + 1.64 * pow(f,0.75))
        }
    }

    static func normalizedPressure(force: Double, maximum: Double) -> Double {
        guard force.isFinite, maximum.isFinite, maximum > 0 else { return 0.5 }
        return min(1,max(0,force/maximum))
    }
    static func smoothed(_ points: [InkPoint]) -> [InkPoint] {
        guard points.count > 3 else { return points }
        // Interpolation alone passes every sample's positional noise through.
        // Smooth the control polygon first; retain both endpoints and metadata.
        var filtered = points
        for _ in 0..<2 {
            let source = filtered
            for i in 1..<(source.count-1) {
                filtered[i].x = (source[i-1].x + 2*source[i].x + source[i+1].x)/4
                filtered[i].y = (source[i-1].y + 2*source[i].y + source[i+1].y)/4
            }
        }
        let points = filtered
        var out: [InkPoint] = [points[0]]
        for i in 0..<(points.count-1) {
            let a=points[max(0,i-1)],b=points[i],c=points[i+1],d=points[min(points.count-1,i+2)]
            for step in 1...3 {
                let t=Double(step)/3, t2=t*t,t3=t2*t
                func value(_ a:Double,_ b:Double,_ c:Double,_ d:Double)->Double {
                    0.5*((2*b)+(-a+c)*t+(2*a-5*b+4*c-d)*t2+(-a+3*b-3*c+d)*t3)
                }
                var p=b
                p.x=value(a.x,b.x,c.x,d.x);p.y=value(a.y,b.y,c.y,d.y)
                p.width=b.width+(c.width-b.width)*t
                p.force=b.force+(c.force-b.force)*t
                out.append(p)
            }
        }
        return out
    }

    static func opacity(kind: InkStroke.Kind, colorAlpha: Double) -> Double {
        switch kind {
        case .marker: return min(0.3, colorAlpha)
        case .pencil: return min(0.8, colorAlpha)
        case .crayon: return min(0.9, colorAlpha)
        default: return colorAlpha
        }
    }
}

/// All operands are page coordinates; the eraser sweeps a capsule between samples.
enum InkEraser {
    static func distance(_ p: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        let t = length2 > 0 ? min(1, max(0, ((p.x-a.x)*dx + (p.y-a.y)*dy) / length2)) : 0
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }

    static func erase(_ strokes: [InkStroke], from a: CGPoint, to b: CGPoint,
                      radius: CGFloat, whole: Bool) -> (strokes: [InkStroke], changed: Bool) {
        var result: [InkStroke] = []
        var changed = false
        for stroke in strokes {
            guard !stroke.points.isEmpty else { result.append(stroke); continue }
            let reach = radius + CGFloat(stroke.points.map(\.width).max() ?? 0) / 2
            let swept = CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(a.x-b.x), height: abs(a.y-b.y)).insetBy(dx: -reach, dy: -reach)
            let xs = stroke.points.map(\.x), ys = stroke.points.map(\.y)
            let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: max(0.001, xs.max()! - xs.min()!), height: max(0.001, ys.max()! - ys.min()!))
            guard bounds.intersects(swept) else { result.append(stroke); continue }
            func hit(_ p: InkPoint) -> Bool { distance(p.cg, to: a, b) <= radius + CGFloat(p.width) / 2 }
            func mix(_ p: InkPoint, _ q: InkPoint, _ t: Double) -> InkPoint {
                var v = p
                v.x += (q.x-p.x)*t; v.y += (q.y-p.y)*t
                v.width += (q.width-p.width)*t; v.force += (q.force-p.force)*t
                v.time += (q.time-p.time)*t
                return v
            }
            var samples = [stroke.points[0]]
            for (p,q) in zip(stroke.points, stroke.points.dropFirst()) {
                let count = max(1, Int(ceil(hypot(q.x-p.x,q.y-p.y) / Double(max(0.25, radius / 3)))))
                for i in 1...count { samples.append(mix(p,q,Double(i)/Double(count))) }
            }
            guard samples.contains(where: hit) else { result.append(stroke); continue }
            changed = true
            if whole { continue }
            var run: [InkPoint] = []
            func flush() {
                guard !run.isEmpty else { return }
                if run.count == 1 { run.append(run[0]) }
                var piece = stroke; piece.points = run; result.append(piece); run.removeAll()
            }
            var previous = samples[0]
            var previousHit = hit(previous)
            if !previousHit { run.append(previous) }
            for point in samples.dropFirst() {
                let isHit = hit(point)
                if isHit != previousHit {
                    var lo = 0.0, hi = 1.0
                    for _ in 0..<12 {
                        let mid = (lo+hi)/2
                        if hit(mix(previous,point,mid)) == previousHit { lo = mid } else { hi = mid }
                    }
                    let boundary = mix(previous,point,(lo+hi)/2)
                    if isHit { run.append(boundary); flush() } else { run = [boundary] }
                }
                if !isHit { run.append(point) }
                previous = point; previousHit = isHit
            }
            flush()
        }
        return (result, changed)
    }
}
