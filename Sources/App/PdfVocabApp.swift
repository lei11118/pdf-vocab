import SwiftUI

@main
struct PdfVocabApp: App {
    private let store: DocumentStore?

    init() {
        self.store = AppDatabase.shared.map { DocumentStore(db: $0) }
    }

    var body: some Scene {
        WindowGroup {
            if let store {
                LibraryView(store: store)
            } else {
                ContentUnavailableView(
                    "数据库打开失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text("请重启 App;若问题持续,请反馈。")
                )
            }
        }
    }
}
