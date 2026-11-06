import SwiftUI
import UIKit

enum HoverBubbleLayout {
    static func size(term:String, detail:String, maximumWidth:CGFloat, maximumHeight:CGFloat,
                     contextualCandidate: String? = nil) -> CGSize {
        let titleFont = UIFont.preferredFont(forTextStyle:.subheadline)
        let detailFont = UIFont.preferredFont(forTextStyle:.caption1)
        let limit = max(1,min(380,maximumWidth))
        let detailWidth = detail.components(separatedBy:.newlines).map {
            ($0 as NSString).size(withAttributes:[.font:detailFont]).width
        }.max() ?? 0
        let candidateWidth = contextualCandidate.map {
            ($0 as NSString).size(withAttributes:[.font:detailFont]).width
        } ?? 0
        let naturalWidth = max((term as NSString).size(withAttributes:[.font:titleFont]).width,
                               max(detailWidth, candidateWidth))
        let width = min(limit,max(150,ceil(naturalWidth)+24))
        func height(_ text:String,_ font:UIFont) -> CGFloat {
            ceil((text as NSString).boundingRect(with:CGSize(width:max(1,width-24),height:.greatestFiniteMagnitude),
                options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font],context:nil).height)
        }
        let candidateHeight = contextualCandidate.map { 8 + min(64, height($0, detailFont)) } ?? 0
        return CGSize(width:width,height:min(maximumHeight,
            24+8+height(term,titleFont)+height(detail,detailFont)+candidateHeight))
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
                               contextualCandidate: contextualCandidate)
    }
    var body: some View {
        if size.height >= 36 {
            WordBubbleContent(term: term,
                              detail: detail,
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
    var contextualSelection: ContextualSelection? = nil
    var contextualTranslationEnabled = false
    var contextualDriver: ContextualTranslationDriver? = nil
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text(term).font(.subheadline.weight(.semibold)).fixedSize(horizontal:false,vertical:true)
            if let contextualSelection, let contextualDriver {
                ContextualTranslationTaskView(selection: contextualSelection,
                                              isEnabled: contextualTranslationEnabled,
                                              presentation: .hover,
                                              driver: contextualDriver)
            }
            DefinitionScrollText(text:detail).frame(maxWidth:.infinity,maxHeight:.infinity)
        }.padding(12)
        .foregroundStyle(DS.foreground1)
        .background(DS.background3,in:RoundedRectangle(cornerRadius:16,style:.continuous))
        .shadow(color:.black.opacity(0.12),radius:12,y:5)
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
