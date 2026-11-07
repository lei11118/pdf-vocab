import Foundation
import XCTest
@testable import PdfVocab

final class LayoutBlockContextBuilderTests: XCTestCase {
    func testRealLayoutFixturesProduceExactMappedBlocks() throws {
        struct Selection: Decodable { let location: Int; let length: Int }
        struct Line: Decodable {
            let text: String
            let bbox: [Double]
        }
        struct Sample: Decodable {
            let sampleID: String
            let sourceKind: String
            let textProvenance: String
            let mediaBox: [Double]
            let lines: [Line]
            let selectedLineIndex: Int
            let selectedText: String
            let selectedUTF16Range: Selection
        }
        struct Fixture: Decodable { let samples: [Sample] }

        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "LayoutBlock-Samples", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(fixture.samples.count, 4)

        for sample in fixture.samples {
            XCTAssertTrue(["scanned-image-pdf", "text-layer-pdf"].contains(sample.sourceKind))
            if sample.sourceKind == "scanned-image-pdf" {
                XCTAssertTrue(sample.textProvenance.contains("manual-image-transcription"), sample.sampleID)
            }
            let sourceText = sample.lines.map(\.text).joined(separator: "\n")
            let lineOffsets = sample.lines.indices.map { index in
                sample.lines.prefix(index).reduce(0) { $0 + ($1.text as NSString).length + 1 }
            }
            guard sample.lines.indices.contains(sample.selectedLineIndex),
                  sample.mediaBox.count == 4,
                  let lineOffset = lineOffsets[safe: sample.selectedLineIndex] else {
                XCTFail("Invalid layout fixture \(sample.sampleID)")
                continue
            }
            let localSelection = UTF16Span(location: sample.selectedUTF16Range.location,
                                           length: sample.selectedUTF16Range.length)
            let selection = UTF16Span(location: lineOffset + localSelection.location,
                                      length: localSelection.length)
            XCTAssertEqual(selection.substring(in: sourceText), sample.selectedText, sample.sampleID)
            let lineBounds: [CGRect?] = sample.lines.map { line in
                guard line.bbox.count == 4 else { return nil }
                return CGRect(x: CGFloat(line.bbox[0]),
                              y: CGFloat(line.bbox[1]),
                              width: CGFloat(line.bbox[2]),
                              height: CGFloat(line.bbox[3]))
            }
            let mediaBounds = CGRect(x: CGFloat(sample.mediaBox[0]),
                                     y: CGFloat(sample.mediaBox[1]),
                                     width: CGFloat(sample.mediaBox[2]),
                                     height: CGFloat(sample.mediaBox[3]))
            XCTAssertTrue(lineBounds.compactMap { $0 }.allSatisfy { mediaBounds.contains($0) }, sample.sampleID)
            let trustedBlock = try XCTUnwrap(NativeSentenceContextBuilder.trustedSourceBlock(
                sourceText: sourceText,
                selectedSourceSpans: [selection],
                lineBounds: lineBounds
            ), sample.sampleID)
            let context = try XCTUnwrap(NativeLayoutBlockContextBuilder.build(
                sourceText: sourceText,
                trustedSourceBlock: trustedBlock,
                selectedSourceSpans: [selection],
                documentSHA256: "layout-fixture-\(sample.sampleID)",
                pageIndex: 0
            ), sample.sampleID)

            XCTAssertEqual(context.kind, .layoutBlock, sample.sampleID)
            XCTAssertEqual(context.selectedSourceSpans, [selection], sample.sampleID)
            XCTAssertEqual(context.sourceSpan.length, (context.text as NSString).length, sample.sampleID)
            XCTAssertEqual(context.selectedDisplaySpans.first?.substring(in: context.text),
                           sample.selectedText,
                           sample.sampleID)
        }
    }

    func testStructuralBoundariesDoNotDependOnSentencePunctuation() {
        XCTAssertEqual(LayoutBlockContextBuilder.boundaryKind(for: "51 Rock faults move over time"), .promptStart)
        XCTAssertEqual(LayoutBlockContextBuilder.boundaryKind(for: "1 I've just eaten lunch"), .promptStart)
        XCTAssertEqual(LayoutBlockContextBuilder.boundaryKind(for: "• Choose one answer"), .promptStart)
        XCTAssertEqual(LayoutBlockContextBuilder.boundaryKind(for: "Find nine more words"), .promptStart)
        XCTAssertEqual(LayoutBlockContextBuilder.boundaryKind(for: "Module2-3 Acceleration"), .formulaOrHeading)
        XCTAssertEqual(LayoutBlockContextBuilder.boundaryKind(for: "x = u + at"), .formulaOrHeading)
        XCTAssertNil(LayoutBlockContextBuilder.boundaryKind(for: "3.2 meters per second"))
    }

    func testLayoutBlockRejectsTextBeyondTheTranslationInputBound() {
        let text = "selected " + String(repeating: "context ", count: 260)
        let selected = UTF16Span(location: 0, length: ("selected" as NSString).length)
        XCTAssertGreaterThan((text as NSString).length, LayoutBlockContextBuilder.maximumUTF16Units)

        XCTAssertNil(LayoutBlockContextBuilder.build(sourceText: text,
                                                     sourceSpan: UTF16Span(location: 0,
                                                                           length: (text as NSString).length),
                                                     selectedSourceSpans: [selected],
                                                     documentSHA256: "layout-over-limit",
                                                     pageIndex: 0,
                                                     blockID: "oversized-block"))
    }

    func testNativeLayoutMapsMultipleSpansOnOneRowAndRejectsCrossRowSpans() throws {
        let source = "Body keeps first and second words together."
        let first = try XCTUnwrap(UTF16Span(range: (source as NSString).range(of: "first"), in: source))
        let second = try XCTUnwrap(UTF16Span(range: (source as NSString).range(of: "second"), in: source))
        let geometry = try XCTUnwrap(NativeSentenceContextBuilder.trustedSourceBlock(
            sourceText: source,
            selectedSourceSpans: [first, second],
            lineBounds: [CGRect(x: 20, y: 200, width: 300, height: 16)]
        ))
        let context = try XCTUnwrap(NativeLayoutBlockContextBuilder.build(sourceText: source,
                                                                          trustedSourceBlock: geometry,
                                                                          selectedSourceSpans: [first, second],
                                                                          documentSHA256: "native-multiple-spans",
                                                                          pageIndex: 0))

        XCTAssertEqual(context.kind, .layoutBlock)
        XCTAssertEqual(context.selectedSourceSpans, [first, second])
        XCTAssertEqual(context.selectedDisplaySpans.compactMap { $0.substring(in: context.text) },
                       ["first", "second"])

        let multiline = "Body starts here.\nSecond line continues."
        let start = try XCTUnwrap(UTF16Span(range: (multiline as NSString).range(of: "starts"), in: multiline))
        let continues = try XCTUnwrap(UTF16Span(range: (multiline as NSString).range(of: "continues"), in: multiline))
        let unverifiedFullPageBlock = TrustedSourceBlock(sourceSpan: UTF16Span(location: 0,
                                                                                length: (multiline as NSString).length),
                                                         leadingEdgeTruncated: false,
                                                         trailingEdgeTruncated: false)
        XCTAssertNil(NativeLayoutBlockContextBuilder.build(sourceText: multiline,
                                                           trustedSourceBlock: unverifiedFullPageBlock,
                                                           selectedSourceSpans: [start, continues],
                                                           documentSHA256: "native-cross-row-spans",
                                                           pageIndex: 0))
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
