import Foundation
import ImageIO
import PDFKit
import UIKit
import XCTest
@testable import PdfVocab

@MainActor
final class RealScanContextTests: XCTestCase {
    func testRealScannedLinesSelectClassroomAndBuildLayoutBlockRequest() throws {
        let bundle = Bundle(for: Self.self)
        let imageURL = try XCTUnwrap(bundle.url(forResource: "IELTS-context-strip", withExtension: "png"))
        let imageData = try Data(contentsOf: imageURL)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(imageData as CFData, nil))
        let scannedStrip = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))

        // The source crop is 253.44 × 25.2 PDF points. The 20-point margin
        // keeps it away from the renderer's page edges without resizing it.
        let imageRect = CGRect(x: 20, y: 20, width: 253.44, height: 25.2)
        let pageBounds = CGRect(x: 0, y: 0, width: 293.44, height: 65.2)
        let pdfData = UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { renderer in
            renderer.beginPage()
            UIImage(cgImage: scannedStrip, scale: 1, orientation: .up).draw(in: imageRect)
        }
        let document = try XCTUnwrap(PDFDocument(data: pdfData))
        let pdfPage = try XCTUnwrap(document.page(at: 0))
        XCTAssertTrue(OCRService.needsOCR(page: pdfPage))

        let currentRevision = ContextOCRPage.currentRevision
        let recognized = try OCRService.recognizeContextPage(page: pdfPage,
                                                              documentSHA256: "real-scan-context-strip",
                                                              pageIndex: 0,
                                                              revision: currentRevision)
        XCTAssertEqual(recognized.contextPage.revision, currentRevision)
        XCTAssertFalse(recognized.contextPage.lines.isEmpty, "Vision should return lines for the bundled scan crop")

        let goldLines = [
            "Complete IELTS Bands 4–5.5 is a short course of 50–60",
            "classroom hours for students who wish to take the"
        ]
        let recognizedLines = recognized.contextPage.lines
            .sorted { ($0.pageRect?.y ?? 0) > ($1.pageRect?.y ?? 0) }
            .map(\.sourceText)
        let goldText = Self.normalizedWhitespace(goldLines.joined(separator: " "))
        let recognizedText = Self.normalizedWhitespace(recognizedLines.joined(separator: " "))
        let goldWords = goldText.split(separator: " ").map(String.init)
        let recognizedWords = recognizedText.split(separator: " ").map(String.init)
        let characterErrorRate = Double(Self.editDistance(Array(goldText), Array(recognizedText)))
            / Double(max(1, goldText.count))
        let wordErrorRate = Double(Self.editDistance(goldWords, recognizedWords))
            / Double(max(1, goldWords.count))
        print(String(format: "Real scan crop OCR (one crop): CER=%.3f WER=%.3f lines=%d",
                     characterErrorRate, wordErrorRate, recognizedLines.count))

        let selectionSource = try XCTUnwrap(ContextOCRSelectionSource(page: recognized.contextPage))
        let classroomIndex = try XCTUnwrap(selectionSource.entries.firstIndex {
            $0.word.text.compare("classroom", options: [.caseInsensitive]) == .orderedSame
        }, "The real OCR pass must produce a selectable classroom token")
        let classroomEntry = selectionSource.entries[classroomIndex]
        let sourceLine = try XCTUnwrap(recognized.contextPage.lines.indices.contains(classroomEntry.lineIndex)
                                       ? recognized.contextPage.lines[classroomEntry.lineIndex]
                                       : nil)
        XCTAssertEqual(classroomEntry.sourceSpan.substring(in: sourceLine.sourceText), classroomEntry.word.text)
        XCTAssertEqual(classroomEntry.word.text.lowercased(), "classroom")
        let classroomToken = try XCTUnwrap(classroomEntry.tokens.first {
            $0.span == classroomEntry.sourceSpan
        })
        XCTAssertEqual(classroomToken.sourceSurface, classroomEntry.word.text)
        XCTAssertEqual(classroomToken.geometryQuality, .word,
                       "Vision word geometry must not be upgraded to verified character geometry")

        let selection = try XCTUnwrap(selectionSource.contextualSelection(for: classroomIndex...classroomIndex,
                                                                           generation: 1))
        let context = try XCTUnwrap(selection.sentenceContext,
                                    "The incomplete lowercase row should use a bounded layout block")
        XCTAssertEqual(context.kind, .layoutBlock)
        XCTAssertEqual(context.selectedSourceSpans, [classroomEntry.sourceSpan])
        let mapping = try XCTUnwrap(context.sourceSpanMappings.first {
            $0.lineIndex == classroomEntry.lineIndex && $0.sourceSpan == classroomEntry.sourceSpan
        })
        XCTAssertEqual(mapping.contextSpan.substring(in: context.text)?.lowercased(), "classroom")

        let request = try ContextualTranslationRequest.make(from: context)
        XCTAssertEqual(request.selectedSourcePhrase.lowercased(), "classroom")
        XCTAssertEqual(request.selectedSourceSpans, [mapping.contextSpan])
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
    }

    private static func editDistance<Element: Equatable>(_ lhs: [Element], _ rhs: [Element]) -> Int {
        var previous = Array(0...rhs.count)
        for (leftIndex, leftElement) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightElement) in rhs.enumerated() {
                let substitutionCost = leftElement == rightElement ? 0 : 1
                current[rightIndex + 1] = min(
                    min(previous[rightIndex + 1] + 1, current[rightIndex] + 1),
                    previous[rightIndex] + substitutionCost
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
