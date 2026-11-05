import Foundation
import GRDB

enum ContextOCRStoreError: LocalizedError {
    case encoding(Error)
    case decoding(Error)
    case payloadIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .encoding(let error): return "Could not encode context OCR page: \(error.localizedDescription)"
        case .decoding(let error): return "Could not decode context OCR page: \(error.localizedDescription)"
        case .payloadIdentityMismatch: return "Context OCR payload identity does not match its database row"
        }
    }
}

/// Persistence for the opt-in full-line OCR representation. Legacy OCR tables
/// and their completion semantics remain owned by `OCRStore`.
final class ContextOCRStore: @unchecked Sendable {
    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    func save(_ page: ContextOCRPage) throws {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(page)
        } catch {
            throw ContextOCRStoreError.encoding(error)
        }
        try db.dbQueue.write { database in
            try database.execute(sql: """
                INSERT INTO context_ocr_page (docSha, page, revision, payload)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(docSha, page) DO UPDATE SET
                    revision = excluded.revision,
                    payload = excluded.payload
                """, arguments: [page.documentSHA256, page.pageIndex, page.revision, payload])
        }
    }

    /// A missing row and a stale revision both return nil. A stored blank page
    /// decodes to a non-nil value with an empty line list.
    func load(documentSHA256: String, pageIndex: Int, revision: Int) throws -> ContextOCRPage? {
        try db.dbQueue.read { database in
            guard let row = try Row.fetchOne(database,
                sql: "SELECT revision, payload FROM context_ocr_page WHERE docSha = ? AND page = ?",
                arguments: [documentSHA256, pageIndex]) else { return nil }
            let storedRevision: Int = row["revision"]
            guard storedRevision == revision else { return nil }
            let payload: Data = row["payload"]
            let page: ContextOCRPage
            do {
                page = try JSONDecoder().decode(ContextOCRPage.self, from: payload)
            } catch {
                throw ContextOCRStoreError.decoding(error)
            }
            guard page.documentSHA256 == documentSHA256,
                  page.pageIndex == pageIndex,
                  page.revision == storedRevision else {
                throw ContextOCRStoreError.payloadIdentityMismatch
            }
            return page
        }
    }
}
