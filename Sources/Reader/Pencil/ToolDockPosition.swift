import SwiftUI

/// v0.24.0:工具条自由位置的存取与钳制。
///
/// 存在 UserDefaults 里的是**归一化比例**(x: 0…1 从左到右,y: 0…1 从底到顶),
/// 这样横竖屏切换 / 分屏尺寸变化 / 换一台 iPad 都能落到相对位置,而不是飞出去。
enum ToolDockPosition {

    private static func key(_ docSha: String, _ suffix: String) -> String {
        "pencil.doc.\(docSha).\(suffix)"
    }

    static func load(docSha: String, bounds: CGSize) -> CGSize {
        guard !docSha.isEmpty, bounds.width > 1, bounds.height > 1 else { return .zero }
        let defaults = UserDefaults.standard
        guard let fx = defaults.object(forKey: key(docSha, "dockX")) as? Double,
              let fy = defaults.object(forKey: key(docSha, "dockY")) as? Double else { return .zero }
        return CGSize(
            width: (CGFloat(fx) - 0.5) * bounds.width,
            height: CGFloat(fy) * bounds.height
        )
    }

    static func save(_ offset: CGSize, docSha: String, bounds: CGSize) {
        guard !docSha.isEmpty, bounds.width > 1, bounds.height > 1 else { return }
        let defaults = UserDefaults.standard
        defaults.set(Double(offset.width / bounds.width + 0.5), forKey: key(docSha, "dockX"))
        defaults.set(Double(offset.height / bounds.height), forKey: key(docSha, "dockY"))
    }

    /// 位置钳制:整条工具带(含展开样式层)不许出屏;向上最多到离顶 12pt。
    static func clamp(_ offset: CGSize, bounds: CGSize, dockSize: CGSize) -> CGSize {
        guard bounds.width > 1, bounds.height > 1 else { return .zero }
        let halfWidth = max((bounds.width - max(dockSize.width, 120)) / 2 - 8, 0)
        let maxUp = max(bounds.height - max(dockSize.height, 60) - 96, 0)
        return CGSize(
            width: min(max(offset.width, -halfWidth), halfWidth),
            height: min(max(offset.height, -maxUp), 0)
        )
    }

    /// 松手时的磁吸:靠近中线就吸回中线(工具带默认位置),免得歪一点点很难受。
    static func snapped(_ offset: CGSize, bounds: CGSize, dockSize: CGSize) -> CGSize {
        let clamped = clamp(offset, bounds: bounds, dockSize: dockSize)
        guard abs(clamped.width) < 46 else { return clamped }
        return CGSize(width: 0, height: clamped.height)
    }
}

/// 量出工具带的实际尺寸(展开样式层时会变高,钳制要用最新值)。
struct DockSizeReader: View {
    let onChange: (CGSize) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.size) }
                .onChange(of: proxy.size) { _, size in onChange(size) }
        }
    }
}
