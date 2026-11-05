import Foundation
import PDFKit
import UIKit
import XCTest
@testable import PdfVocab

@MainActor
final class ContextOCRTests: XCTestCase {
    func testCanonicalOCRTokensRetainEveryNonWhitespaceSourceSpan() throws {
        let source = "E=mc² + 3.14 ± e\u{0301} 👩‍🔬 charge charge"
        let canonical = SemanticTokenizer.canonicalize(source,
                                                       documentSHA256: "ocr-fixture",
                                                       pageIndex: 3,
                                                       blockID: "line-a")
        XCTAssertEqual(canonical.sourceText, source)
        XCTAssertTrue(canonical.tokens.contains { $0.sourceSurface == "±" })
        XCTAssertTrue(canonical.tokens.contains { $0.sourceSurface == "👩‍🔬" })
        XCTAssertTrue(canonical.tokens.contains { $0.sourceSurface == "e\u{0301}" })

        let ns = source as NSString
        var covered = Array(repeating: false, count: ns.length)
        for token in canonical.tokens {
            XCTAssertEqual(token.span.substring(in: source), token.sourceSurface)
            XCTAssertEqual(token.blockID, "line-a")
            guard let end = token.span.endExclusive, token.span.location >= 0, end <= covered.count else {
                XCTFail("Tokenizer produced an invalid UTF-16 span for \(token.sourceSurface)")
                continue
            }
            for offset in token.span.location..<end { covered[offset] = true }
        }
        var offset = 0
        while offset < ns.length {
            let range = ns.rangeOfComposedCharacterSequence(at: offset)
            let surface = ns.substring(with: range)
            if !surface.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                XCTAssertTrue(covered[range.location..<NSMaxRange(range)].allSatisfy { $0 },
                              "Non-whitespace source was lost: \(surface)")
            }
            offset = NSMaxRange(range)
        }
    }

    func testBlockIDSeparatesRepeatedLocalTokenRangesAndIDsStayStable() {
        let first = SemanticTokenizer.canonicalize("charge charge", documentSHA256: "same-doc",
                                                   pageIndex: 2, blockID: "row-one")
        let repeatFirst = SemanticTokenizer.canonicalize("charge charge", documentSHA256: "same-doc",
                                                         pageIndex: 2, blockID: "row-one")
        let second = SemanticTokenizer.canonicalize("charge charge", documentSHA256: "same-doc",
                                                    pageIndex: 2, blockID: "row-two")

        XCTAssertEqual(first.tokens.map(\.id), repeatFirst.tokens.map(\.id))
        XCTAssertEqual(Set(first.tokens.map(\.id)).count, 2)
        XCTAssertTrue(Set(first.tokens.map(\.id)).isDisjoint(with: Set(second.tokens.map(\.id))))
        XCTAssertTrue(first.tokens.allSatisfy { $0.blockID == "row-one" })
    }

    func testSourceRectValidationAndVisionMediaMapping() throws {
        XCTAssertNil(SourceRect(x: 0, y: 0, width: 0, height: 1))
        XCTAssertNil(SourceRect(x: .infinity, y: 0, width: 1, height: 1))
        let invalidJSON = Data(#"{"x":0,"y":0,"width":0,"height":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SourceRect.self, from: invalidJSON))

        let mediaRegion = CGRect(x: 31, y: -27, width: 400, height: 600)
        let mapped = try XCTUnwrap(ContextOCRGeometry.pageRect(
            fromVisionNormalized: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2),
            in: mediaRegion))
        XCTAssertEqual(mapped.x, 111, accuracy: 0.001)
        XCTAssertEqual(mapped.y, 153, accuracy: 0.001)
        XCTAssertEqual(mapped.width, 160, accuracy: 0.001)
        XCTAssertEqual(mapped.height, 120, accuracy: 0.001)
        XCTAssertNil(ContextOCRGeometry.pageRect(fromVisionNormalized: CGRect(x: -0.1, y: 0.2, width: 0.4, height: 0.2),
                                                 in: mediaRegion))
        XCTAssertNil(ContextOCRGeometry.pageRect(fromVisionNormalized: CGRect(x: 0.8, y: 0.2, width: 0.4, height: 0.2),
                                                 in: mediaRegion))

        // Rotation is intentionally absent from the conversion: the existing
        // recognitionImage rotation fixture verifies the rendered source also
        // stays in canonical media coordinates.
    }

    func testContextOCRBandsCoverFullWidthWithOverlapAndRespectPageBounds() {
        let bounds = CGRect(x: 31, y: -27, width: 800, height: 600)
        let bands = OCRService.contextRegions(for: bounds)

        XCTAssertEqual(bands.count, 2)
        for band in bands {
            XCTAssertEqual(band.minX, bounds.minX, accuracy: 0.001)
            XCTAssertEqual(band.width, bounds.width, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(band.minY, bounds.minY)
            XCTAssertLessThanOrEqual(band.maxY, bounds.maxY)
        }
        XCTAssertEqual(bands[0].minY, bounds.minY, accuracy: 0.001)
        XCTAssertEqual(bands[1].maxY, bounds.maxY, accuracy: 0.001)
        XCTAssertGreaterThan(bands[0].maxY, bands[1].minY,
                             "Adjacent full-width bands must overlap to protect lines near the split")
    }

    func testTileDedupRemovesOnlySameTextWithStrongSpatialOverlap() throws {
        let region = try XCTUnwrap(SourceRect(x: 0, y: 0, width: 800, height: 300))
        let overlapA = try makeLine(blockID: "overlap-a", text: "same line", confidence: 0.7,
                                    rect: CGRect(x: 10, y: 150, width: 200, height: 24), region: region)
        let overlapB = try makeLine(blockID: "overlap-b", text: "same line", confidence: 0.9,
                                    rect: CGRect(x: 15, y: 151, width: 198, height: 23), region: region)
        let leftColumn = try makeLine(blockID: "left", text: "same line", confidence: 0.8,
                                      rect: CGRect(x: 300, y: 100, width: 160, height: 24), region: region)
        let rightColumn = try makeLine(blockID: "right", text: "same line", confidence: 0.8,
                                       rect: CGRect(x: 600, y: 100, width: 160, height: 24), region: region)
        let differentText = try makeLine(blockID: "different", text: "other text", confidence: 0.9,
                                         rect: CGRect(x: 12, y: 150, width: 190, height: 24), region: region)

        let deduplicated = ContextOCRGeometry.deduplicatedLines([overlapA, overlapB, leftColumn, rightColumn, differentText])
        XCTAssertEqual(deduplicated.filter { $0.sourceText == "same line" }.count, 3)
        XCTAssertEqual(deduplicated.first { $0.blockID == "overlap-a" || $0.blockID == "overlap-b" }?.blockID, "overlap-b")
        XCTAssertTrue(deduplicated.contains { $0.blockID == "different" })
        XCTAssertEqual(Set(deduplicated.map(\.blockID)).count, deduplicated.count)
    }

    func testLineOrderingIsStrictAndDeterministic() throws {
        let region = try XCTUnwrap(SourceRect(x: 0, y: 0, width: 400, height: 200))
        let a = try makeLine(blockID: "a", text: "alpha", confidence: 0.8,
                             rect: CGRect(x: 0, y: 8, width: 40, height: 20), region: region)
        let b = try makeLine(blockID: "b", text: "bravo", confidence: 0.8,
                             rect: CGRect(x: 10, y: 14, width: 40, height: 20), region: region)
        let c = try makeLine(blockID: "c", text: "charlie", confidence: 0.8,
                             rect: CGRect(x: 20, y: 20, width: 40, height: 20), region: region)

        let ids = ContextOCRGeometry.deduplicatedLines([c, a, b]).map(\.blockID)
        XCTAssertEqual(ids, ["c", "b", "a"],
                       "Ordering is a strict media-y then x order, not a fuzzy row comparator")
    }

    func testContextOCRStoreRoundTripBlankRevisionCorruptionAndCascade() throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let sha = "context-ocr-test-\(UUID().uuidString)"
        try db.dbQueue.write { database in
            try database.execute(sql: """
                INSERT INTO document (sha256, title, fileName, pageCount, hasTextLayer, importedAt,
                                      lastPage, pageX, pageY, zoom, zoomAuto)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [sha, "Context OCR fixture", "fixture.pdf", 2, false, Date(), 0, 0, 0, 1, true])
        }
        defer { try? db.dbQueue.write { try $0.execute(sql: "DELETE FROM document WHERE sha256 = ?", arguments: [sha]) } }

        let store = ContextOCRStore(db: db)
        let invalidLine = OCRLine(blockID: "bad", candidates: [OCRCandidate(text: "bad", confidence: .infinity)],
                                  regionRect: try XCTUnwrap(SourceRect(x: 0, y: 0, width: 10, height: 10)),
                                  pageRect: nil, tokens: [], tokenGeometry: [])
        let invalidPage = ContextOCRPage(documentSHA256: sha, pageIndex: 1, revision: 7,
                                         mediaBox: try XCTUnwrap(SourceRect(x: 0, y: 0, width: 612, height: 792)),
                                         lines: [invalidLine])
        XCTAssertThrowsError(try store.save(invalidPage)) { error in
            guard let storeError = error as? ContextOCRStoreError,
                  case .encoding(_) = storeError else {
                return XCTFail("Expected explicit JSON encoding error, received \(error)")
            }
        }
        let legacyCountsBefore = try db.dbQueue.read { database in
            (try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM ocr_word WHERE docSha = ?", arguments: [sha]) ?? 0,
             try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM ocr_status WHERE docSha = ?", arguments: [sha]) ?? 0)
        }
        let media = try XCTUnwrap(SourceRect(x: 0, y: 0, width: 612, height: 792))
        let lineRect = try XCTUnwrap(SourceRect(x: 40, y: 700, width: 180, height: 24))
        let region = try XCTUnwrap(SourceRect(x: 0, y: 0, width: 612, height: 792))
        let canonical = SemanticTokenizer.canonicalize("charge 3.2 + π", documentSHA256: sha,
                                                       pageIndex: 0, blockID: "fixture-line")
        let tokenGeometry = canonical.tokens.map { token in
            SourceTokenGeometry(tokenID: token.id, span: token.span, rect: lineRect, quality: .word)
        }
        let line = OCRLine(blockID: "fixture-line",
                           candidates: [OCRCandidate(text: "charge 3.2 + π", confidence: 0.91),
                                        OCRCandidate(text: "charge 3.2 + pi", confidence: 0.43)],
                           regionRect: region, pageRect: lineRect,
                           tokens: canonical.tokens.map { $0.withGeometryQuality(.word) },
                           tokenGeometry: tokenGeometry)
        let page = ContextOCRPage(documentSHA256: sha, pageIndex: 0, revision: 7,
                                  mediaBox: media, lines: [line])
        try store.save(page)
        XCTAssertEqual(try XCTUnwrap(store.load(documentSHA256: sha, pageIndex: 0, revision: 7)), page)
        let staleRevision = try store.load(documentSHA256: sha, pageIndex: 0, revision: 8)
        let absentPage = try store.load(documentSHA256: sha, pageIndex: 1, revision: 7)
        XCTAssertNil(staleRevision)
        XCTAssertNil(absentPage)

        let blank = ContextOCRPage(documentSHA256: sha, pageIndex: 1, revision: 7,
                                   mediaBox: media, lines: [])
        try store.save(blank)
        let loadedBlank = try XCTUnwrap(store.load(documentSHA256: sha, pageIndex: 1, revision: 7))
        XCTAssertTrue(loadedBlank.lines.isEmpty)

        try db.dbQueue.write { database in
            try database.execute(sql: "UPDATE context_ocr_page SET payload = ? WHERE docSha = ? AND page = ?",
                                 arguments: [Data("{".utf8), sha, 0])
        }
        XCTAssertThrowsError(try store.load(documentSHA256: sha, pageIndex: 0, revision: 7)) { error in
            guard let storeError = error as? ContextOCRStoreError,
                  case .decoding(_) = storeError else {
                return XCTFail("Expected explicit JSON decoding error, received \(error)")
            }
        }
        let legacyCountsAfterSave = try db.dbQueue.read { database in
            (try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM ocr_word WHERE docSha = ?", arguments: [sha]) ?? 0,
             try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM ocr_status WHERE docSha = ?", arguments: [sha]) ?? 0)
        }
        XCTAssertEqual(legacyCountsAfterSave.0, legacyCountsBefore.0)
        XCTAssertEqual(legacyCountsAfterSave.1, legacyCountsBefore.1)

        try db.dbQueue.write { try $0.execute(sql: "DELETE FROM document WHERE sha256 = ?", arguments: [sha]) }
        let afterCascade = try store.load(documentSHA256: sha, pageIndex: 1, revision: 7)
        XCTAssertNil(afterCascade, "Deleting the owning document must cascade its context OCR pages")
    }

    func testSyntheticRasterOCRReportsLexicalAndFullTextMetrics() throws {
        let source = "charge plus 3.2 = π"
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let raster = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 360), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 360))
            (source as NSString).draw(at: CGPoint(x: 70, y: 120), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 78),
                .foregroundColor: UIColor.black
            ])
        }
        let pdfData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 180)).pdfData { context in
            context.beginPage()
            raster.draw(in: CGRect(x: 0, y: 0, width: 600, height: 180))
        }
        let page = try XCTUnwrap(PDFDocument(data: pdfData)?.page(at: 0))
        // Keep the original 2x2 OCR path as the measured baseline. The context
        // path uses different full-width bands and must be evaluated separately.
        let baselineLegacyWords = OCRService.recognize(page: page)
        let result = try OCRService.recognizeContextPage(page: page,
                                                         documentSHA256: "synthetic-raster-fixture",
                                                         pageIndex: 0,
                                                         revision: 1)
        XCTAssertFalse(result.contextPage.lines.isEmpty, "The synthetic high-contrast raster should produce OCR candidates")
        XCTAssertTrue(result.contextPage.lines.allSatisfy { !$0.candidates.isEmpty })
        XCTAssertTrue(result.contextPage.lines.allSatisfy { line in
            line.tokens.count == line.tokenGeometry.count
                && zip(line.tokens, line.tokenGeometry).allSatisfy { pair in
                    pair.0.id == pair.1.tokenID && pair.0.span == pair.1.span
                }
        })
        XCTAssertFalse(result.contextPage.lines.flatMap(\.tokens).contains { $0.geometryQuality == .verifiedCharacter },
                       "Vision word boxes are never represented as verified character geometry")

        let legacyRaw = baselineLegacyWords.map(\.text).joined(separator: " ")
        let fullRaw = result.contextPage.lines.map(\.sourceText).joined(separator: " ")
        let expectedLexical = englishWords(in: source)
        let legacyLexical = englishWords(in: legacyRaw)
        let fullLineLexical = englishWords(in: fullRaw)
        let expectedFull = normalizedWhitespace(source.lowercased())
        let legacyFull = normalizedWhitespace(legacyRaw.lowercased())
        let fullLineText = normalizedWhitespace(fullRaw.lowercased())
        let legacyLexicalCER = errorRate(Array(expectedLexical.joined(separator: " ")), Array(legacyLexical.joined(separator: " ")))
        let legacyLexicalWER = errorRate(expectedLexical, legacyLexical)
        let fullLineLexicalCER = errorRate(Array(expectedLexical.joined(separator: " ")), Array(fullLineLexical.joined(separator: " ")))
        let fullLineLexicalWER = errorRate(expectedLexical, fullLineLexical)
        let legacyFullCER = errorRate(Array(expectedFull), Array(legacyFull))
        let legacyFullWER = errorRate(expectedFull.split(separator: " ").map(String.init),
                                      legacyFull.split(separator: " ").map(String.init))
        let fullLineCER = errorRate(Array(expectedFull), Array(fullLineText))
        let fullLineWER = errorRate(expectedFull.split(separator: " ").map(String.init),
                                    fullLineText.split(separator: " ").map(String.init))
        print("Synthetic raster OCR (one sample; not representative of real-photo accuracy)")
        print("Gold: \(source)")
        print("Legacy lexical raw: \(legacyRaw)")
        print("Full-line raw: \(fullRaw)")
        print(String(format: "Legacy lexical CER=%.3f WER=%.3f; full-line lexical CER=%.3f WER=%.3f",
                     legacyLexicalCER, legacyLexicalWER, fullLineLexicalCER, fullLineLexicalWER))
        print(String(format: "Legacy full-text CER=%.3f WER=%.3f; full-line full-text CER=%.3f WER=%.3f; lines=%d",
                     legacyFullCER, legacyFullWER, fullLineCER, fullLineWER, result.contextPage.lines.count))
    }

    private func makeLine(blockID: String, text: String, confidence: Double,
                          rect: CGRect, region: SourceRect) throws -> OCRLine {
        let pageRect = try XCTUnwrap(SourceRect(rect: rect))
        return OCRLine(blockID: blockID,
                       candidates: [OCRCandidate(text: text, confidence: confidence)],
                       regionRect: region,
                       pageRect: pageRect,
                       tokens: [],
                       tokenGeometry: [])
    }

    private func normalizedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func englishWords(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"[A-Za-z]+"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).lowercased() }
    }

    private func errorRate<Element: Equatable>(_ reference: [Element], _ actual: [Element]) -> Double {
        guard !reference.isEmpty else { return actual.isEmpty ? 0 : 1 }
        var previous = Array(0...actual.count)
        for (row, expected) in reference.enumerated() {
            var current = Array(repeating: 0, count: actual.count + 1)
            current[0] = row + 1
            for column in actual.indices {
                let substitution = previous[column] + (expected == actual[column] ? 0 : 1)
                current[column + 1] = min(previous[column + 1] + 1,
                                          min(current[column] + 1, substitution))
            }
            previous = current
        }
        return Double(previous[actual.count]) / Double(reference.count)
    }
}
