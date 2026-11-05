import Foundation
import GRDB

enum OCRCharacterGeometryStoreError: LocalizedError {
    case encoding(Error)
    case payloadIdentityMismatch
    case payloadTooLarge(actualBytes: Int, maximumBytes: Int)
    case payloadExceedsTotalBudget(actualBytes: Int, maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .encoding(let error):
            return "Could not encode OCR character geometry: \(error.localizedDescription)"
        case .payloadIdentityMismatch:
            return "OCR character geometry payload source text does not match its cache key"
        case .payloadTooLarge(let actualBytes, let maximumBytes):
            return "OCR character geometry payload is \(actualBytes) bytes; per-entry limit is \(maximumBytes)"
        case .payloadExceedsTotalBudget(let actualBytes, let maximumBytes):
            return "OCR character geometry payload is \(actualBytes) bytes; total cache budget is \(maximumBytes)"
        }
    }
}

/// Bounded persistence for derived fast character geometry. It never mutates
/// the accurate context OCR page or legacy OCR word tables.
final class OCRCharacterGeometryStore: @unchecked Sendable {
    static let defaultMaximumTotalBytes = 32 * 1024 * 1024
    static let defaultMaximumPayloadBytes = 1 * 1024 * 1024

    private let db: AppDatabase
    private let maximumTotalBytes: Int
    private let maximumPayloadBytes: Int

    init(db: AppDatabase,
         maximumTotalBytes: Int = OCRCharacterGeometryStore.defaultMaximumTotalBytes,
         maximumPayloadBytes: Int = OCRCharacterGeometryStore.defaultMaximumPayloadBytes) {
        precondition(maximumTotalBytes > 0)
        precondition(maximumPayloadBytes > 0)
        self.db = db
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    /// A missing, undecodable, or mismatched derived payload is a cache miss.
    /// Database read and access-time write errors still propagate to the caller.
    func load(key: OCRCharacterGeometryCacheKey) throws -> OCRCharacterGeometryCachePayload? {
        try db.dbQueue.write { database in
            guard let row = try Row.fetchOne(database,
                                             sql: """
                                                SELECT docSha, page, blockID, sourceRevision,
                                                       geometryRevision, engineVersion, payload
                                                FROM ocr_character_geometry
                                                WHERE cacheKey = ?
                                                """,
                                             arguments: [key.cacheKey]) else { return nil }

            let rowMatchesKey: Bool = (row["docSha"] as String) == key.documentSHA256
                && (row["page"] as Int) == key.pageIndex
                && (row["blockID"] as String) == key.blockID
                && (row["sourceRevision"] as Int) == key.sourceRevision
                && (row["geometryRevision"] as Int) == key.geometryRevision
                && (row["engineVersion"] as String) == key.engineVersion
            guard rowMatchesKey else {
                DiagLog.log("context OCR geometry: cache row identity mismatch key=\(key.cacheKey.prefix(8))")
                return nil
            }

            let data: Data = row["payload"]
            guard data.count <= maximumPayloadBytes else {
                DiagLog.log("context OCR geometry: oversized cache key=\(key.cacheKey.prefix(8)) bytes=\(data.count) limit=\(maximumPayloadBytes)")
                return nil
            }
            let payload: OCRCharacterGeometryCachePayload
            do {
                payload = try JSONDecoder().decode(OCRCharacterGeometryCachePayload.self, from: data)
            } catch {
                DiagLog.log("context OCR geometry: corrupt cache key=\(key.cacheKey.prefix(8)) error=\(error.localizedDescription)")
                return nil
            }
            guard payload.key == key, key.matchesSourceText(payload.refinement.sourceText) else {
                DiagLog.log("context OCR geometry: payload identity mismatch key=\(key.cacheKey.prefix(8))")
                return nil
            }

            let accessTime = try nextAccessTime(in: database)
            try database.execute(sql: "UPDATE ocr_character_geometry SET lastAccess = ? WHERE cacheKey = ?",
                                 arguments: [accessTime, key.cacheKey])
            return payload
        }
    }

    func save(_ payload: OCRCharacterGeometryCachePayload) throws {
        guard payload.key.matchesSourceText(payload.refinement.sourceText) else {
            throw OCRCharacterGeometryStoreError.payloadIdentityMismatch
        }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(payload)
        } catch {
            throw OCRCharacterGeometryStoreError.encoding(error)
        }
        guard data.count <= maximumPayloadBytes else {
            throw OCRCharacterGeometryStoreError.payloadTooLarge(actualBytes: data.count,
                                                                 maximumBytes: maximumPayloadBytes)
        }
        guard data.count <= maximumTotalBytes else {
            throw OCRCharacterGeometryStoreError.payloadExceedsTotalBudget(actualBytes: data.count,
                                                                           maximumBytes: maximumTotalBytes)
        }

        let key = payload.key
        try db.dbQueue.write { database in
            let accessTime = try nextAccessTime(in: database)
            try database.execute(sql: """
                INSERT INTO ocr_character_geometry
                    (cacheKey, docSha, page, blockID, sourceRevision, geometryRevision,
                     engineVersion, payload, lastAccess)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(cacheKey) DO UPDATE SET
                    docSha = excluded.docSha,
                    page = excluded.page,
                    blockID = excluded.blockID,
                    sourceRevision = excluded.sourceRevision,
                    geometryRevision = excluded.geometryRevision,
                    engineVersion = excluded.engineVersion,
                    payload = excluded.payload,
                    lastAccess = excluded.lastAccess
                """, arguments: [key.cacheKey,
                                key.documentSHA256,
                                key.pageIndex,
                                key.blockID,
                                key.sourceRevision,
                                key.geometryRevision,
                                key.engineVersion,
                                data,
                                accessTime])
            try pruneToBudget(in: database)
        }
    }

    private func nextAccessTime(in database: Database) throws -> Double {
        let latest = try Double.fetchOne(database,
                                        sql: "SELECT COALESCE(MAX(lastAccess), 0) FROM ocr_character_geometry") ?? 0
        return max(Date().timeIntervalSince1970, latest + 0.000_001)
    }

    private func pruneToBudget(in database: Database) throws {
        try database.execute(sql: """
            DELETE FROM ocr_character_geometry
            WHERE cacheKey IN (
                SELECT cacheKey FROM (
                    SELECT cacheKey,
                           SUM(length(payload)) OVER (
                               ORDER BY lastAccess DESC, cacheKey ASC
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                           ) AS retainedBytes
                    FROM ocr_character_geometry
                )
                WHERE retainedBytes > ?
            )
            """, arguments: [maximumTotalBytes])
    }
}
