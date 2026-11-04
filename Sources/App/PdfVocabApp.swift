import SwiftUI
import UIKit

@main
struct PdfVocabApp: App {
    private let store: DocumentStore?

    init() {
        RuntimeDiagnostics.beginSession()
        self.store = AppDatabase.shared.map { DocumentStore(db: $0) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        DiagLog.log("app launched v\(version)")
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--gesture-audit") {
                ReaderGestureAuditView()
            } else {
                appContent
            }
            #else
            appContent
            #endif
        }
    }
    @ViewBuilder private var appContent:some View {
            if let store {
                LibraryView(store: store)
                    .tint(DS.accent)
                    .buttonStyle(DSPressableButtonStyle())
                    .preferredColorScheme(nil)
            } else {
                ContentUnavailableView(
                    "数据库打开失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text("请重启 App;若问题持续,请反馈。")
                )
            }
    }
}

#if DEBUG
/// Deterministic composition for real XCUITest drags, using the production
/// window, menu and arc input components rather than mocked gesture handlers.
private struct ReaderGestureAuditView:View {
    @StateObject private var session = PencilToolSession()
    init() {
        for (key,value) in ["X":48.0,"Y":200.0,"W":300.0,"H":96.0] {
            UserDefaults.standard.set(value,forKey:"readerWindow.gesture-audit."+key)
        }
    }
    var body:some View {
        GeometryReader { geo in
            ZStack {
                SelectionBarAuditHost().frame(maxWidth:.infinity,maxHeight:.infinity)
                ReaderWindowSurface(bounds:geo.size,onClose:{},windowID:"gesture-audit") {
                    Text("完整词卡").frame(maxWidth:.infinity,maxHeight:.infinity)
                } compact: { Text("function 函数").frame(maxWidth:.infinity,maxHeight:.infinity) }
                PencilArcMenu(session:session,anchor:CGPoint(x:geo.size.width*0.72,y:geo.size.height*0.64),bounds:geo.size,onDismiss:{})
            }
        }.background(DS.background1)
    }
}
private struct SelectionBarAuditHost:UIViewRepresentable {
    func makeCoordinator() -> SelectionMenuController { SelectionMenuController() }
    func makeUIView(context:Context) -> UIView {
        let view = UIView()
        context.coordinator.install(on:view)
        context.coordinator.textProvider = { "function" }
        context.coordinator.targetRectProvider = { _ in CGRect(x:80,y:130,width:140,height:30) }
        DispatchQueue.main.async { context.coordinator.present(at:CGPoint(x:150,y:130)) }
        return view
    }
    func updateUIView(_ view:UIView,context:Context) {}
}
#endif
