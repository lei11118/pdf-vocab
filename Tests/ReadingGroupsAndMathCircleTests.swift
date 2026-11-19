import PDFKit
import UIKit
import XCTest
@testable import PdfVocab

final class ReadingPhraseGrouperTests: XCTestCase {
    func testReadingGroupsFromProseAndAcademicSentences() throws {
        XCTAssertNotNil(EnglishReadingTagger.bundled, "The reading group tagger must work with packaged assets and no system downloads.")
        let examples: [(String, String, String?)] = [
            ("She looked up the unfamiliar word before class.", "looked", "looked up"),
            ("She looked up the unfamiliar word before class.", "up", "looked up"),
            ("She looked up the unfamiliar word before class.", "word", "unfamiliar word"),
            ("She looked up at the sky.", "looked", nil),
            ("She looked up the chimney.", "looked", nil),
            ("They carried out the experiment twice.", "out", "carried out"),
            ("She took into account the measurement error.", "account", "took into account"),
            ("The board turned the offer down after the vote.", "turned", "turned the offer down"),
            ("The crew put the fire out before dawn.", "out", "put the fire out"),
            ("The driver turned the car down the street.", "turned", nil),
            ("The researchers did not rule out a sampling error.", "not", "did not rule out"),
            ("The report does not completely rule out a leak.", "completely", "does not completely rule out"),
            ("The researchers did not rule out a sampling error.", "out", "did not rule out"),
            ("The results don't support that conclusion.", "don't", "don't support"),
            ("The shear load could not explain the failure.", "explain", "could not explain"),
            ("The two readings didn't differ by much.", "differ", "didn't differ by much"),
            ("The normal force does no work along this path.", "work", "does no work"),
            ("I could hardly hear the announcement.", "hardly", "could hardly hear"),
            ("The coefficient of friction did not change under load.", "friction", "coefficient of friction"),
            ("The small trial found no statistically significant difference.", "difference", "no statistically significant difference"),
            ("A statistically significant result is not necessarily useful.", "necessarily", "not necessarily"),
            ("A high-frequency signal was recorded.", "signal", "high-frequency signal"),
            ("The bank financed the path along the river bank.", "river", "river bank"),
            ("The result, based on three trials, was published.", "result", nil),
            ("Wait, for once, before answering.", "Wait", nil),
            ("charge charge 3.2 +", "charge", nil),
            ("omega delta", "omega", nil),
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

    @MainActor
    func testNativePDFPhraseWrapRequiresTrustedSingleColumn() throws {
        for secondLineX in [50.0, 330.0] {
            let doc = try XCTUnwrap(PDFDocument(data: UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 720, height: 780))
                .pdfData { context in
                    context.beginPage()
                    let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 17)]
                    ("The controller reports the rate" as NSString).draw(at: CGPoint(x: 50, y: 100), withAttributes: attributes)
                    ("of change once every few seconds." as NSString).draw(at: CGPoint(x: secondLineX, y: 121), withAttributes: attributes)
                }))
            let page = try XCTUnwrap(doc.page(at: 0))
            let source = try XCTUnwrap(page.string)
            let raw = source as NSString
            let anchor = try XCTUnwrap(UTF16Span(range: raw.range(of: "rate"), in: source))
            let end = NSMaxRange(raw.range(of: "change"))
            let span = UTF16Span(location: anchor.location, length: end - anchor.location)
            let selection = try XCTUnwrap(page.selection(for: try XCTUnwrap(span.nsRange(in: source))))
            let contextual = ContextSelectionRouter.route(selection: selection, page: page,
                documentSHA256: "wrapped", pageIndex: 0, displaySurface: "rate of change", geometryQuality: .word,
                generation: 1, verifiedPhraseGroupSpan: span, verifiedPhraseAnchorSpan: anchor)
            if secondLineX == 50.0 {
                let context = try XCTUnwrap(contextual?.sentenceContext)
                XCTAssertEqual(try ContextualTranslationRequest.make(from: context, verifiedPhraseGroupSpan: span)
                    .selectedSourcePhrase, "rate of change")
            } else {
                XCTAssertNil(contextual)
            }
        }
    }

    private func group(in source: String, selected: String, origin: Int = 0, allowWrap: Bool = false) throws
        -> ReadingPhraseGroup? {
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
    func testRasterFixtureHasAnImageAndNoVisibleNativeGlyphs() throws {
        let document = try XCTUnwrap(PDFDocument(data: HumanReadingAuditFixture.scanPDF()))
        let page = try XCTUnwrap(document.page(at: 0))
        let scan = PDFTextLayout.scan(on: page)
        XCTAssertTrue(scan.glyphs.isEmpty)
        XCTAssertTrue(scan.imageBounds.contains { $0.contains(CGPoint(x: 85, y: 278)) })
    }

    @MainActor
    func testTimeDependentSchrodingerPreservesThreeFractionsAndSourceGlyphs() throws {
        let data = HumanReadingAuditFixture.schrodingerPDF(raster: false)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let scan = PDFTextLayout.scan(on: page)
        let fractions = NativeFractionLayout.detect(in: scan)
        let indices = Set(scan.glyphs.indices.filter { !scan.glyphs[$0].text.allSatisfy(\.isWhitespace) })
        let contents = "PDFKit=\(page.string ?? "") scan=\(scan.glyphs.map(\.text).joined(separator: "|")) "
            + "fraction rows=\(fractions.map { $0.orderedGlyphs.map(\.glyph.text).joined() })"
            + " fraction LaTeX=\(fractions.map { NativeFractionReadingSelection.geometryResult(for: $0)?.latex ?? "?" })"
        if fractions.count != 3 {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "com.adobe.pdf")
            attachment.name = "schrodinger-native-vector-fixture.pdf"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(fractions.count, 3, contents)
        let expected = try XCTUnwrap(MathReadingService.resolve(
            #"-\frac{\hbar^{2}}{2m}\frac{\partial^{2}\Psi(x,t)}{\partial x^{2}}+U(x,t)\Psi(x,t)=i\hbar\frac{\partial\Psi(x,t)}{\partial t}"#
        ))
        XCTAssertEqual(expected.status, .parsedText)
        let equation = try XCTUnwrap(NativeEquationCircleSelection.build(glyphs: scan.glyphs, enclosedIndices: indices,
                                                                         fractions: fractions), contents)
        XCTAssertEqual(equation.whole.readingResult?.latex, expected.latex)
        XCTAssertEqual(equation.whole.readingResult?.ast, expected.ast)
        XCTAssertTrue(indices.allSatisfy { equation.whole.region.contains(scan.glyphs[$0].rect) })

        for text in ["∂", "²"] {
            let glyph = try XCTUnwrap(fractions[1].denominator.glyphs.first { $0.glyph.text == text })
            let point = CGPoint(x: glyph.glyph.rect.midX, y: glyph.glyph.rect.midY)
            let detail = try XCTUnwrap(equation.detail(at: point))
            XCTAssertTrue(detail.isGlyph)
            XCTAssertEqual(detail.readingResult?.sourceText, text)
            XCTAssertEqual(detail.region, glyph.glyph.rect)
        }
        let rule = fractions[1].rule
        let bar = CGPoint(x: (rule.start.x + rule.end.x) / 2, y: (rule.start.y + rule.end.y) / 2)
        XCTAssertEqual(equation.detail(at: bar)?.readingResult?.sourceText, "(∂²Ψ(x,t))/(∂x²)")
        let missing = indices.subtracting([fractions[1].denominator.glyphs[0].sourceIndex])
        XCTAssertNil(NativeEquationCircleSelection.build(glyphs: scan.glyphs, enclosedIndices: missing,
                                                          fractions: fractions))
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

