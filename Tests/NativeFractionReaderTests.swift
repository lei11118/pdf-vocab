import PDFKit
import UIKit
import XCTest
@testable import PdfVocab

@MainActor
final class NativeFractionReaderTests: XCTestCase {
    #if DEBUG
    func testReaderAuditFractionKeepsItsRuleAndGlyphsAfterPDFRewrite() throws {
        let document = try XCTUnwrap(PDFDocument(data: HumanReadingAuditFixture.nativePDF()))
        let page = try XCTUnwrap(document.page(at: 0))
        let scan = PDFTextLayout.scan(on: page)
        let neighbors = scan.glyphs.filter { $0.rect.midX > 365 && $0.rect.midY < 265 }
            .map { "\($0.text) rect=\($0.rect) base=\($0.baseline)" }
        let rules = scan.horizontalRules.map { "\($0.start) \($0.end) width=\($0.lineWidth)" }
        let fraction = try XCTUnwrap(NativeFractionLayout.detect(in: scan).first,
                                     "PDF glyphs: \(neighbors), PDF rules: \(rules)")
        let reading = try XCTUnwrap(NativeFractionReadingSelection.build(fraction: fraction, on: page),
                                    "Detected region \(fraction.region), glyphs \(fraction.orderedGlyphs.map(\.sourceIndex))")
        XCTAssertEqual(reading.whole.readingResult?.latex, "\\frac{73}{91}")
    }
    #endif

