import CoreText
import Foundation
import PDFKit
import UIKit
import XCTest
@testable import PdfVocab

@MainActor
final class OCRCharacterRefinementTests: XCTestCase {
    func testExactBoxesMapThroughNonzeroROIAndMediaOffsets() throws {
        let media = try XCTUnwrap(SourceRect(x: 100, y: 200, width: 500, height: 400))
        let sourceLine = try makeLine(text: "abc", pageRect: CGRect(x: 300, y: 360, width: 90, height: 24))
        let roiRect = CGRect(x: 280, y: 340, width: 130, height: 64)
        let observationRect = try XCTUnwrap(ContextOCRGeometry.pageRect(
            fromVisionNormalized: CGRect(x: 0.15, y: 0.30, width: 0.55, height: 0.5),
            in: roiRect))
        let normalizedCharacterBoxes = [
            CGRect(x: 0.22, y: 0.35, width: 0.08, height: 0.25),
            CGRect(x: 0.35, y: 0.35, width: 0.08, height: 0.25),
            CGRect(x: 0.48, y: 0.35, width: 0.08, height: 0.25)
        ]
        let characters = try normalizedCharacterBoxes.enumerated().map { index, normalized in
            OCRCharacterFastSpanEvidence(
                fastSpan: UTF16Span(location: index, length: 1),
                pageRect: try XCTUnwrap(ContextOCRGeometry.pageRect(fromVisionNormalized: normalized, in: roiRect)))
        }
        let observation = OCRCharacterFastObservationEvidence(ordinal: 0,
                                                              text: "abc",
                                                              confidence: 0.42,
                                                              pageRect: observationRect,
                                                              characters: characters)

        let result = OCRCharacterRefiner.validate(line: sourceLine,
                                                  roi: try XCTUnwrap(SourceRect(rect: roiRect)),
                                                  mediaBox: media,
                                                  evidence: [observation])

        XCTAssertNil(result.fallback)
        XCTAssertEqual(result.sourceText, "abc")
        XCTAssertEqual(result.selectedObservationOrdinal, 0)
        XCTAssertEqual(result.boxes.map(\.sourceSpan), (0..<3).map { UTF16Span(location: $0, length: 1) })
        XCTAssertEqual(result.boxes.first?.actualRect,
                       try XCTUnwrap(ContextOCRGeometry.pageRect(fromVisionNormalized: normalizedCharacterBoxes[0],
                                                                in: roiRect)))
        XCTAssertEqual(result.boxes.first?.geometrySource, .visionFast)
        XCTAssertEqual(result.boxes.first?.mappingSource, .mandatoryExactMapping)
    }

    func testOutOfBoundsCharacterBoxIsRejected() throws {
        let media = try XCTUnwrap(SourceRect(x: 100, y: 200, width: 500, height: 400))
        let line = try makeLine(text: "a", pageRect: CGRect(x: 300, y: 360, width: 90, height: 24))
        let observation = try makeObservation(ordinal: 0,
                                              text: "a",
                                              observationRect: CGRect(x: 310, y: 362, width: 18, height: 18),
                                              characterRects: [CGRect(x: 95, y: 364, width: 8, height: 12)])

        let result = OCRCharacterRefiner.validate(line: line,
                                                  roi: try XCTUnwrap(SourceRect(x: 280, y: 340, width: 130, height: 64)),
                                                  mediaBox: media,
                                                  evidence: [observation])

        XCTAssertTrue(result.boxes.isEmpty)
        XCTAssertEqual(result.fallback, .noTrustedCharacterBoxes)
    }

    func testSourceLineMustBeFullyInsideMediaAndROI() throws {
        let media = try XCTUnwrap(SourceRect(x: 100, y: 200, width: 500, height: 400))
        let outsideMediaLine = try makeLine(text: "a", pageRect: CGRect(x: 590, y: 360, width: 20, height: 24))
        let observation = try makeObservation(ordinal: 0,
                                              text: "a",
                                              observationRect: CGRect(x: 595, y: 362, width: 10, height: 18),
                                              characterRects: [CGRect(x: 596, y: 364, width: 8, height: 12)])

        let outsideMediaResult = OCRCharacterRefiner.validate(line: outsideMediaLine,
                                                               roi: try XCTUnwrap(SourceRect(x: 580, y: 340, width: 20, height: 64)),
                                                               mediaBox: media,
                                                               evidence: [observation])
        XCTAssertEqual(outsideMediaResult.fallback, .invalidRegion)

        let line = try makeLine(text: "a", pageRect: CGRect(x: 300, y: 360, width: 90, height: 24))
        let clippedROIResult = OCRCharacterRefiner.validate(line: line,
                                                             roi: try XCTUnwrap(SourceRect(x: 320, y: 340, width: 60, height: 64)),
                                                             mediaBox: media,
                                                             evidence: [observation])
        XCTAssertEqual(clippedROIResult.fallback, .invalidRegion)
    }

