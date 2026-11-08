import CryptoKit
import Foundation
import GRDB

/// Stable identity for one validated, whole-block translation response.
/// Selection-specific alignment is still decoded against the live request.
enum ContextTranslationPayloadCacheIdentity {
    static let snapshotSchemaVersion = 1

    private struct Token: Codable {
        let id: String
        let sourceSpan: UTF16Span
    }

    private struct PhraseGroup: Codable {
        let id: String
        let sourceSpan: UTF16Span
    }

    private struct Identity: Codable {
        let documentSHA256: String
        let sourceUTF8: Data
        let tokens: [Token]
        let verifiedPhraseGroup: PhraseGroup?
        let sourceLanguageIdentifier: String
        let targetLanguageIdentifier: String
        let backendVersion: String
        let contextAlgorithmVersion: String
        let snapshotSchemaVersion: Int
    }

    static func cacheKey(request: ContextualTranslationRequest,
                         sourceLanguageIdentifier: String,
                         targetLanguageIdentifier: String,
                         backendVersion: String,
                         contextAlgorithmVersion: String) -> String? {
        let identity = Identity(documentSHA256: request.documentSHA256,
                                sourceUTF8: Data(request.sentenceText.utf8),
                                tokens: request.tokens.map { Token(id: $0.id, sourceSpan: $0.sourceSpan) },
                                verifiedPhraseGroup: request.selectedPhraseGroup.map {
                                    PhraseGroup(id: $0.id, sourceSpan: $0.sourceSpan)
                                },
                                sourceLanguageIdentifier: sourceLanguageIdentifier,
                                targetLanguageIdentifier: targetLanguageIdentifier,
                                backendVersion: backendVersion,
                                contextAlgorithmVersion: contextAlgorithmVersion,
                                snapshotSchemaVersion: snapshotSchemaVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(identity) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A small, bounded representation of only the two alignment attributes used
/// by this feature. Other framework or platform attributes are intentionally
/// discarded when a payload is restored.
struct ContextualTranslationPayloadSnapshot: Codable {
    struct AttributeRun: Codable {
        let span: UTF16Span
        let tokenID: String?
        let phraseGroupID: String?
    }

    let schemaVersion: Int
    let sourceText: String
    let targetText: String
    let sourceRuns: [AttributeRun]
    let targetRuns: [AttributeRun]

    static func encode(_ payload: ContextualTranslationPayload) -> Data? {
        guard let snapshot = try? ContextualTranslationPayloadSnapshot(payload: payload) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(snapshot),
              data.count <= ContextTranslationStore.maximumPayloadBytes else { return nil }
        return data
    }

    static func decode(_ data: Data) -> ContextualTranslationPayload? {
        guard !data.isEmpty, data.count <= ContextTranslationStore.maximumPayloadBytes,
              hasBoundedJSONDepth(data, maximumDepth: maximumJSONDepth),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return snapshot.makePayload()
    }

    private init(payload: ContextualTranslationPayload) throws {
        guard let attributedSource = payload.attributedSourceText,
              let attributedTarget = payload.attributedTargetText,
              String(attributedSource.characters).utf8.elementsEqual(payload.sourceText.utf8),
              String(attributedTarget.characters).utf8.elementsEqual(payload.targetText.utf8),
              Self.validText(payload.sourceText, maximumUTF16Units: ContextualTranslationRequest.maximumInputUTF16Units),
              Self.validText(payload.targetText, maximumUTF16Units: ContextualTranslationService.maximumOutputUTF16Units),
              !payload.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let sourceRuns = Self.attributeRuns(in: attributedSource, text: payload.sourceText),
              let targetRuns = Self.attributeRuns(in: attributedTarget, text: payload.targetText) else {
            throw SnapshotError.invalidPayload
        }
        schemaVersion = ContextTranslationPayloadCacheIdentity.snapshotSchemaVersion
        sourceText = payload.sourceText
        targetText = payload.targetText
        self.sourceRuns = sourceRuns
        self.targetRuns = targetRuns
    }

    private func makePayload() -> ContextualTranslationPayload? {
        guard schemaVersion == ContextTranslationPayloadCacheIdentity.snapshotSchemaVersion,
              Self.validText(sourceText, maximumUTF16Units: ContextualTranslationRequest.maximumInputUTF16Units),
              Self.validText(targetText, maximumUTF16Units: ContextualTranslationService.maximumOutputUTF16Units),
              !targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let attributedSource = Self.attributedString(sourceText, runs: sourceRuns),
              let attributedTarget = Self.attributedString(targetText, runs: targetRuns) else { return nil }
        return ContextualTranslationPayload(sourceText: sourceText,
                                            attributedSourceText: attributedSource,
                                            targetText: targetText,
                                            attributedTargetText: attributedTarget)
    }

    private static func attributeRuns(in attributed: AttributedString,
                                      text: String) -> [AttributeRun]? {
        var result: [AttributeRun] = []
        for run in attributed.runs {
            let tokenID = run[ContextualTranslationTokenIDAttribute.self]
            let phraseGroupID = run[ContextualTranslationPhraseGroupIDAttribute.self]
            guard tokenID != nil || phraseGroupID != nil else { continue }
            guard let lower = String.Index(run.range.lowerBound, within: text),
                  let upper = String.Index(run.range.upperBound, within: text),
                  let span = UTF16Span(composedRange: NSRange(lower..<upper, in: text), in: text),
                  span.length > 0,
                  validIdentifier(tokenID), validIdentifier(phraseGroupID) else { return nil }
            result.append(AttributeRun(span: span, tokenID: tokenID, phraseGroupID: phraseGroupID))
            guard result.count <= maximumRunsPerText else { return nil }
        }
        guard validRunRanges(result, text: text) else { return nil }
        return result
    }

    private static func attributedString(_ text: String,
                                         runs: [AttributeRun]) -> AttributedString? {
        guard validText(text, maximumUTF16Units: maximumRunUTF16Units),
              runs.count <= maximumRunsPerText,
              validRunRanges(runs, text: text) else { return nil }
        var attributed = AttributedString(text)
        for run in runs {
            guard let end = run.span.endExclusive else { return nil }
            let lowerStringIndex = String.Index(utf16Offset: run.span.location, in: text)
            let upperStringIndex = String.Index(utf16Offset: end, in: text)
            guard let lower = AttributedString.Index(lowerStringIndex, within: attributed),
                  let upper = AttributedString.Index(upperStringIndex, within: attributed) else { return nil }
            if let tokenID = run.tokenID {
                attributed[lower..<upper][ContextualTranslationTokenIDAttribute.self] = tokenID
            }
            if let phraseGroupID = run.phraseGroupID {
                attributed[lower..<upper][ContextualTranslationPhraseGroupIDAttribute.self] = phraseGroupID
            }
        }
        return attributed
    }

    private static func validRunRanges(_ runs: [AttributeRun], text: String) -> Bool {
        guard runs.count <= maximumRunsPerText else { return false }
        for run in runs {
            guard run.tokenID != nil || run.phraseGroupID != nil,
                  validIdentifier(run.tokenID), validIdentifier(run.phraseGroupID),
                  run.span.length > 0,
                  run.span.composedCharacterRange(in: text) != nil else { return false }
        }
        let tokenSpans = runs.filter { $0.tokenID != nil }.map(\.span).sorted { $0.location < $1.location }
        let phraseSpans = runs.filter { $0.phraseGroupID != nil }.map(\.span).sorted { $0.location < $1.location }
        return hasNoOverlaps(tokenSpans) && hasNoOverlaps(phraseSpans)
    }

    private static func hasNoOverlaps(_ spans: [UTF16Span]) -> Bool {
        for pair in zip(spans, spans.dropFirst()) {
            guard let previousEnd = pair.0.endExclusive,
                  pair.1.location >= previousEnd else { return false }
        }
        return true
    }

    private static func validIdentifier(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && (value as NSString).length <= maximumIdentifierUTF16Units
    }

    private static func validText(_ text: String, maximumUTF16Units: Int) -> Bool {
        let length = (text as NSString).length
        return length > 0 && length <= maximumUTF16Units
    }

    private static func hasBoundedJSONDepth(_ data: Data, maximumDepth: Int) -> Bool {
        var depth = 0
        var isInsideString = false
        var isEscaped = false
        for byte in data {
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    isInsideString = false
                }
                continue
            }
            switch byte {
            case 0x22:
                isInsideString = true
            case 0x7B, 0x5B:
                depth += 1
                if depth > maximumDepth { return false }
            case 0x7D, 0x5D:
                depth -= 1
                if depth < 0 { return false }
            default:
                break
            }
        }
        return !isInsideString && depth == 0
    }

    private static let maximumRunUTF16Units = ContextualTranslationService.maximumOutputUTF16Units
    private static let maximumRunsPerText = 4_096
    private static let maximumIdentifierUTF16Units = 128
    private static let maximumJSONDepth = 4

    private enum SnapshotError: Error {
        case invalidPayload
    }
}

/// Bounded persistence for validated contextual Translation responses. The
/// store keeps an AppDatabase reference so restored databases are picked up
/// through its current dbQueue after replaceDatabase(withFileAt:).
final class ContextTranslationStore: @unchecked Sendable {
    static let maximumTotalBytes = 16 * 1024 * 1024
    static let maximumPayloadBytes = 256 * 1024

