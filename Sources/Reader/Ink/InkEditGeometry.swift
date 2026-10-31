import UIKit

enum InkEditGeometry {
    static func bounds(_ points: [CGPoint]) -> CGRect {
        points.reduce(CGRect.null) { $0.union(CGRect(origin: $1,size: CGSize(width: 0.01,height: 0.01))) }
    }
    static func intersects(_ points: [CGPoint], polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3, !points.isEmpty else { return false }
        let path = UIBezierPath(); path.move(to: polygon[0])
        polygon.dropFirst().forEach { path.addLine(to: $0) }; path.close()
        if points.contains(where: { path.contains($0) }) { return true }
        func cross(_ a: CGPoint,_ b: CGPoint,_ c: CGPoint) -> CGFloat {
            (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
        }
        for (a,b) in zip(points,points.dropFirst()) {
            for i in polygon.indices {
                let c = polygon[i], d = polygon[(i+1)%polygon.count]
                if max(a.x,b.x) < min(c.x,d.x) || max(c.x,d.x) < min(a.x,b.x) ||
                   max(a.y,b.y) < min(c.y,d.y) || max(c.y,d.y) < min(a.y,b.y) { continue }
                if cross(a,b,c)*cross(a,b,d) <= 0 && cross(c,d,a)*cross(c,d,b) <= 0 { return true }
            }
        }
        return false
    }
    static func shape(_ kind: PencilShapeKind, from a: CGPoint, to b: CGPoint) -> [[CGPoint]] {
        let r = CGRect(x: min(a.x,b.x),y: min(a.y,b.y),width: abs(b.x-a.x),height: abs(b.y-a.y))
        switch kind {
        case .line: return [[a,b]]
        case .rect: return [[CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY),CGPoint(x:r.minX,y:r.minY)]]
        case .ellipse:
            return [(0...96).map { i in let t = Double(i)/96 * 2 * Double.pi
                return CGPoint(x:r.midX+cos(t)*r.width/2,y:r.midY+sin(t)*r.height/2) }]
        case .arrow:
            let angle = atan2(b.y-a.y,b.x-a.x), length = min(24,max(8,hypot(b.x-a.x,b.y-a.y)*0.22))
            return [[a,b],[CGPoint(x:b.x-length*cos(angle-0.5),y:b.y-length*sin(angle-0.5)),b,
                           CGPoint(x:b.x-length*cos(angle+0.5),y:b.y-length*sin(angle+0.5))]]
        }
    }
    static func resize(bounds r: CGRect, corner: CGPoint, to point: CGPoint) -> CGAffineTransform {
        let anchor = CGPoint(x: corner.x < r.midX ? r.maxX : r.minX,y: corner.y < r.midY ? r.maxY : r.minY)
        let initial = max(1,hypot(corner.x-anchor.x,corner.y-anchor.y))
        let scale = min(8,max(0.1,hypot(point.x-anchor.x,point.y-anchor.y)/initial))
        return CGAffineTransform(translationX: -anchor.x,y: -anchor.y)
            .concatenating(CGAffineTransform(scaleX: scale,y: scale))
            .concatenating(CGAffineTransform(translationX: anchor.x,y: anchor.y))
    }
}

/// Only the selected ink and its visible handles intercept finger input.
final class InkEditingOverlay: UIView {
    var selection = CGRect.null { didSet { setNeedsDisplay() } }
    var preview: [[CGPoint]] = [] { didSet { setNeedsDisplay() } }
    var previewColor: UIColor = .systemBlue
    var previewWidth: CGFloat = 2
    var onBegin: (() -> Void)?
    var onChange: ((CGAffineTransform) -> Void)?
    var onEnd: ((Bool) -> Void)?
    private var start = CGPoint.zero
    private var initial = CGRect.null
    private var corner: CGPoint?
    lazy var pan = UIPanGestureRecognizer(target:self,action:#selector(drag(_:)))
    var corners: [CGPoint] {
        guard !selection.isNull else { return [] }
        return [CGPoint(x:selection.minX,y:selection.minY),CGPoint(x:selection.maxX,y:selection.minY),
                CGPoint(x:selection.minX,y:selection.maxY),CGPoint(x:selection.maxX,y:selection.maxY)]
    }
    override init(frame: CGRect) {
        super.init(frame:frame); backgroundColor = .clear; isOpaque = false
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = [NSNumber(value:UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !isHidden && !selection.isNull && selection.insetBy(dx:-24,dy:-24).contains(point)
    }
    func begin(at point: CGPoint) {
        start = point; initial = selection
        corner = corners.min(by:{ hypot($0.x-point.x,$0.y-point.y)<hypot($1.x-point.x,$1.y-point.y) })
        if let c = corner, hypot(c.x-point.x,c.y-point.y)>24 { corner = nil }
        onBegin?()
    }
    func move(to point: CGPoint) {
        let t = corner.map { InkEditGeometry.resize(bounds:initial,corner:$0,to:point) }
            ?? CGAffineTransform(translationX:point.x-start.x,y:point.y-start.y)
        onChange?(t)
    }
    @objc private func drag(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: begin(at:g.location(in:self))
        case .changed: move(to:g.location(in:self))
        case .ended: move(to:g.location(in:self)); onEnd?(false)
        case .cancelled,.failed: onEnd?(true)
        default: break
        }
    }
    override func draw(_ rect: CGRect) {
        if !selection.isNull {
            UIColor.systemBlue.setStroke()
            let path = UIBezierPath(rect:selection); path.lineWidth = 1.5; path.setLineDash([5,3],count:2,phase:0); path.stroke()
            for p in corners {
                UIColor.white.setFill(); let dot=UIBezierPath(ovalIn:CGRect(x:p.x-6,y:p.y-6,width:12,height:12)); dot.fill(); dot.stroke()
            }
        }
        previewColor.setStroke()
        for points in preview where !points.isEmpty {
            let path = UIBezierPath(); path.move(to:points[0]); points.dropFirst().forEach { path.addLine(to:$0) }
            path.lineWidth = previewWidth; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
        }
    }
}