    func testWhitespaceSourceCharactersDoNotProduceRefinedBoxes() throws {
        let media = try XCTUnwrap(SourceRect(x: 100, y: 200, width: 500, height: 400))
        let line = try makeLine(text: "a b", pageRect: CGRect(x: 300, y: 360, width: 90, height: 24))
        let observation = try makeObservation(ordinal: 0,
                                             text: "a b",
                                             observationRect: CGRect(x: 310, y: 362, width: 40, height: 18),
                                             characterRects: [
                                                CGRect(x: 312, y: 364, width: 8, height: 12),
                                                CGRect(x: 322, y: 364, width: 5, height: 12),
                                                CGRect(x: 332, y: 364, width: 8, height: 12)
                                             ])

        let result = OCRCharacterRefiner.validate(line: line,
                                                  roi: try XCTUnwrap(SourceRect(x: 280, y: 340, width: 130, height: 64)),
                                                  mediaBox: media,
                                                  evidence: [observation])

        XCTAssertEqual(result.boxes.map(\.sourceSpan), [UTF16Span(location: 0, length: 1),
                                                        UTF16Span(location: 2, length: 1)])
    }

    func testOversizedFastCandidateRetainsRawMetadataAndFallsBack() throws {
        let media = try XCTUnwrap(SourceRect(x: 100, y: 200, width: 500, height: 400))
        let line = try makeLine(text: "a", pageRect: CGRect(x: 300, y: 360, width: 90, height: 24))
        let oversizedText = String(repeating: "a", count: OCRCharacterAligner.maximumGraphemes + 1)
        let observation = OCRCharacterFastObservationEvidence(ordinal: 0,
                                                              text: oversizedText,
                                                              confidence: 0.8,
                                                              pageRect: try XCTUnwrap(SourceRect(x: 310, y: 362, width: 40, height: 18)),
                                                              characters: [])

        let result = OCRCharacterRefiner.validate(line: line,
                                                  roi: try XCTUnwrap(SourceRect(x: 280, y: 340, width: 130, height: 64)),
                                                  mediaBox: media,
                                                  evidence: [observation])

        XCTAssertEqual(result.fallback, .textLimitExceeded)
        XCTAssertEqual(result.observations.first?.text, oversizedText)
        XCTAssertTrue(result.observations.first?.characters.isEmpty == true)
    }

    func testRepeatedFastSpanIsRejected() throws {
        let media = try XCTUnwrap(SourceRect(x: 100, y: 200, width: 500, height: 400))
        let line = try makeLine(text: "a", pageRect: CGRect(x: 300, y: 360, width: 90, height: 24))
        let span = UTF16Span(location: 0, length: 1)
        let repeated = OCRCharacterFastObservationEvidence(ordinal: 0,
                                                           text: "a",
                                                           confidence: 0.8,
                                                           pageRect: try XCTUnwrap(SourceRect(x: 310, y: 362, width: 18, height: 18)),
                                                           characters: [
            OCRCharacterFastSpanEvidence(fastSpan: span,
                                         pageRect: try XCTUnwrap(SourceRect(x: 312, y: 364, width: 8, height: 12))),
            OCRCharacterFastSpanEvidence(fastSpan: span,
                                         pageRect: try XCTUnwrap(SourceRect(x: 313, y: 364, width: 8, height: 12)))
        ])

        let result = OCRCharacterRefiner.validate(line: line,
                                                  roi: try XCTUnwrap(SourceRect(x: 280, y: 340, width: 130, height: 64)),
                                                  mediaBox: media,
                                                  evidence: [repeated])

        XCTAssertTrue(result.boxes.isEmpty)
        XCTAssertEqual(result.fallback, .noTrustedCharacterBoxes)
    }

