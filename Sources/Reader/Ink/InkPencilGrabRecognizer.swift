import UIKit

/// v0.47.1:**只接 Pencil 的「抓笔」识别器**。
///
/// 为什么需要它:
/// 自研墨迹画布是铺在 `PDFView` 上的**视口层**。如果让它自己接管触摸,就只能靠
/// `hitTest` 里读 `event.allTouches` 判断"这是不是笔" —— 判错的两种后果都很糟:
/// 手指被吞(单指滑不动)、或笔没落到画布上(写不出字)。v0.46/v0.47.0 都栽在这里。
///
/// 这个识别器把"接笔"和"接手势"彻底分开:
/// - 挂在 `PDFView` 上 → 落点是页面视图(它的后代)也能收到,不依赖命中目标;
/// - `allowedTouchTypes = [.pencil]` → **手指的触摸根本不会进这里**,PDFView 自己的
///   滚动 / 捏合 / 选词保持原生行为,一行都不用改;
/// - 永远停在 `.possible`,从不识别成功 → 不取消任何系统手势,也不影响 PDFKit;
/// - `touchesBegan/Moved/Ended` 拿到的是真实 `UITouch`(force / altitudeAngle /
///   azimuthAngle / coalesced / predicted 全在),解析式描边需要的输入一个不少。
final class InkPencilGrabRecognizer: UIGestureRecognizer {

    var onBegan: ((UITouch, UIEvent?) -> Void)?
    var onMoved: ((Set<UITouch>, UIEvent?) -> Void)?
    var onEnded: ((Set<UITouch>, UIEvent?) -> Void)?
    var onCancelled: (() -> Void)?
    /// 只有书写模式 + 渲染器就绪时才要笔;否则原样放行(识别器本身不消费触摸,安全)
    var isActive: (() -> Bool)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    }

    private var active: Bool { isActive?() ?? true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard active else { return }
        guard let touch = touches.first(where: { $0.type == .pencil }) else { return }
        onBegan?(touch, event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard active else { return }
        onMoved?(touches, event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard active else { return }
        onEnded?(touches, event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onCancelled?()
    }

    override func reset() {
        super.reset()
        onCancelled?()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