    func testHostedPressSelectsWholeFractionThenGlyphAndRuleWithExactRanges() throws {
        let (document, page) = try makeFractionPage()
        let source = try XCTUnwrap(page.string) as NSString
        let numeratorCandidate = source.range(of: "x+1")
        let denominatorCandidate = source.range(of: "x+2")
        let numeratorRange = try XCTUnwrap(numeratorCandidate.location == NSNotFound ? nil : numeratorCandidate)
        let denominatorRange = try XCTUnwrap(denominatorCandidate.location == NSNotFound ? nil : denominatorCandidate)
        let plusRange = NSRange(location: numeratorRange.location + 1, length: 1)
        let expectedGlyphRanges = glyphRanges(numeratorRange) + glyphRanges(denominatorRange)

        let defaults = UserDefaults.standard
        let oldContextFlag = defaults.object(forKey: FeatureFlags.contextReadingEnabledKey)
        let oldMathFlag = defaults.object(forKey: FeatureFlags.mathEnabledKey)
        defaults.set(true, forKey: FeatureFlags.contextReadingEnabledKey)
        defaults.set(true, forKey: FeatureFlags.mathEnabledKey)
        defer {
            if let oldContextFlag { defaults.set(oldContextFlag, forKey: FeatureFlags.contextReadingEnabledKey) }
            else { defaults.removeObject(forKey: FeatureFlags.contextReadingEnabledKey) }
            if let oldMathFlag { defaults.set(oldMathFlag, forKey: FeatureFlags.mathEnabledKey) }
            else { defaults.removeObject(forKey: FeatureFlags.mathEnabledKey) }
        }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let view = VocabPDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let controller = UIViewController()
        controller.view = view
        window.frame = view.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        view.displayMode = .singlePage
        view.document = document
        view.scaleFactor = 1.5
        view.layoutDocumentView()
        view.go(to: page)

        func pagePoint(for range: NSRange) throws -> CGPoint {
            let selection = try XCTUnwrap(page.selection(for: range))
            let rect = selection.bounds(for: page)
            XCTAssertTrue(SelectionGeometry.isValid(rect))
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        func viewPoint(for range: NSRange) throws -> CGPoint {
            view.convert(try pagePoint(for: range), from: page)
        }
        func longPress(at point: CGPoint) {
            let press = MutableNativeFractionPress(point: point)
            coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
            press.testState = .ended
            coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
        }

        var selected: [SelectionInfo] = []
        let coordinator = ReaderCoordinator(onPageChanged: { _ in }, onSelectionInfo: {
            if let info = $0 { selected.append(info) }
        })
        coordinator.pdfView = view
        coordinator.setContextReadingMode(true, generation: 1)
        coordinator.hapticsEnabled = false

        let numeratorPoint = try pagePoint(for: plusRange)
        let scan = PDFTextLayout.scan(on: page)
        let layout = try XCTUnwrap(NativeFractionLayout.detect(in: scan).first,
                                   "Expected geometry for both rows. Rules: \(scan.horizontalRules)")
        _ = try XCTUnwrap(NativeFractionReadingSelection.build(fraction: layout, on: page))
        let firstTarget = try XCTUnwrap(coordinator.nativeFractionPressTarget(on: page, at: numeratorPoint),
                                          "Expected a hit at \(numeratorPoint) inside \(layout.region)")
        guard case .whole = firstTarget.detail.scope else {
            return XCTFail("The first candidate press must select the whole fraction")
        }
        XCTAssertEqual(firstTarget.detail.sourceText, "(x+1)/(x+2)")
        XCTAssertEqual(firstTarget.detail.sourceRanges, expectedGlyphRanges)
        XCTAssertEqual(coalesced(visibleRanges(of: firstTarget.detail.selection, on: page, source: source)),
                       [numeratorRange, denominatorRange].sorted { $0.location < $1.location })

        longPress(at: view.convert(numeratorPoint, from: page))
        XCTAssertEqual(selected.last?.text, "(x+1)/(x+2)")
        XCTAssertEqual(selected.last?.mathReadingResult?.sourceText, "(x+1)/(x+2)")
        XCTAssertEqual(selected.last?.mathReadingResult?.status, .parsedText)

        let glyphTarget = try XCTUnwrap(coordinator.nativeFractionPressTarget(on: page, at: numeratorPoint))
        guard case .glyph = glyphTarget.detail.scope else {
            return XCTFail("A repeated press must select the exact source glyph")
        }
        XCTAssertEqual(glyphTarget.detail.sourceText, "+")
        XCTAssertEqual(glyphTarget.detail.sourceRanges, [plusRange])
        longPress(at: view.convert(numeratorPoint, from: page))
        XCTAssertEqual(selected.last?.text, "+")
        XCTAssertTrue(selected.last?.mathDetail == true)

        let rulePoint = CGPoint(x: (firstTarget.fraction.rule.start.x + firstTarget.fraction.rule.end.x) * 0.5,
                                y: (firstTarget.fraction.rule.start.y + firstTarget.fraction.rule.end.y) * 0.5)
        let ruleTarget = try XCTUnwrap(coordinator.nativeFractionPressTarget(on: page, at: rulePoint))
        guard case .whole = ruleTarget.detail.scope else {
            return XCTFail("A rule hit must address the whole fraction")
        }
        XCTAssertEqual(ruleTarget.detail.sourceRanges, expectedGlyphRanges)
        XCTAssertEqual(coalesced(visibleRanges(of: ruleTarget.detail.selection, on: page, source: source)),
                       [numeratorRange, denominatorRange].sorted { $0.location < $1.location })
        longPress(at: view.convert(rulePoint, from: page))
        XCTAssertEqual(selected.last?.text, "(x+1)/(x+2)")

        coordinator.dismissSelection()
        defaults.set(false, forKey: FeatureFlags.mathEnabledKey)
        longPress(at: view.convert(numeratorPoint, from: page))
        XCTAssertNotEqual(selected.last?.text, "(x+1)/(x+2)")
        XCTAssertNil(selected.last?.mathReadingResult,
                     "Disabling math keeps the existing ordinary selection route")
        coordinator.dismissSelection()
    }

    private func makeFractionPage() throws -> (PDFDocument, PDFPage) {
        let bounds = CGRect(x: 0, y: 0, width: 420, height: 340)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("x+x" as NSString).draw(at: CGPoint(x: 48, y: 270),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            ("x+1;" as NSString).draw(at: CGPoint(x: 170, y: 115),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 26)])
            ("x+2;" as NSString).draw(at: CGPoint(x: 170, y: 195),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 26)])
            context.cgContext.setLineWidth(1)
            context.cgContext.move(to: CGPoint(x: 165, y: 168))
            context.cgContext.addLine(to: CGPoint(x: 235, y: 168))
            context.cgContext.strokePath()
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        return (document, try XCTUnwrap(document.page(at: 0)))
    }

    private func glyphRanges(_ range: NSRange) -> [NSRange] {
        (range.location..<NSMaxRange(range)).map { NSRange(location: $0, length: 1) }
    }

    private func visibleRanges(of selection: PDFSelection, on page: PDFPage, source: NSString) -> [NSRange] {
        (0..<selection.numberOfTextRanges(on: page)).flatMap { index in
            let range = selection.range(at: index, on: page)
            return (range.location..<NSMaxRange(range)).compactMap { offset -> NSRange? in
                let character = source.rangeOfComposedCharacterSequence(at: offset)
                guard character.location == offset,
                      !source.substring(with: character).allSatisfy(\.isWhitespace) else { return nil }
                return character
            }
        }
    }

    private func coalesced(_ ranges: [NSRange]) -> [NSRange] {
        let ordered = ranges.sorted {
            $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
        }
        var result: [NSRange] = []
        for range in ordered {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSRange(location: last.location,
                                                   length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

@MainActor
private final class MutableNativeFractionPress: UILongPressGestureRecognizer {
    private let hit: CGPoint
    var testState: UIGestureRecognizer.State = .began

    init(point: CGPoint) {
        hit = point
        super.init(target: nil, action: nil)
    }

    override var state: UIGestureRecognizer.State {
        get { testState }
        set { testState = newValue }
    }

    override func location(in view: UIView?) -> CGPoint { hit }
}
