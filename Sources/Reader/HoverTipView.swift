import SwiftUI
import UIKit

enum HoverBubbleLayout {
    static func size(term:String, detail:String, maximumWidth:CGFloat, maximumHeight:CGFloat,
                     contextualCandidate: String? = nil,
                     hasContextualSection: Bool = false) -> CGSize {
        let titleFont = UIFont.preferredFont(forTextStyle:.subheadline)
        let detailFont = UIFont.preferredFont(forTextStyle:.caption1)
        let contextLabelFont = UIFont.preferredFont(forTextStyle:.caption2)
        let limit = max(1,min(380,maximumWidth))
        let detailWidth = detail.components(separatedBy:.newlines).map {
            ($0 as NSString).size(withAttributes:[.font:detailFont]).width
        }.max() ?? 0
        let candidateWidth = contextualCandidate.map {
            ($0 as NSString).size(withAttributes:[.font:detailFont]).width
        } ?? 0
        let candidateLabelWidth = contextualCandidate.map {
            ("语境译义" as NSString).size(withAttributes:[.font:contextLabelFont]).width
        } ?? 0
        let naturalWidth = max((term as NSString).size(withAttributes:[.font:titleFont]).width,
                               max(detailWidth, max(candidateWidth, candidateLabelWidth)))
        let width = min(limit,max(150,ceil(naturalWidth)+24))
        func height(_ text:String,_ font:UIFont) -> CGFloat {
            ceil((text as NSString).boundingRect(with:CGSize(width:max(1,width-24),height:.greatestFiniteMagnitude),
                options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font],context:nil).height)
        }
        let candidateHeight = contextualCandidate.map {
            height("语境译义", contextLabelFont) + 4 + height($0, detailFont)
        } ?? 0
        let contextualSectionVisible = hasContextualSection || contextualCandidate != nil
        let spacingHeight = CGFloat(contextualSectionVisible ? 2 : 1) * 8
        return CGSize(width:width,height:min(maximumHeight,
            24+spacingHeight+height(term,titleFont)+height(detail,detailFont)+candidateHeight))
    }
}

/// The source adapter supplies the TOP of the actual word rectangle, not the pen tip.
struct HoverTipView: View {
    let term: String
    let detail: String
    let anchor: CGPoint
    let bounds: CGSize
    var contextualSelection: ContextualSelection? = nil
    var contextualTranslationEnabled = false
    @StateObject private var contextualDriver = ContextualTranslationDriver()

    private var contextualCandidate: String? {
        guard case .candidate(let candidate) = contextualDriver.state else { return nil }
        return candidate.translatedPhrase
    }

    private var size: CGSize {
        HoverBubbleLayout.size(term: term,
                               detail: detail,
                               maximumWidth: bounds.width - 16,
                               maximumHeight: min(420, max(0, anchor.y - 12)),
                               contextualCandidate: contextualCandidate,
                               hasContextualSection: contextualSelection != nil)
    }
    var body: some View {
        if size.height >= 36 {
            WordBubbleContent(term: term,
                              detail: detail,
                              contextualCandidate: contextualCandidate,
                              contextualSelection: contextualSelection,
                              contextualTranslationEnabled: contextualTranslationEnabled,
                              contextualDriver: contextualDriver)
                .frame(width:size.width,height:size.height)
                .position(x:min(max(anchor.x,size.width/2+8),max(size.width/2+8,bounds.width-size.width/2-8)),
                          y:anchor.y-8-size.height/2)
        }
    }
}

struct WordBubbleContent: View {
    let term: String
    let detail: String
    var contextualCandidate: String? = nil
    var contextualSelection: ContextualSelection? = nil
    var contextualTranslationEnabled = false
    var contextualDriver: ContextualTranslationDriver? = nil
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment:.leading,spacing:8) {
                Text(term).font(.subheadline.weight(.semibold)).fixedSize(horizontal:false,vertical:true)
                if let contextualSelection, let contextualDriver {
                    ContextualTranslationTaskView(selection: contextualSelection,
                                                  isEnabled: contextualTranslationEnabled,
                                                  presentation: .hover,
                                                  driver: contextualDriver)
                } else if let contextualCandidate {
                    ContextualTranslationHoverText(phrase: contextualCandidate)
                }
                DefinitionScrollText(text:detail,isScrollable:false)
                    .frame(maxWidth:.infinity)
                    .accessibilityIdentifier("hover-dictionary-definition")
            }
            .padding(12)
        }
        .accessibilityElement(children:.contain)
        .accessibilityIdentifier("word-bubble-scroll-content")
        .foregroundStyle(DS.foreground1)
        .background(DS.background3,in:RoundedRectangle(cornerRadius:16,style:.continuous))
        .shadow(color:.black.opacity(0.12),radius:12,y:5)
    }
}

/// Native text layout avoids selected-text snapshot rendering; non-scrolling callers can
/// measure full content and let their enclosing surface provide the scroll interaction.
struct DefinitionScrollText: UIViewRepresentable {
    let text: String
    var isScrollable = true
    func makeUIView(context:Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = isScrollable
        view.backgroundColor = .clear; view.textColor = .secondaryLabel
        view.font = .preferredFont(forTextStyle:.caption1); view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow,for:.vertical)
        return view
    }
    func updateUIView(_ view:UITextView,context:Context) {
        if view.text != text { view.text = text; view.setContentOffset(.zero,animated:false) }
        view.isScrollEnabled = isScrollable
    }
    func sizeThatFits(_ proposal:ProposedViewSize,uiView:UITextView,context:Context) -> CGSize? {
        guard !isScrollable, let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width:width,height:CGFloat.greatestFiniteMagnitude))
        return CGSize(width:width,height:ceil(size.height))
    }
}
