import SwiftUI

/// The library graph is independent of every document graph in the same database.
struct KnowledgeGraphLibrary: View {
    let store: DocumentStore
    @State private var documents: [DocumentRecord]?
    @State private var chosen: DocumentRecord?
    @StateObject private var tools = PencilToolSession()

    var body: some View {
        Group {
            if let documents {
                KnowledgeGraphView(docId:KnowledgeGraph.libraryID,db:store.db,tools:tools,
                                   libraryDocuments:documents,onOpenDocument:{ id in
                    chosen = documents.first { $0.sha256 == id }
                })
            } else { ProgressView("正在加载知识图谱…") }
        }
        .task { documents = (try? store.allDocuments()) ?? [] }
        .fullScreenCover(item:$chosen) { doc in
            KnowledgeGraphView(docId:doc.sha256,db:store.db,tools:tools)
                .environment(\.readerPanelClose,nil)
        }
    }
}
