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
        VStack(alignment:.leading,spacing:8) {
            HStack(alignment:.firstTextBaseline) {
                Text(term).font(.subheadline.weight(.semibold))
                Button { WordInteraction.speak(term) } label: { Image(systemName:"speaker.wave.2.fill") }
                    .accessibilityLabel("朗读")
            }
            DefinitionScrollText(text:detail).frame(maxWidth:.infinity,maxHeight:.infinity)
        }.padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(radius: 6, y: 2)
    }
}

/// Native text layout keeps an arbitrarily long definition visible and scrollable
/// inside a bounded hover window; it does not depend on Text's selected-text snapshot rendering.
struct DefinitionScrollText: UIViewRepresentable {
    let text: String
    func makeUIView(context:Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = true
        view.backgroundColor = .clear; view.textColor = .secondaryLabel
        view.font = .preferredFont(forTextStyle:.caption1); view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow,for:.vertical)
        return view
    }
    func updateUIView(_ view:UITextView,context:Context) {
        if view.text != text { view.text = text; view.setContentOffset(.zero,animated:false) }
    }
}
