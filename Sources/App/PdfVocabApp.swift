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
        WindowGroup("PDF", id: PDFReaderWindowRequest.sceneID, for: PDFReaderWindowRequest.self) { $request in
            if let store, let request {
                PDFReaderWindow(store: store, request: request)
                    .tint(DS.accent)
                    .buttonStyle(DSPressableButtonStyle())
            }
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
        for (key,value) in ["X":48.0,"Y":200.0,"W":200.0,"H":96.0] {
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

/// A new identity per opening allows two independent scenes for the same PDF.
struct PDFReaderWindowRequest: Codable, Hashable {
    static let sceneID = "pdf-reader"
    var id = UUID()
    var docSha: String
    var page: Int
    func documentStartingAtRequestedPage(_ document: DocumentRecord) -> DocumentRecord {
        var result = document
        result.lastPage = min(max(page, 0), max(0, document.pageCount-1))
        result.pageX = 0; result.pageY = 0; result.zoomAuto = true
        return result
    }
}

private struct PDFReaderWindow: View {
    let store: DocumentStore
    let request: PDFReaderWindowRequest
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        NavigationStack {
            if let doc = try? store.document(sha256: request.docSha) {
                ReaderView(doc: request.documentStartingAtRequestedPage(doc), store: store)
                    .environment(\.readerPanelClose, { dismissWindow(id: PDFReaderWindowRequest.sceneID, value: request) })
            } else {
                ContentUnavailableView("文档不可用", systemImage: "doc.questionmark", description: Text("文档可能已删除，请返回书库重新打开。"))
            }
        }
    }
}
