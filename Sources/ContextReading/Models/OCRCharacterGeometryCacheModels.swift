import CryptoKit
import Foundation

struct ContextOCRRefinementRequest: Hashable, Sendable {
    let id: UUID
    let documentSHA256: String
    let pageIndex: Int
    let blockID: String
    let generation: Int

    init(documentSHA256: String,
         pageIndex: Int,
         blockID: String,
         generation: Int) {
        self.id = UUID()
        self.documentSHA256 = documentSHA256
        self.pageIndex = pageIndex
        self.blockID = blockID
        self.generation = generation
    }
}

enum ContextOCRRefinementOutcome: Sendable {
    case completed
    case cancelled
    case failed
}

struct OCRCharacterGeometryCacheKey: Codable, Equatable, Hashable, Sendable {
    let cacheKey: String
    let documentSHA256: String
    let pageIndex: Int
    let blockID: String
    let sourceRevision: Int
    let geometryRevision: Int
    let engineVersion: String
    let sourceTextSHA256: String
    let layoutSHA256: String

    static let geometryRevision = OCRCharacterRefiner.algorithmVersion

    static func make(page: ContextOCRPage,
                     line: OCRLine,
                     engineVersion: String) throws -> OCRCharacterGeometryCacheKey {
        guard page.revision == ContextOCRPage.currentRevision else {
            throw OCRCharacterGeometryCacheKeyError.staleSourceRevision(page.revision)
        }
        guard !page.documentSHA256.isEmpty,
              page.pageIndex >= 0,
              !line.blockID.isEmpty,
              !engineVersion.isEmpty else {
            throw OCRCharacterGeometryCacheKeyError.invalidIdentity
        }

        let sourceDigest = Self.sha256(Data(line.sourceText.utf8))
        let layout = LayoutIdentity(mediaBox: page.mediaBox,
                                    regionRect: line.regionRect,
                                    pageRect: line.pageRect,
                                    tokens: line.tokens,
                                    tokenGeometry: line.tokenGeometry)
        let layoutDigest = Self.sha256(try Self.stableJSON(layout))
        let identity = CacheIdentity(documentSHA256: page.documentSHA256,
                                     pageIndex: page.pageIndex,
                                     blockID: line.blockID,
                                     sourceRevision: page.revision,
                                     geometryRevision: Self.geometryRevision,
                                     engineVersion: engineVersion,
                                     sourceTextSHA256: sourceDigest,
                                     layoutSHA256: layoutDigest)
        let cacheKey = Self.sha256(try Self.stableJSON(identity))
        return OCRCharacterGeometryCacheKey(cacheKey: cacheKey,
                                            documentSHA256: page.documentSHA256,
                                            pageIndex: page.pageIndex,
                                            blockID: line.blockID,
                                            sourceRevision: page.revision,
                                            geometryRevision: Self.geometryRevision,
                                            engineVersion: engineVersion,
                                            sourceTextSHA256: sourceDigest,
                                            layoutSHA256: layoutDigest)
    }

    static var currentEngineVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "vision-fast-ios-\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    func matchesSourceText(_ sourceText: String) -> Bool {
        Self.sha256(Data(sourceText.utf8)) == sourceTextSHA256
    }

    private struct LayoutIdentity: Codable {
        let mediaBox: SourceRect
        let regionRect: SourceRect
        let pageRect: SourceRect?
        let tokens: [SourceToken]
        let tokenGeometry: [SourceTokenGeometry]
    }

    private struct CacheIdentity: Codable {
        let documentSHA256: String
        let pageIndex: Int
        let blockID: String
        let sourceRevision: Int
        let geometryRevision: Int
        let engineVersion: String
        let sourceTextSHA256: String
        let layoutSHA256: String
    }

    private static func stableJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum OCRCharacterGeometryCacheKeyError: LocalizedError {
    case invalidIdentity
    case staleSourceRevision(Int)

    var errorDescription: String? {
        switch self {
        case .invalidIdentity:
            return "OCR character geometry cache identity is invalid"
        case .staleSourceRevision(let revision):
            return "OCR character geometry requires the current source revision, got \(revision)"
        }
    }
}

struct OCRCharacterGeometryCachePayload: Codable, Equatable, Sendable {
    let key: OCRCharacterGeometryCacheKey
    let refinement: OCRCharacterRefinementResult
}
