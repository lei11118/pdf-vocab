import UIKit

/// An analytical infinite line rendered inside the viewport. The pose is stored
/// in document coordinates and projected into the viewport after scroll/zoom.
final class SmartRulerView: UIView, UIGestureRecognizerDelegate {
    static let barHeight:CGFloat=80
    static let snapTargetsDegrees:[Double]=[0,30,45,60,90,120,135,180]
    static let snapToleranceDegrees:Double=3
    private weak var hostView:UIView?
    private weak var documentView:UIView?
    private var documentAnchor:CGPoint?
    private var documentAxis:CGPoint?
    private(set) var poseScale:CGFloat=1
    private var halfHeight:CGFloat { Self.barHeight*poseScale/2 }
    var angleLabel:String { String(format:"%.0f°",angleDegrees) }
    private(set) var rulerPosition=CGPoint.zero
    private(set) var angle:CGFloat=0
    var angleDegrees:Double { Double(angle)*180 / .pi }
    var rulerLength:CGFloat { hypot(bounds.width,bounds.height)*2 }
    var isOn=false { didSet { isHidden = !isOn;setNeedsDisplay() } }
    private(set) var measuredLength: CGFloat?
    private var measurementPoint: CGPoint?
    private var measurementRevision = 0
    private var dragOrigin=CGPoint.zero
    private var turnOrigin=CGPoint.zero
    private var turnPivot=CGPoint.zero
    private var turnAngle:CGFloat?
    private let haptic=UIImpactFeedbackGenerator(style:.light)
    private lazy var pan=UIPanGestureRecognizer(target:self,action:#selector(dragRuler(_:)))
    init(length:CGFloat,host:UIView) {
        hostView=host
        super.init(frame:host.bounds)
        backgroundColor = .clear;isOpaque=false;isHidden=true
        autoresizingMask=[.flexibleWidth,.flexibleHeight]
        rulerPosition=CGPoint(x:host.bounds.midX,y:host.bounds.midY)
        pan.maximumNumberOfTouches=2;pan.delegate=self
        pan.allowedTouchTypes=[NSNumber(value:UITouch.TouchType.direct.rawValue)];addGestureRecognizer(pan)
        let turn=UIRotationGestureRecognizer(target:self,action:#selector(rotate(_:)))
        turn.delegate=self;turn.allowedTouchTypes=pan.allowedTouchTypes;addGestureRecognizer(turn)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) unavailable") }
    func updateHostBounds() { if let hostView { frame=hostView.bounds };syncDocumentPose();setNeedsDisplay() }
    func bindDocument(_ view:UIView?) {
        if documentView !== view { documentView=view;captureDocumentPose() }
        syncDocumentPose()
    }
    private func captureDocumentPose() {
        guard let documentView else { return }
        documentAnchor=documentView.convert(rulerPosition,from:self)
        documentAxis=documentView.convert(CGPoint(x:rulerPosition.x+100*poseScale*cos(angle),y:rulerPosition.y+100*poseScale*sin(angle)),from:self)
    }
    func syncDocumentPose() {
        guard let documentView,let anchor=documentAnchor,let axis=documentAxis else { return }
        let a=convert(anchor,from:documentView),b=convert(axis,from:documentView)
        rulerPosition=a;angle=atan2(b.y-a.y,b.x-a.x)
        poseScale=max(0.01,hypot(b.x-a.x,b.y-a.y)/100);setNeedsDisplay()
    }
    func resetInHost() {
        updateHostBounds();poseScale=1;rulerPosition=CGPoint(x:bounds.midX,y:bounds.midY);angle=0;captureDocumentPose();setNeedsDisplay()
    }
    func setPose(position:CGPoint,angle:CGFloat) {
        guard position.x.isFinite,position.y.isFinite,angle.isFinite else { return }
        rulerPosition=position;self.angle=CGFloat(Self.normalizedAngle(Double(angle)));captureDocumentPose();setNeedsDisplay()
    }
    static func normalizedAngle(_ angle:Double)->Double {
        guard angle.isFinite else { return 0 }
        let value=angle.truncatingRemainder(dividingBy:.pi)
        return value<0 ? value + .pi : value
    }
    static func calculateSnappedAngle(current:Double)->(angle:Double,didSnap:Bool) {
        let value=normalizedAngle(current),degrees=value*180 / .pi
        if let target=snapTargetsDegrees.min(by:{ abs($0-degrees)<abs($1-degrees) }),abs(target-degrees)<=snapToleranceDegrees {
            return (normalizedAngle(target * .pi/180),true)
        }
        return (value,false)
    }
    func linePoints()->(CGPoint,CGPoint) {
        let dx=cos(angle)*rulerLength,dy=sin(angle)*rulerLength
        return (CGPoint(x:rulerPosition.x-dx,y:rulerPosition.y-dy),CGPoint(x:rulerPosition.x+dx,y:rulerPosition.y+dy))
    }
    private func signedDistance(_ p:CGPoint)->CGFloat { -(p.x-rulerPosition.x)*sin(angle)+(p.y-rulerPosition.y)*cos(angle) }
    func distanceToLine(from p:CGPoint)->CGFloat { abs(signedDistance(p)) }
    func projectOnLine(_ p:CGPoint)->CGPoint {
        let d=signedDistance(p);return CGPoint(x:p.x+d*sin(angle),y:p.y-d*cos(angle))
    }
    func projector(startingAt point:CGPoint)->((CGPoint)->CGPoint)? {
        guard isOn else { return nil }
        let distance=signedDistance(point),half=halfHeight
        guard abs(abs(distance)-half)<=18 else { return nil }
        let normal=CGPoint(x:-sin(angle),y:cos(angle)),direction=CGPoint(x:cos(angle),y:sin(angle))
        let origin=CGPoint(x:rulerPosition.x+normal.x*half*(distance<0 ? -1:1),y:rulerPosition.y+normal.y*half*(distance<0 ? -1:1))
        let start = (point.x-origin.x)*direction.x+(point.y-origin.y)*direction.y
        let scale = poseScale
        measurementRevision += 1
        return { [weak self] p in
            let t=(p.x-origin.x)*direction.x+(p.y-origin.y)*direction.y
            let projected = CGPoint(x:origin.x+t*direction.x,y:origin.y+t*direction.y)
            self?.measuredLength = abs(t-start)/scale
            self?.measurementPoint = CGPoint(x:projected.x-normal.x*(distance<0 ? -24:24),y:projected.y-normal.y*(distance<0 ? -24:24))
            self?.setNeedsDisplay()
            return projected
        }
    }
    func finishMeasurement() {
        measurementRevision += 1
        let revision = measurementRevision
        DispatchQueue.main.asyncAfter(deadline: .now()+0.8) { [weak self] in
            guard let self, self.measurementRevision == revision else { return }
            self.measuredLength = nil; self.measurementPoint = nil; self.setNeedsDisplay()
        }
    }
    override func point(inside point:CGPoint,with event:UIEvent?)->Bool {
        isOn && bounds.contains(point) && abs(signedDistance(point))<=halfHeight+6
    }
    @objc private func dragRuler(_ g:UIPanGestureRecognizer) {
        guard turnAngle==nil else { return }
        switch g.state {
        case .began:dragOrigin=rulerPosition
        case .changed:
            let t=g.translation(in:self);setPose(position:CGPoint(x:dragOrigin.x+t.x,y:dragOrigin.y+t.y),angle:angle)
        default:break
        }
    }
    @objc private func rotate(_ g:UIRotationGestureRecognizer) {
        switch g.state {
        case .began:turnAngle=angle;turnOrigin=rulerPosition;turnPivot=g.location(in:self)
        case .changed,.ended:
            guard let initial=turnAngle else { return }
            let pivot=g.location(in:self),rotation=g.rotation
            let dx=turnOrigin.x-turnPivot.x,dy=turnOrigin.y-turnPivot.y
            let snap=Self.calculateSnappedAngle(current:Double(initial+rotation))
            let p=CGPoint(x:pivot.x+dx*cos(rotation)-dy*sin(rotation),y:pivot.y+dx*sin(rotation)+dy*cos(rotation))
            if snap.didSnap && abs(Double(angle)-snap.angle)>0.01 { haptic.impactOccurred() }
            setPose(position:p,angle:CGFloat(snap.angle))
            if g.state == .ended { turnAngle=nil;dragOrigin=rulerPosition;pan.setTranslation(.zero,in:self) }
        case .cancelled,.failed:turnAngle=nil;dragOrigin=rulerPosition;pan.setTranslation(.zero,in:self)
        default:break
        }
    }
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith other:UIGestureRecognizer)->Bool { other.view === self }
    override func draw(_ rect:CGRect) {
        guard isOn,let ctx=UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState();ctx.translateBy(x:rulerPosition.x,y:rulerPosition.y);ctx.rotate(by:angle)
        ctx.scaleBy(x:poseScale,y:poseScale)
        let corners=[CGPoint.zero,CGPoint(x:bounds.maxX,y:0),CGPoint(x:0,y:bounds.maxY),CGPoint(x:bounds.maxX,y:bounds.maxY)]
        let xs=corners.map { (($0.x-rulerPosition.x)*cos(angle)+($0.y-rulerPosition.y)*sin(angle))/poseScale }
        let lo=(xs.min() ?? 0)-80,hi=(xs.max() ?? 0)+80,half=Self.barHeight/2
        ctx.setFillColor(UIColor.secondarySystemBackground.withAlphaComponent(0.7).cgColor)
        ctx.fill(CGRect(x:lo,y:-half,width:hi-lo,height:Self.barHeight))
        ctx.setStrokeColor(UIColor.label.withAlphaComponent(0.35).cgColor);ctx.setLineWidth(0.75)
        for y in [-half,half] { ctx.move(to:CGPoint(x:lo,y:y));ctx.addLine(to:CGPoint(x:hi,y:y));ctx.strokePath() }
        var tick=Int(floor(lo/10))
        while CGFloat(tick)*10<hi {
            let x=CGFloat(tick)*10,length:CGFloat=tick%5==0 ? 14:7
            ctx.move(to:CGPoint(x:x,y:-half));ctx.addLine(to:CGPoint(x:x,y:-half+length));ctx.strokePath()
            ctx.move(to:CGPoint(x:x,y:half));ctx.addLine(to:CGPoint(x:x,y:half-length));ctx.strokePath()
            if tick%5==0 { (String(tick*10) as NSString).draw(at:CGPoint(x:x+2,y:-half+17),withAttributes:[.font:UIFont.monospacedDigitSystemFont(ofSize:9,weight:.medium),.foregroundColor:UIColor.secondaryLabel]) }
            tick+=1
        }
        ctx.restoreGState()
        // Labels stay upright and readable; the ruler's document pose is unchanged.
        drawBadge(angleLabel, at: rulerPosition, circular: true)
        if let measuredLength, let measurementPoint {
            drawBadge(String(format: "%.0f pt", measuredLength), at: measurementPoint, circular: false)
        }
    }
    private func drawBadge(_ text: String, at point: CGPoint, circular: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: UIColor.label]
        let size = (text as NSString).size(withAttributes: attrs)
        let width = circular ? max(42,size.width+16) : size.width+16
        let height: CGFloat = circular ? 42 : 28
        let center = CGPoint(x: min(max(point.x,width/2+4),bounds.width-width/2-4), y: min(max(point.y,height/2+4),bounds.height-height/2-4))
        let rect = CGRect(x:center.x-width/2,y:center.y-height/2,width:width,height:height)
        UIColor.secondarySystemBackground.withAlphaComponent(0.96).setFill()
        UIBezierPath(roundedRect:rect,cornerRadius:height/2).fill()
        (text as NSString).draw(at:CGPoint(x:rect.midX-size.width/2,y:rect.midY-size.height/2),withAttributes:attrs)
    }
}
