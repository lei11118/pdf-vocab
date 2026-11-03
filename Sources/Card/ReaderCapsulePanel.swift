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

/// One shell for all reader-owned panels: stable global gestures, persistent content.
/// System document/share pickers retain the OS presentation required by UIKit.
struct ReaderCapsulePanel<Content: View>: View {
    let title: String
    let bounds: CGSize
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var size = CGSize(width:620,height:640)
    @State private var origin = CGPoint(x:24,y:80)
    @State private var dragBase: CGPoint?
    @State private var resizeBase: CGSize?
    @State private var collapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var actualSize: CGSize {
        CGSize(width:min(max(220,size.width),max(220,bounds.width-16)),
               height:collapsed ? 52 : min(max(200,size.height),max(200,bounds.height-16)))
    }
    private var actualOrigin: CGPoint {
        CGPoint(x:min(max(8,origin.x),max(8,bounds.width-actualSize.width-8)),
                y:min(max(8,origin.y),max(8,bounds.height-actualSize.height-8)))
    }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"line.3.horizontal").foregroundStyle(.secondary)
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength:0)
                Button { withAnimation(reduceMotion ? nil : .snappy(duration:0.2)) { collapsed.toggle() } } label: {
                    Image(systemName:collapsed ? "arrow.up.left.and.arrow.down.right" : "minus")
                }.accessibilityLabel(collapsed ? "展开窗口" : "折叠窗口")
                Button(action:onClose) { Image(systemName:"xmark") }.accessibilityLabel("关闭窗口")
            }
            .padding(.horizontal,16).frame(height:52).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:2,coordinateSpace:.global).onChanged { value in
                if dragBase == nil { dragBase = actualOrigin }
                origin = CGPoint(x:dragBase!.x+value.translation.width,y:dragBase!.y+value.translation.height)
            }.onEnded { _ in origin = actualOrigin; dragBase = nil })
            content().frame(maxWidth:.infinity,maxHeight:.infinity)
                .opacity(collapsed ? 0 : 1).allowsHitTesting(!collapsed)
        }
        .frame(width:actualSize.width,height:actualSize.height,alignment:.top)
        .background(.regularMaterial,in:RoundedRectangle(cornerRadius:collapsed ? 26 : 30,style:.continuous))
        .clipShape(RoundedRectangle(cornerRadius:collapsed ? 26 : 30,style:.continuous))
        .overlay(alignment:.bottomTrailing) {
            if !collapsed {
                Image(systemName:"arrow.up.left.and.arrow.down.right").font(.caption)
                    .frame(width:44,height:44).background(.thinMaterial,in:Circle()).contentShape(Rectangle())
                    .highPriorityGesture(DragGesture(minimumDistance:1,coordinateSpace:.global).onChanged { value in
                        if resizeBase == nil { resizeBase = actualSize }
                        size = CGSize(width:resizeBase!.width+value.translation.width,height:resizeBase!.height+value.translation.height)
                    }.onEnded { _ in size = actualSize; resizeBase = nil })
                    .accessibilityLabel("拖动调整窗口大小")
            }
        }
        .shadow(color:.black.opacity(0.18),radius:16,y:5)
        .position(x:actualOrigin.x+actualSize.width/2,y:actualOrigin.y+actualSize.height/2)
        .onAppear {
            size = CGSize(width:min(720,bounds.width-32),height:min(740,bounds.height-80))
            origin = CGPoint(x:(bounds.width-size.width)/2,y:40)
        }
    }
}
