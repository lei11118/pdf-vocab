import SwiftUI

/// v0.11.0(M4-B):Pencil 悬停迷你释义气泡(选词模式,悬停约 0.5s 出现;纯展示,不拦截触摸)。
struct HoverTipView: View {
    let term: String
    let detail: String
    let anchor: CGPoint
    let bounds: CGSize

    private var bubbleX: CGFloat {
        min(max(anchor.x, 110), max(bounds.width - 110, 110))
    }

    private var bubbleY: CGFloat {
        max(anchor.y - 46, 34)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(term)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(radius: 6, y: 2)
        .position(x: bubbleX, y: bubbleY)
        .allowsHitTesting(false)
    }
}
