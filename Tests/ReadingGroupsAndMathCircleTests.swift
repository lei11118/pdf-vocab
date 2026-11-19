import PDFKit
import UIKit
import XCTest
@testable import PdfVocab

final class ReadingPhraseGrouperTests: XCTestCase {
    func testReadingGroupsFromProseAndAcademicSentences() throws {
        let examples: [(String, String, String?)] = [
            ("She looked up the unfamiliar word before class.", "looked", "looked up"),
            ("She looked up the unfamiliar word before class.", "up", "looked up"),
            ("She looked up the unfamiliar word before class.", "word", "unfamiliar word"),
            ("She looked up at the sky.", "looked", nil),
            ("She looked up the chimney.", "looked", nil),
            ("They carried out the experiment twice.", "out", "carried out"),
            ("She took into account the measurement error.", "account", "took into account"),
            ("The board turned the offer down after the vote.", "turned", nil),
            ("The researchers did not rule out a sampling error.", "not", "did not rule out"),
            ("The researchers did not rule out a sampling error.", "out", "did not rule out"),
            ("The results don't support that conclusion.", "don't", "don't support"),
            ("The shear load could not explain the failure.", "explain", "could not explain"),
            ("I could hardly hear the announcement.", "hardly", "could hardly hear"),
            ("The coefficient of friction did not change under load.", "friction", "coefficient of friction"),
            ("The small trial found no statistically significant difference.", "difference", "no statistically significant difference"),
            ("A statistically significant result is not necessarily useful.", "necessarily", "not necessarily"),
            ("A high-frequency signal was recorded.", "signal", "high-frequency signal"),
            ("The bank financed the path along the river bank.", "river", "river bank"),
            ("The result, based on three trials, was published.", "result", nil),
            ("Wait, for once, before answering.", "Wait", nil),
        ]
        for (sentence, selected, expected) in examples {
            XCTAssertEqual(try group(in: sentence, selected: selected)?.sourceSurface, expected,
                           "\(sentence) • \(selected)")
        }
    }

    func testWrapAndExactOccurrenceKeepOriginalUTF16Coordinates() throws {
        let text = "😀 The trial shows the rate\nof change over time. The new rate of change is lower."
        let result = try XCTUnwrap(group(in: text, selected: "rate", origin: 41, allowWrap: true))
        XCTAssertEqual(result.sourceSurface, "rate of change")
        XCTAssertEqual(result.sourceSpan.location, 41 + (text as NSString).range(of: "rate").location)
        XCTAssertEqual(result.sourceSpan.length, "rate\nof change".utf16.count)
        XCTAssertNil(try group(in: text, selected: "rate", origin: 41, allowWrap: false))
        XCTAssertNil(try group(in: "An estimate of\n\nchange was reported.", selected: "change", allowWrap: false))
    }

    private func group(in source: String, selected: String, origin: Int = 0, allowWrap: Bool = false) throws
        -> VerifiedPhraseGroup? {
        let range = (source as NSString).range(of: selected)
        let absolute = UTF16Span(location: origin + range.location, length: range.length)
        let span = UTF16Span(location: origin, length: source.utf16.count)
        let context = SentenceContext(documentSHA256: "fixture", pageIndex: 0, blockID: "page",
                                     text: source, displayLineText: source, displaySentenceText: source,
                                     sourceSpan: span, displaySpan: UTF16Span(location: 0, length: span.length),
                                     selectedSourceSpans: [absolute], selectedDisplaySpans: [], kind: .layoutBlock)
        return ReadingPhraseGrouper.group(in: context, selected: absolute,
                                          sourceText: nil, allowsLineWrap: allowWrap)
    }
}

final class MathCircleTests: XCTestCase {
    func testCircleAcceptsLooseClosingStrokeAndUsesActualOutline() {
        let bounds = CGRect(x: 100, y: 50, width: 125, height: 65)
        let points = Self.ellipse(in: bounds, revolution: 0.94)
        XCTAssertTrue(MathCircle.accepts(points))
        XCTAssertTrue(MathCircle(points).contains(CGPoint(x: bounds.midX, y: bounds.midY)))
        XCTAssertFalse(MathCircle(points).contains(CGPoint(x: bounds.minX + 1, y: bounds.minY + 1)))
        XCTAssertFalse(MathCircle.accepts(Self.ellipse(in: bounds, revolution: 0.5)))
        XCTAssertFalse(MathCircle.accepts(Self.ellipse(in: bounds.insetBy(dx: 0, dy: 29))))
        XCTAssertFalse(MathCircle.accepts((0..<20).map { CGPoint(x: $0 * 6, y: $0 * 2) }))
    }

    @MainActor
    func testReaderCircleRequiresCompleteFractionAndWorksWithContextDisabled() throws {
        let pdf = try XCTUnwrap(PDFDocument(data: HumanReadingAuditFixture.nativePDF()))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 620, height: 840))
        view.displayMode = .singlePage
        view.document = pdf
        view.scaleFactor = 0.92
        view.layoutDocumentView()
        view.go(to: page)
        let scan = PDFTextLayout.scan(on: page)
        let fraction = try XCTUnwrap(NativeFractionLayout.detect(in: scan).first)
        var info: SelectionInfo?
        var message: String?
        let coordinator = ReaderCoordinator(onPageChanged: { _ in }, onSelectionInfo: { info = $0 })
        coordinator.pdfView = view
        coordinator.onFormulaCircleOutcome = { message = $0 }
        coordinator.setFormulaCircleActive(true)
        coordinator.completeFormulaCircle(Self.ellipse(in: view.convert(fraction.numerator.region, from: page)
            .insetBy(dx: -8, dy: -5)))
        XCTAssertNil(info)
        XCTAssertTrue(coordinator.formulaCircleActive)
        XCTAssertNotNil(message)

        coordinator.completeFormulaCircle(Self.ellipse(in: view.convert(fraction.region, from: page)
            .insetBy(dx: -15, dy: -15)))
        XCTAssertEqual(info?.mathReadingResult?.latex, "\\frac{73}{91}")
        XCTAssertNotNil(info?.mathSourceImage)
        XCTAssertFalse(coordinator.formulaCircleActive)
        XCTAssertNil(message)
        coordinator.dismissSelection()
    }

    private static func ellipse(in rect: CGRect, revolution: Double = 1) -> [CGPoint] {
        (0...36).map { i in
            let angle = 2 * Double.pi * Double(i) / 36 * revolution
            return CGPoint(x: rect.midX + rect.width / 2 * cos(angle),
                           y: rect.midY + rect.height / 2 * sin(angle))
        }
    }
}

