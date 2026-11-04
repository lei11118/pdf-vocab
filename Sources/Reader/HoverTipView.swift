import SwiftUI
import UIKit

enum HoverBubbleLayout {
    static func size(term:String, detail:String, maximumWidth:CGFloat, maximumHeight:CGFloat) -> CGSize {
        let titleFont = UIFont.preferredFont(forTextStyle:.subheadline)
        let detailFont = UIFont.preferredFont(forTextStyle:.caption1)
        let limit = max(1,min(380,maximumWidth))
        let naturalWidth = max((term as NSString).size(withAttributes:[.font:titleFont]).width,
                               detail.components(separatedBy:.newlines).map { ($0 as NSString).size(withAttributes:[.font:detailFont]).width }.max() ?? 0)
        let width = min(limit,max(150,ceil(naturalWidth)+24))
        func height(_ text:String,_ font:UIFont) -> CGFloat {
            ceil((text as NSString).boundingRect(with:CGSize(width:max(1,width-24),height:.greatestFiniteMagnitude),
                options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font],context:nil).height)
        }
        return CGSize(width:width,height:min(maximumHeight,24+8+height(term,titleFont)+height(detail,detailFont)))
    }
}

/// The source adapter supplies the TOP of the actual word rectangle, not the pen tip.
struct HoverTipView: View {
    let term: String
    let detail: String
    let anchor: CGPoint
    let bounds: CGSize
    private var size: CGSize { HoverBubbleLayout.size(term:term,detail:detail,maximumWidth:bounds.width-16,
        maximumHeight:min(420,max(0,anchor.y-12))) }
    var body: some View {
        if size.height >= 36 {
            WordBubbleContent(term: term, detail: detail)
                .frame(width:size.width,height:size.height)
                .position(x:min(max(anchor.x,size.width/2+8),max(size.width/2+8,bounds.width-size.width/2-8)),
                          y:anchor.y-8-size.height/2)
        }
    }
}

struct WordBubbleContent: View {
    let term: String
    let detail: String
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text(term).font(.subheadline.weight(.semibold)).fixedSize(horizontal:false,vertical:true)
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
