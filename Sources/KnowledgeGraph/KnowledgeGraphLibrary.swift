import SwiftUI

/// The library entry chooses a document; graphs themselves remain document-scoped.
struct KnowledgeGraphLibrary: View {
    let store: DocumentStore
    @State private var documents: [DocumentRecord] = []
    @State private var chosen: DocumentRecord?
    @StateObject private var tools = PencilToolSession()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(documents) { doc in
                Button { chosen = doc } label: {
                    Label(doc.title, systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            .overlay { if documents.isEmpty { ContentUnavailableView("暂无文档",systemImage:"books.vertical",description:Text("导入文档后可创建对应的知识图谱。")) } }
            .navigationTitle("选择文档图谱")
            .toolbar { ToolbarItem(placement:.topBarLeading) { Button("完成") { dismiss() } } }
            .task { documents = (try? store.allDocuments()) ?? [] }
            .fullScreenCover(item:$chosen) { doc in
                KnowledgeGraphView(docId:doc.sha256,db:store.db,tools:tools)
            }
        }
    }
}
