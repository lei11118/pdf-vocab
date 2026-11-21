import SwiftUI

private struct ReaderPanelCloseKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
private struct ReaderPanelTrailingInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var readerPanelTrailingInset: CGFloat {
        get { self[ReaderPanelTrailingInsetKey.self] }
        set { self[ReaderPanelTrailingInsetKey.self] = newValue }
    }

    var readerPanelClose: (() -> Void)? {
        get { self[ReaderPanelCloseKey.self] }
        set { self[ReaderPanelCloseKey.self] = newValue }
    }
}
extension View {
    func readerPanel<Content: View>(isPresented: Binding<Bool>, title: String,
                                   @ViewBuilder content: @escaping () -> Content) -> some View {
        overlay {
            if isPresented.wrappedValue {
                GeometryReader { geo in
                    ReaderCapsulePanel(title:title,bounds:geo.size,onClose:{isPresented.wrappedValue = false},content:content)
                        .environment(\.readerPanelClose,{isPresented.wrappedValue = false})
                }.transition(.opacity)
            }
        }
    }
}

/// A hosting boundary prevents child toolbar/navigation preferences and dismiss
/// actions from escaping into the document library's NavigationStack.
private struct ReaderPanelContent<Content:View>: UIViewControllerRepresentable {
    let content: Content
    func makeUIViewController(context:Context) -> UIHostingController<Content> {
        let host = UIHostingController(rootView:content)
        host.view.backgroundColor = .clear
        return host
    }
    func updateUIViewController(_ host:UIHostingController<Content>,context:Context) { host.rootView = content }
}

struct ReaderCapsulePanel<Content:View>: View {
    let title: String
    let bounds: CGSize
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.readerPanelTrailingInset) private var trailingInset

    var body: some View {
        let inset = min(trailingInset, max(0, bounds.width - 196))
        let available = CGSize(width: bounds.width - inset, height: bounds.height)
        ReaderWindowSurface(bounds:available,onClose:onClose,windowID:title,allowsCompact:false) {
            ReaderPanelContent(content:content().environment(\.readerPanelClose,onClose).tint(DS.accent))
        } compact: {
            EmptyView()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-panel.\(title)")
        .frame(width: available.width, alignment: .leading)
    }
}

/// Nested app panels use the same window only when reached from a reader.
private struct ReaderAwarePanel<Panel:View>:ViewModifier {
    @Environment(\.readerPanelClose) private var parentClose
    @Binding var presented:Bool
    let title:String
    @ViewBuilder var panel:() -> Panel
    @ViewBuilder func body(content:Content) -> some View {
        if parentClose != nil { content.readerPanel(isPresented:$presented,title:title,content:panel) }
        else { content.sheet(isPresented:$presented,content:panel) }
    }
}
extension View {
    func readerAwarePanel<Panel:View>(isPresented:Binding<Bool>,title:String,@ViewBuilder content:@escaping () -> Panel) -> some View {
        modifier(ReaderAwarePanel(presented:isPresented,title:title,panel:content))
    }
    func readerAwarePanel<Item:Identifiable,Panel:View>(item:Binding<Item?>,title:String,@ViewBuilder content:@escaping (Item) -> Panel) -> some View {
        readerAwarePanel(isPresented:Binding(get:{item.wrappedValue != nil},set:{if !$0 {item.wrappedValue = nil}}),title:title) {
            if let value = item.wrappedValue { content(value) }
        }
    }
}
