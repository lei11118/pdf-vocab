import Foundation
import PDFKit

extension ContextOCRPage {
    static let currentRevision = 2
}

enum ContextOCRWorkerError: LocalizedError {
    case invalidDocument
    case lockedDocument
    case emptyDocument
    case invalidPageIndex(index: Int, pageCount: Int)
    case unavailablePage(index: Int)

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            return "The PDF document could not be opened"
        case .lockedDocument:
            return "The PDF document is locked and has no empty-password unlock"
        case .emptyDocument:
            return "The PDF document has no pages"
        case .invalidPageIndex(let index, let pageCount):
            return "PDF page index \(index) is outside the document's \(pageCount) pages"
        case .unavailablePage(let index):
            return "PDF page \(index) is unavailable"
        }
    }
}

/// Serializes PDFKit access and returns only Sendable page values to callers.
actor ContextOCRWorker {
    static let shared = ContextOCRWorker()

    private static let documentLimit = 2
    private static let legacyPageLimit = 8
    private static let pagesPerDocumentOpen = 32

    private struct DocumentKey: Hashable {
        let urlPath: String
        let documentSHA256: String
    }

    private struct LegacyPageKey: Hashable {
        let document: DocumentKey
        let pageIndex: Int
    }

    private struct DocumentEntry {
        var document: PDFDocument
        var lastUsed: UInt64
        var pagesSinceOpen: Int
    }

    private struct LegacyWordsEntry {
        let words: [OCRWord]
        var lastUsed: UInt64
    }

    private var documents: [DocumentKey: DocumentEntry] = [:]
    private var legacyWords: [LegacyPageKey: LegacyWordsEntry] = [:]
    private var useCounter: UInt64 = 0

    /// Returns nil for a native-text page. Scanned pages are persisted as both
    /// the full-line context representation and the compatible legacy boxes.
    func recognizeContextPage(url: URL,
                              documentSHA256: String,
                              pageIndex: Int,
                              db: AppDatabase) throws -> ContextOCRPage? {
        try Task.checkCancellation()
        let key = try Self.documentKey(url: url, documentSHA256: documentSHA256)
        let page = try page(at: pageIndex, for: key, url: url)
        try Task.checkCancellation()

        guard OCRService.needsOCR(page: page) else {
            try Task.checkCancellation()
            return nil
        }

        let mediaBox = SourceRect(rect: page.bounds(for: .mediaBox))
        let contextStore = ContextOCRStore(db: db)
        let cachedPage: ContextOCRPage?
        do {
            cachedPage = try contextStore.load(documentSHA256: documentSHA256,
                                               pageIndex: pageIndex,
                                               revision: ContextOCRPage.currentRevision)
        } catch let error as ContextOCRStoreError {
            switch error {
            case .decoding(_), .payloadIdentityMismatch:
                DiagLog.log("context OCR: invalid cache sha=\(documentSHA256.prefix(8)) page=\(pageIndex) error=\(error.localizedDescription)")
                cachedPage = nil
            case .encoding:
                throw error
            }
        }
        if let stored = cachedPage, stored.mediaBox == mediaBox {
            try Task.checkCancellation()
            return stored
        }

        let result = try autoreleasepool {
            try OCRService.recognizeContextPage(page: page,
                                                documentSHA256: documentSHA256,
                                                pageIndex: pageIndex,
                                                revision: ContextOCRPage.currentRevision)
        }
        try Task.checkCancellation()

        try contextStore.save(result.contextPage)
        OCRStore(db: db).save(docSha: documentSHA256, page: pageIndex, words: result.legacyWords)
        cacheLegacyWords(result.legacyWords, for: LegacyPageKey(document: key, pageIndex: pageIndex))
        return result.contextPage
    }

    /// Processes at most one legacy OCR page per actor turn. A future caller
    /// can await this once per page, allowing current-page work between pages.
    func recognizeLegacyPage(url: URL,
                             documentSHA256: String,
                             pageIndex: Int,
                             store: OCRStore) throws -> [OCRWord] {
        try Task.checkCancellation()
        let key = try Self.documentKey(url: url, documentSHA256: documentSHA256)
        let page = try page(at: pageIndex, for: key, url: url)
        try Task.checkCancellation()

        let cacheKey = LegacyPageKey(document: key, pageIndex: pageIndex)
        let words: [OCRWord]
        if let cached = cachedLegacyWords(for: cacheKey) {
            words = cached
        } else {
            words = autoreleasepool {
                OCRService.needsOCR(page: page) ? OCRService.recognize(page: page) : []
            }
            try Task.checkCancellation()
            cacheLegacyWords(words, for: cacheKey)
        }

        try Task.checkCancellation()
        store.save(docSha: documentSHA256, page: pageIndex, words: words)
        return words
    }

    /// Returns the opened PDF's page count without exposing PDFKit objects.
    func pageCount(url: URL, documentSHA256: String) throws -> Int {
        try Task.checkCancellation()
        let key = try Self.documentKey(url: url, documentSHA256: documentSHA256)
        _ = try page(at: 0, for: key, url: url)
        try Task.checkCancellation()
        guard let document = documents[key]?.document else {
            throw ContextOCRWorkerError.invalidDocument
        }
        return document.pageCount
    }

    private static func documentKey(url: URL, documentSHA256: String) throws -> DocumentKey {
        let fileURL = url.standardizedFileURL
        guard url.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ContextOCRWorkerError.invalidDocument
        }
        return DocumentKey(urlPath: fileURL.path, documentSHA256: documentSHA256)
    }

    /// PDFDocument and PDFPage remain actor-owned and never cross this boundary.
    private func page(at index: Int, for key: DocumentKey, url: URL) throws -> PDFPage {
        let document: PDFDocument
        if var entry = documents[key] {
            if entry.pagesSinceOpen >= Self.pagesPerDocumentOpen {
                do {
                    entry.document = try openDocument(at: url)
                } catch {
                    documents.removeValue(forKey: key)
                    throw error
                }
                entry.pagesSinceOpen = 0
            }
            document = entry.document
            entry.pagesSinceOpen += 1
            entry.lastUsed = nextUse()
            documents[key] = entry
        } else {
            let opened = try openDocument(at: url)
            if documents.count >= Self.documentLimit,
               let leastRecentlyUsed = documents.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
                documents.removeValue(forKey: leastRecentlyUsed)
            }
            documents[key] = DocumentEntry(document: opened,
                                           lastUsed: nextUse(),
                                           pagesSinceOpen: 1)
            document = opened
        }

        guard index >= 0, index < document.pageCount else {
            throw ContextOCRWorkerError.invalidPageIndex(index: index, pageCount: document.pageCount)
        }
        guard let page = document.page(at: index) else {
            throw ContextOCRWorkerError.unavailablePage(index: index)
        }
        return page
    }

    private func openDocument(at url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw ContextOCRWorkerError.invalidDocument
        }
        if document.isLocked, !document.unlock(withPassword: "") {
            throw ContextOCRWorkerError.lockedDocument
        }
        guard document.pageCount > 0 else {
            throw ContextOCRWorkerError.emptyDocument
        }
        guard document.page(at: 0) != nil else {
            throw ContextOCRWorkerError.unavailablePage(index: 0)
        }
        return document
    }

    private func cachedLegacyWords(for key: LegacyPageKey) -> [OCRWord]? {
        guard var entry = legacyWords[key] else { return nil }
        entry.lastUsed = nextUse()
        legacyWords[key] = entry
        return entry.words
    }

    private func cacheLegacyWords(_ words: [OCRWord], for key: LegacyPageKey) {
        legacyWords[key] = LegacyWordsEntry(words: words, lastUsed: nextUse())
        while legacyWords.count > Self.legacyPageLimit,
              let leastRecentlyUsed = legacyWords.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            legacyWords.removeValue(forKey: leastRecentlyUsed)
        }
    }

    private func nextUse() -> UInt64 {
        useCounter &+= 1
        return useCounter
    }
}
