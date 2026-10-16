import UIKit

/// v0.11.0(M4-B):Pencil Pro / 妙控键盘触控板触觉反馈(iPadOS 17.5+ 的 `UICanvasFeedbackGenerator`)。
/// 说明:仅 iPad + Apple Pencil(Pro)/触控板硬件上有实际效果;手指与 iPhone 无触觉——
/// 按 Apple 建议"信任系统"不判断设备,系统自行决定是否播放。
enum PencilHaptics {
    private static let canvas = UICanvasFeedbackGenerator()

    /// 选词完成(拖选/双击/三击手势结束)
    static func selectionCompleted(at point: CGPoint) {
        canvas.prepare()
        canvas.pathCompleted(at: point)
    }

    /// 加入生词本成功
    static func collected(at point: CGPoint) {
        canvas.prepare()
        canvas.alignmentOccurred(at: point)
    }
}