    func testDifferentSourceCharactersSharingWholeWordBoxAreBothRejected() throws {
        let media = try XCTUnwrap(SourceRect(x: 100, y: 200, width: 500, height: 400))
        let line = try makeLine(text: "ab", pageRect: CGRect(x: 300, y: 360, width: 90, height: 24))
        let sharedRect = try XCTUnwrap(SourceRect(x: 320, y: 364, width: 28, height: 15))
        let observation = OCRCharacterFastObservationEvidence(ordinal: 0,
                                                              text: "ab",
                                                              confidence: 0.9,
                                                              pageRect: try XCTUnwrap(SourceRect(x: 315, y: 362, width: 40, height: 18)),
                                                              characters: [
            OCRCharacterFastSpanEvidence(fastSpan: UTF16Span(location: 0, length: 1), pageRect: sharedRect),
            OCRCharacterFastSpanEvidence(fastSpan: UTF16Span(location: 1, length: 1), pageRect: sharedRect)
        ])

        let result = OCRCharacterRefiner.validate(line: line,
                                                  roi: try XCTUnwrap(SourceRect(x: 280, y: 340, width: 130, height: 64)),
                                                  mediaBox: media,
                                                  evidence: [observation])

        XCTAssertTrue(result.boxes.isEmpty)
        XCTAssertEqual(result.fallback, .noTrustedCharacterBoxes)
    }

    func testCharacterOutsideItsAccurateWordFrameIsRejected() throws {
        let media = try XCTUnwrap(SourceRect(x: 100, y: 200, width: 500, height: 400))
        let lineBounds = CGRect(x: 300, y: 360, width: 90, height: 24)
        let span = UTF16Span(location: 0, length: 1)
        let token = SourceToken(documentSHA256: "refiner-fixture",
                                pageIndex: 0,
                                span: span,
                                sourceSurface: "+",
                                kind: .symbol,
                                blockID: "fixture-line",
                                geometryQuality: .word)
        let tokenGeometry = SourceTokenGeometry(tokenID: token.id,
                                                span: span,
                                                rect: try XCTUnwrap(SourceRect(x: 300, y: 360, width: 20, height: 24)),
                                                quality: .word)
        let line = try makeLine(text: "+", pageRect: lineBounds, tokens: [token], tokenGeometry: [tokenGeometry])
        let observation = try makeObservation(ordinal: 0,
                                             text: "+",
                                             observationRect: CGRect(x: 337, y: 362, width: 18, height: 18),
                                             characterRects: [CGRect(x: 340, y: 364, width: 12, height: 14)])

        let result = OCRCharacterRefiner.validate(line: line,
                                                  roi: try XCTUnwrap(SourceRect(x: 280, y: 340, width: 130, height: 64)),
                                                  mediaBox: media,
                                                  evidence: [observation])

        XCTAssertTrue(result.boxes.isEmpty)
        XCTAssertEqual(result.fallback, .noTrustedCharacterBoxes)
    }

    func testLookalikeSubstitutionDoesNotChangeOrMapSourceText() throws {
        let media = try XCTUnwrap(SourceRect(x: 100, y: 200, width: 500, height: 400))
        let line = try makeLine(text: "ν", pageRect: CGRect(x: 300, y: 360, width: 90, height: 24))
        let observation = try makeObservation(ordinal: 0,
                                              text: "v",
                                              observationRect: CGRect(x: 310, y: 362, width: 18, height: 18),
                                              characterRects: [CGRect(x: 312, y: 364, width: 8, height: 12)])

        let result = OCRCharacterRefiner.validate(line: line,
                                                  roi: try XCTUnwrap(SourceRect(x: 280, y: 340, width: 130, height: 64)),
                                                  mediaBox: media,
                                                  evidence: [observation])

        XCTAssertEqual(result.sourceText, "ν")
        XCTAssertEqual(result.observations.first?.text, "v")
        XCTAssertTrue(result.boxes.isEmpty)
        XCTAssertEqual(result.fallback, .noMandatoryExactMatches)
    }

