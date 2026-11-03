import SwiftUI

private struct ReaderPanelCloseKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
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
    var body: some View {
        ReaderWindowSurface(bounds:bounds,onClose:onClose) {
            ReaderPanelContent(content:content().environment(\.readerPanelClose,onClose))
        } compact: {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Button(action:onClose) { Image(systemName:"xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("关闭窗口")
            }.padding(.leading,16).padding(.trailing,52)
        }
    }
}
