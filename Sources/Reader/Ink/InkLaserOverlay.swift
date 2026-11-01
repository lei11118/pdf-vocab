import UIKit

/// All visible laser strokes share an idle deadline. A new stroke revives the
/// group until that deadline has completely elapsed; expired strokes stay gone.
final class InkLaserOverlay: UIView {
    private var trails: [[CGPoint]] = []
    private let beam = CAShapeLayer()
    private var fade: DispatchWorkItem?
    private var expiresAt: CFTimeInterval?
    private var generation = 0
    private let duration: CFTimeInterval = 0.65
    var pointCount: Int { trails.reduce(0) { $0 + $1.count } }
    var strokeCount: Int { trails.count }
    var now: () -> CFTimeInterval = { CACurrentMediaTime() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; backgroundColor = .clear
        beam.fillColor = UIColor.clear.cgColor; beam.strokeColor = UIColor.systemRed.cgColor
        beam.lineWidth = 3; beam.lineCap = .round; beam.lineJoin = .round
        beam.shadowColor = UIColor.systemRed.cgColor; beam.shadowRadius = 6; beam.shadowOpacity = 0.8
        layer.addSublayer(beam)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func begin(at point: CGPoint) {
        if let expiresAt, now() >= expiresAt { clear() }
        generation += 1; fade?.cancel(); fade = nil; expiresAt = nil
        beam.removeAnimation(forKey: "fade")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        beam.opacity = 1
        trails.append([point]); drawTrail()
        CATransaction.commit()
    }
    func append(_ point: CGPoint) {
        guard !trails.isEmpty else { return }
        trails[trails.count - 1].append(point)
        drawTrail()
    }
    func finish() {
        guard !trails.isEmpty else { return }
        fade?.cancel(); generation += 1
        let token = generation
        expiresAt = now() + duration
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1; opacity.toValue = 0; opacity.duration = duration
        CATransaction.begin(); CATransaction.setDisableActions(true)
        beam.opacity = 0; beam.add(opacity, forKey: "fade")
        CATransaction.commit()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.clear()
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
    func clear() {
        generation += 1; fade?.cancel(); fade = nil; expiresAt = nil; trails = []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        beam.removeAllAnimations(); beam.path = nil; beam.opacity = 0
        CATransaction.commit()
    }
    private func drawTrail() {
        let path = UIBezierPath()
        for points in trails {
            guard let first = points.first else { continue }
            path.move(to: first)
            if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
            else { points.dropFirst().forEach { path.addLine(to: $0) } }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        beam.path = path.cgPath
        CATransaction.commit()
    }
}