    func testTiedBestObservationsFallBackWithoutConfidenceTieBreaking() throws {
        let media = try XCTUnwrap(SourceRect(x: 100, y: 200, width: 500, height: 400))
        let line = try makeLine(text: "aa", pageRect: CGRect(x: 300, y: 360, width: 90, height: 24))
        let first = try makeObservation(ordinal: 0,
                                        text: "a",
                                        confidence: 0.99,
                                        observationRect: CGRect(x: 315, y: 362, width: 18, height: 18),
                                        characterRects: [CGRect(x: 318, y: 364, width: 8, height: 12)])
        let second = try makeObservation(ordinal: 1,
                                         text: "a",
                                         confidence: 0.08,
                                         observationRect: CGRect(x: 315, y: 362, width: 18, height: 18),
                                         characterRects: [CGRect(x: 318, y: 364, width: 8, height: 12)])

        let result = OCRCharacterRefiner.validate(line: line,
                                                  roi: try XCTUnwrap(SourceRect(x: 280, y: 340, width: 130, height: 64)),
                                                  mediaBox: media,
                                                  evidence: [first, second])

        XCTAssertTrue(result.boxes.isEmpty)
        XCTAssertEqual(result.fallback, .ambiguousBestObservation)
    }

    func testSyntheticRasterBenchmarkReportsCoreTextGoldAndFastVisionEvidence() throws {
        let sourceText = "charge + beta 3.2"
        let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let baseline = CGPoint(x: 82, y: 406)
        let font = CTFontCreateWithName("Helvetica" as CFString, 52, nil)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let attributedText = NSAttributedString(string: sourceText, attributes: [fontKey: font])
        let ctLine = CTLineCreateWithAttributedString(attributedText)
        let gold = try coreTextGold(line: ctLine, font: font, text: sourceText, origin: baseline)
        XCTAssertFalse(gold.isEmpty, "CoreText must produce independent visible-glyph gold boxes")

        let nativePDF = UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
            context.beginPage()
            let cgContext = context.cgContext
            cgContext.saveGState()
            cgContext.translateBy(x: 0, y: pageBounds.height)
            cgContext.scaleBy(x: 1, y: -1)
            cgContext.textMatrix = .identity
            cgContext.textPosition = baseline
            cgContext.setFillColor(UIColor.black.cgColor)
            CTLineDraw(ctLine, cgContext)
            cgContext.restoreGState()
        }
        let nativePage = try XCTUnwrap(PDFDocument(data: nativePDF)?.page(at: 0))
        let nativeRaster = nativePage.thumbnail(of: CGSize(width: pageBounds.width * 2,
                                                           height: pageBounds.height * 2),
                                                for: .mediaBox)
        let rasterPDF = UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
            context.beginPage()
            nativeRaster.draw(in: pageBounds)
        }
        let scanURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRCharacterRefiner-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: scanURL) }
        try rasterPDF.write(to: scanURL, options: .atomic)

        let scanPage = try XCTUnwrap(PDFDocument(url: scanURL)?.page(at: 0))
        XCTAssertTrue((scanPage.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "The benchmark input must be a photo-only PDF page")
        let accurate = try OCRService.recognizeContextPage(page: scanPage,
                                                           documentSHA256: "ocr-character-refiner-fixture",
                                                           pageIndex: 0,
                                                           revision: 2).contextPage
        for line in accurate.lines { print("Accurate raw line: \(line.sourceText)") }

        var scoredLines: [(line: OCRLine, alignment: OCRCharacterAlignment)] = []
        for line in accurate.lines {
            if case .aligned(let alignment) = OCRCharacterAligner.align(source: sourceText, fast: line.sourceText) {
                scoredLines.append((line, alignment))
            }
        }
        guard let bestDistance = scoredLines.map({ $0.alignment.distance }).min() else {
            XCTFail("Accurate OCR did not provide an alignable source line")
            return
        }
        let bestLines = scoredLines.filter { $0.alignment.distance == bestDistance }
        guard bestLines.count == 1, let best = bestLines.first else {
            XCTFail("Accurate OCR produced tied source-line candidates")
            return
        }

        let refinement = try OCRCharacterRefiner.refine(line: best.line, on: scanPage)
        print("Refiner diagnostic: accurateRect=\(String(describing: best.line.pageRect)), ROI=\(refinement.roi), selectedOrdinal=\(String(describing: refinement.selectedObservationOrdinal)), fallback=\(String(describing: refinement.fallback))")
        XCTAssertGreaterThan(refinement.boxes.count, 0,
                             "The Vision fast path should provide at least one conservatively mapped real character box")
        for observation in refinement.observations {
            print("Vision.fast raw[\(observation.ordinal)] \(observation.text) confidence=\(String(format: "%.3f", observation.confidence)) rect=\(String(describing: observation.pageRect))")
        }

        var goldSpanBySourceSpan: [UTF16Span: UTF16Span] = [:]
        for match in best.alignment.matches {
            goldSpanBySourceSpan[match.fastSpan] = match.sourceSpan
        }
        let goldBySpan = Dictionary(uniqueKeysWithValues: gold.map { ($0.span, $0) })
        var acceptedByGoldSpan: [UTF16Span: CGRect] = [:]
        for box in refinement.boxes {
            guard let goldSpan = goldSpanBySourceSpan[box.sourceSpan] else { continue }
            acceptedByGoldSpan[goldSpan] = box.actualRect.cgRect
        }

        let coveredGold = gold.filter { acceptedByGoldSpan[$0.span] != nil }
        let hitCount = gold.reduce(into: 0) { count, glyph in
            if let box = acceptedByGoldSpan[glyph.span], box.contains(glyph.center) { count += 1 }
        }
        let positionErrors = coveredGold.compactMap { glyph -> CGFloat? in
            guard let box = acceptedByGoldSpan[glyph.span] else { return nil }
            return hypot(box.midX - glyph.center.x, box.midY - glyph.center.y)
        }
        let coverage = Double(coveredGold.count) / Double(max(gold.count, 1))
        let hitRate = Double(hitCount) / Double(max(gold.count, 1))
        let meanPositionError = positionErrors.isEmpty
            ? nil
            : Double(positionErrors.reduce(0, +) / CGFloat(positionErrors.count))
        print("Synthetic raster benchmark: single Latin sample; not representative of real photos")
        print("Gold visible glyphs=\(gold.count), accepted boxes=\(refinement.boxes.count), covered gold=\(coveredGold.count), uncovered gold=\(gold.count - coveredGold.count)")
        print(String(format: "Coverage=%.3f; gold-center hit rate=%.3f (denominator includes uncovered); mean covered-center error=%@ pt (n=%d/%d)",
                     coverage,
                     hitRate,
                     meanPositionError.map { String(format: "%.2f", $0) } ?? "n/a",
                     positionErrors.count,
                     gold.count))

        let selectedFast = refinement.observations.first { $0.ordinal == refinement.selectedObservationOrdinal }
        let overlay = makeOverlay(baseImage: nativeRaster,
                                  pageBounds: pageBounds,
                                  gold: gold,
                                  fast: selectedFast)
        let attachment = XCTAttachment(image: overlay)
        attachment.name = "Character refinement: CoreText gold (yellow), Vision.fast boxes (cyan)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(goldBySpan.count, gold.count)
    }

    private func makeLine(text: String,
                          pageRect: CGRect,
                          tokens: [SourceToken] = [],
                          tokenGeometry: [SourceTokenGeometry] = []) throws -> OCRLine {
        let sourceRect = try XCTUnwrap(SourceRect(rect: pageRect))
        return OCRLine(blockID: "fixture-line",
                       candidates: [OCRCandidate(text: text, confidence: 0.9)],
                       regionRect: sourceRect,
                       pageRect: sourceRect,
                       tokens: tokens,
                       tokenGeometry: tokenGeometry)
    }

    private func makeObservation(ordinal: Int,
                                 text: String,
                                 confidence: Double = 0.8,
                                 observationRect: CGRect,
                                 characterRects: [CGRect]) throws -> OCRCharacterFastObservationEvidence {
        let spans = composedSpans(in: text)
        let characters = spans.enumerated().map { index, span in
            OCRCharacterFastSpanEvidence(fastSpan: span,
                                         pageRect: index < characterRects.count
                                            ? SourceRect(rect: characterRects[index])
                                            : nil)
        }
        return OCRCharacterFastObservationEvidence(ordinal: ordinal,
                                                   text: text,
                                                   confidence: confidence,
                                                   pageRect: SourceRect(rect: observationRect),
                                                   characters: characters)
    }

    private func composedSpans(in text: String) -> [UTF16Span] {
        let nsText = text as NSString
        var spans: [UTF16Span] = []
        var offset = 0
        while offset < nsText.length {
            let range = nsText.rangeOfComposedCharacterSequence(at: offset)
            if let span = UTF16Span(composedRange: range, in: text) { spans.append(span) }
            offset += max(1, range.length)
        }
        return spans
    }

    private struct GoldGlyph {
        let span: UTF16Span
        let text: String
        let rect: CGRect
        var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    }

    private func coreTextGold(line: CTLine,
                              font: CTFont,
                              text: String,
                              origin: CGPoint) throws -> [GoldGlyph] {
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        let nsText = text as NSString
        var gold: [GoldGlyph] = []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let range = CFRange(location: 0, length: count)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var stringIndices = [CFIndex](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var glyphBounds = [CGRect](repeating: .zero, count: count)
            CTRunGetGlyphs(run, range, &glyphs)
            CTRunGetStringIndices(run, range, &stringIndices)
            CTRunGetPositions(run, range, &positions)
            let hasGlyphStorage = glyphs.withUnsafeBufferPointer { glyphBuffer in
                glyphBounds.withUnsafeMutableBufferPointer { boundsBuffer in
                    guard let glyphPointer = glyphBuffer.baseAddress,
                          let boundsPointer = boundsBuffer.baseAddress else { return false }
                    _ = CTFontGetBoundingRectsForGlyphs(font,
                                                        .horizontal,
                                                        glyphPointer,
                                                        boundsPointer,
                                                        count)
                    return true
                }
            }
            guard hasGlyphStorage else {
                throw NSError(domain: "OCRCharacterRefinementTests",
                              code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not allocate CoreText glyph buffers"])
            }

            for glyphIndex in 0..<count {
                let stringIndex = stringIndices[glyphIndex]
                guard stringIndex >= 0, stringIndex < nsText.length else { continue }
                let range = nsText.rangeOfComposedCharacterSequence(at: stringIndex)
                guard let span = UTF16Span(composedRange: range, in: text) else { continue }
                let glyphText = nsText.substring(with: range)
                guard !glyphText.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                    continue
                }
                let localBounds = glyphBounds[glyphIndex]
                guard localBounds.width.isFinite, localBounds.height.isFinite,
                      localBounds.width > 0, localBounds.height > 0 else { continue }
                let position = positions[glyphIndex]
                let pageRect = CGRect(x: origin.x + position.x + localBounds.minX,
                                      y: origin.y + position.y + localBounds.minY,
                                      width: localBounds.width,
                                      height: localBounds.height)
                guard pageRect.minX.isFinite, pageRect.minY.isFinite,
                      pageRect.width.isFinite, pageRect.height.isFinite else { continue }
                gold.append(GoldGlyph(span: span, text: glyphText, rect: pageRect))
            }
        }
        return gold
    }

    private func makeOverlay(baseImage: UIImage,
                             pageBounds: CGRect,
                             gold: [GoldGlyph],
                             fast: OCRCharacterFastObservationEvidence?) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: pageBounds.size, format: format).image { renderer in
            baseImage.draw(in: CGRect(origin: .zero, size: pageBounds.size))
            let context = renderer.cgContext
            context.setLineWidth(1.4)
            context.setStrokeColor(UIColor.systemYellow.cgColor)
            for glyph in gold {
                context.stroke(imageRect(fromPageRect: glyph.rect, pageBounds: pageBounds))
            }
            context.setStrokeColor(UIColor.systemCyan.cgColor)
            for character in fast?.characters ?? [] {
                guard let rect = character.pageRect?.cgRect else { continue }
                context.stroke(imageRect(fromPageRect: rect, pageBounds: pageBounds))
            }
            let label = "Gold glyphs: yellow   Vision.fast boxes: cyan" as NSString
            label.draw(at: CGPoint(x: 8, y: 8), withAttributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: UIColor.white,
                .backgroundColor: UIColor.black.withAlphaComponent(0.75)
            ])
        }
    }

    private func imageRect(fromPageRect rect: CGRect, pageBounds: CGRect) -> CGRect {
        CGRect(x: rect.minX - pageBounds.minX,
               y: pageBounds.maxY - rect.maxY,
               width: rect.width,
               height: rect.height)
    }
}
