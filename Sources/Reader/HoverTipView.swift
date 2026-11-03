import SwiftUI

/// The source adapter supplies the TOP of the actual word rectangle, not the pen tip.
struct HoverTipView: View {
    let term: String
    let detail: String
    let anchor: CGPoint
    let bounds: CGSize
    private var width: CGFloat { min(340, max(120, bounds.width - 16)) }
    private var height: CGFloat { min(300, max(0, anchor.y - 12)) }
    var body: some View {
        if height >= 36 {
            WordBubbleContent(term: term, detail: detail)
                .frame(width: width, height: height)
                .position(x: min(max(anchor.x, width/2+8), max(width/2+8, bounds.width-width/2-8)),
                          y: anchor.y - 8 - height/2)
        }
    }
}

struct WordBubbleContent: View {
    let term: String
    let detail: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(term).font(.subheadline.weight(.semibold))
                    Button { WordInteraction.speak(term) } label: { Image(systemName: "speaker.wave.2.fill") }
                        .accessibilityLabel("朗读")
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(radius: 6, y: 2)
    }
}
