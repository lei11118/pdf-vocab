import SwiftUI
import UIKit

@main
struct PdfVocabApp: App {
    private let store: DocumentStore?

    init() {
        RuntimeDiagnostics.beginSession()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--context-display-audit") {
            self.store = nil
        } else {
            self.store = AppDatabase.shared.map { DocumentStore(db: $0) }
        }
        #else
        self.store = AppDatabase.shared.map { DocumentStore(db: $0) }
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        DiagLog.log("app launched v\(version)")
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--context-display-audit") {
                ContextDisplayAuditView()
            } else if ProcessInfo.processInfo.arguments.contains("--gesture-audit") {
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
/// Static, database-free surfaces for verifying contextual and dictionary AX layout.
@MainActor
private struct ContextDisplayAuditView: View {
    private let hoverDefinition = String(repeating: "n. 函数；功能；作用；职责。\n", count: 18)
        + "末尾定义：Hover 字典释义可达。"
    private let compactDefinition = String(repeating: "费用；负责；冲锋；负荷。\n", count: 12)
        + "末尾定义：Compact 胶囊释义可达。"
    private let hoverCandidate = String(repeating: "在当前语境中，词义会完整显示并与词典释义并列。", count: 8)
    private let compactCandidate = String(repeating: "在此语境中，charge表示“收取费用”。", count: 6)

    private var compactSelection: ContextualSelection {
        let canonical = SemanticTokenizer.canonicalize(
            "charge", documentSHA256: "context-display-audit", pageIndex: 0)
        guard let token = canonical.tokens.first?.withGeometryQuality(.word) else {
            preconditionFailure("The fixed audit token must canonicalize")
        }
        return ContextualSelection(documentSHA256: canonical.documentSHA256,
                                   pageIndex: canonical.pageIndex,
                                   sourceSpans: [token.span],
                                   tokens: [token],
                                   displaySurface: "charge",
                                   generation: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WordBubbleContent(term: "function",
                              detail: hoverDefinition,
                              contextualCandidate: hoverCandidate)
                .frame(width: 320, height: 180)
            CompactContextualCardContent(selection: compactSelection,
                                         dictionaryDefinitions: compactDefinition,
                                         candidatePreview: compactCandidate)
                .frame(width: 320, height: 96)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.background1)
    }
}

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
