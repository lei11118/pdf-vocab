import UIKit

/// Ephemeral viewport effects are deliberately outside the persisted ink model.
final class InkLaserOverlay:UIView {
    private var points:[CGPoint]=[]
    private let beam=CAShapeLayer()
    private var fade:DispatchWorkItem?
    var pointCount:Int { points.count }
    override init(frame:CGRect) {
        super.init(frame:frame);isUserInteractionEnabled=false;backgroundColor = .clear
        beam.fillColor=UIColor.clear.cgColor;beam.strokeColor=UIColor.systemRed.cgColor
        beam.lineWidth=3;beam.lineCap = .round;beam.lineJoin = .round
        beam.shadowColor=UIColor.systemRed.cgColor;beam.shadowRadius=6;beam.shadowOpacity=0.8
        layer.addSublayer(beam)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) unavailable") }
    func begin(at point:CGPoint) { clear();points=[point];beam.opacity=1;drawTrail() }
    func append(_ point:CGPoint) {
        points.append(point);if points.count>192 { points.removeFirst(points.count-192) };drawTrail()
    }
    func finish() {
        let opacity=CABasicAnimation(keyPath:"opacity");opacity.fromValue=1;opacity.toValue=0;opacity.duration=0.65
        beam.add(opacity,forKey:"fade");beam.opacity=0
        let work=DispatchWorkItem { [weak self] in self?.clear() };fade=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.7,execute:work)
    }
    func clear() { fade?.cancel();fade=nil;points=[];beam.removeAllAnimations();beam.path=nil;beam.opacity=0 }
    private func drawTrail() {
        guard let p=points.first else { return }
        let path=UIBezierPath()
        if points.count==1 { path.append(UIBezierPath(ovalIn:CGRect(x:p.x-1,y:p.y-1,width:2,height:2))) }
        else { path.move(to:p);points.dropFirst().forEach { path.addLine(to:$0) } }
        beam.path=path.cgPath
    }
}
