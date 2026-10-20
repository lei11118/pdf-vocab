import UIKit

/// v0.18.0:只观察、不参与手势竞争的 Pencil 触摸追踪器。
///
/// 用途:「书写时贴边自动滚动」需要笔尖在屏幕上的连续位置,
/// 但**绝不能抢 PencilKit 的绘制手势**(抢了就会写不出字)。
/// 做法是始终保持 `.possible` 状态、永不识别,因此不会让任何其他手势失败。
final class PencilTouchObserver: UIGestureRecognizer {
    var onMove: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        report(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        report(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onEnd?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onEnd?()
    }

    private func report(_ touches: Set<UITouch>) {
        guard let touch = touches.first(where: { $0.type == .pencil }) ?? touches.first,
              let host = view else { return }
        onMove?(touch.location(in: host))
    }
}