    private let db: AppDatabase
    private let maximumTotalBytes: Int
    private let maximumPayloadBytes: Int

    init(db: AppDatabase,
         maximumTotalBytes: Int = ContextTranslationStore.maximumTotalBytes,
         maximumPayloadBytes: Int = ContextTranslationStore.maximumPayloadBytes) {
        precondition(maximumTotalBytes > 0)
        precondition(maximumPayloadBytes > 0)
        self.db = db
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    func load(cacheKey: String, documentSHA256: String) throws -> Data? {
        guard Self.isCacheKey(cacheKey), !documentSHA256.isEmpty else { return nil }
        return try db.dbQueue.write { database in
            guard let row = try Row.fetchOne(database,
                                             sql: "SELECT docSha, typeof(payload) AS payloadType, length(payload) AS payloadLength FROM context_translation_payload WHERE cacheKey = ?",
                                             arguments: [cacheKey]),
                  (row["docSha"] as String) == documentSHA256 else { return nil }
            let payloadType: String = row["payloadType"]
            let storedLength: Int = row["payloadLength"]
            guard payloadType == "blob", storedLength > 0, storedLength <= maximumPayloadBytes else {
                try database.execute(sql: "DELETE FROM context_translation_payload WHERE cacheKey = ?",
                                     arguments: [cacheKey])
                return nil
            }
            guard let payloadRow = try Row.fetchOne(database,
                                                     sql: "SELECT payload FROM context_translation_payload WHERE cacheKey = ?",
                                                     arguments: [cacheKey]) else { return nil }
            let payload: Data = payloadRow["payload"]
            guard payload.count == storedLength, payload.count <= maximumPayloadBytes else {
                try database.execute(sql: "DELETE FROM context_translation_payload WHERE cacheKey = ?",
                                     arguments: [cacheKey])
                return nil
            }
            let accessTime = try nextAccessTime(in: database)
            try database.execute(sql: "UPDATE context_translation_payload SET lastAccess = ? WHERE cacheKey = ?",
                                 arguments: [accessTime, cacheKey])
            try pruneToBudget(in: database)
            return payload
        }
    }

    /// Returns false when the source document has not been persisted yet or
    /// the response exceeds a cache bound. These cases never fail translation.
    @discardableResult
    func save(cacheKey: String, documentSHA256: String, payload: Data) throws -> Bool {
        guard Self.isCacheKey(cacheKey), !documentSHA256.isEmpty,
              !payload.isEmpty, payload.count <= maximumPayloadBytes,
              payload.count <= maximumTotalBytes else { return false }
        return try db.dbQueue.write { database in
            let documentExists = (try Int.fetchOne(database,
                                                   sql: "SELECT COUNT(*) FROM document WHERE sha256 = ?",
                                                   arguments: [documentSHA256]) ?? 0) > 0
            guard documentExists else { return false }
            let accessTime = try nextAccessTime(in: database)
            try database.execute(sql: """
                INSERT INTO context_translation_payload (cacheKey, docSha, payload, lastAccess)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(cacheKey) DO UPDATE SET
                    docSha = excluded.docSha,
                    payload = excluded.payload,
                    lastAccess = excluded.lastAccess
                """, arguments: [cacheKey, documentSHA256, payload, accessTime])
            try pruneToBudget(in: database)
            return true
        }
    }

    func remove(cacheKey: String, documentSHA256: String) throws {
        guard Self.isCacheKey(cacheKey), !documentSHA256.isEmpty else { return }
        try db.dbQueue.write { database in
            try database.execute(sql: "DELETE FROM context_translation_payload WHERE cacheKey = ? AND docSha = ?",
                                 arguments: [cacheKey, documentSHA256])
        }
    }

    func clearAll() throws {
        try db.dbQueue.write { database in
            try database.execute(sql: "DELETE FROM context_translation_payload")
        }
    }

    private static func isCacheKey(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func nextAccessTime(in database: Database) throws -> Double {
        let latest = try Double.fetchOne(database,
                                        sql: "SELECT COALESCE(MAX(lastAccess), 0) FROM context_translation_payload") ?? 0
        return max(Date().timeIntervalSince1970, latest + 0.000_001)
    }

    private func pruneToBudget(in database: Database) throws {
        try database.execute(sql: """
            DELETE FROM context_translation_payload
            WHERE cacheKey IN (
                SELECT cacheKey FROM (
                    SELECT cacheKey,
                           SUM(length(payload)) OVER (
                               ORDER BY lastAccess DESC, cacheKey ASC
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                           ) AS retainedBytes
                    FROM context_translation_payload
                )
                WHERE retainedBytes > ?
            )
            """, arguments: [maximumTotalBytes])
    }
}
