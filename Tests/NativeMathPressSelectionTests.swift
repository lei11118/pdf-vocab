import PDFKit
import UIKit
import XCTest
@testable import PdfVocab

@MainActor
final class NativeMathPressSelectionTests: XCTestCase {
    func testNativeFormulaLongPressSelectsWholeThenExactSiblingGlyphs() throws {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("E=mc²" as NSString).draw(at: CGPoint(x: 50, y: 190),
                                       withAttributes: [.font: UIFont.systemFont(ofSize: 30)])
            ("The answer is x=1." as NSString).draw(at: CGPoint(x: 50, y: 120),
                                                    withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let source = try XCTUnwrap(page.string) as NSString
        let formulaRange = try XCTUnwrap(source.range(of: "E=mc²").location == NSNotFound
            ? nil : source.range(of: "E=mc²"))
        let mRange = try XCTUnwrap(source.range(of: "m", options: [], range: formulaRange).location == NSNotFound
            ? nil : source.range(of: "m", options: [], range: formulaRange))
        let superscriptRange = try XCTUnwrap(source.range(of: "²", options: [], range: formulaRange).location == NSNotFound
            ? nil : source.range(of: "²", options: [], range: formulaRange))

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

        func point(for range: NSRange) throws -> CGPoint {
            let selection = try XCTUnwrap(page.selection(for: range))
            let rect = selection.bounds(for: page)
            XCTAssertTrue(SelectionGeometry.isValid(rect))
            return view.convert(CGPoint(x: rect.midX, y: rect.midY), from: page)
        }

        var selected: [String] = []
        let coordinator = ReaderCoordinator(onPageChanged: { _ in }, onSelectionInfo: {
            if let info = $0 { selected.append(info.text) }
        })
        coordinator.pdfView = view
        coordinator.setContextReadingMode(true, generation: 1)
        coordinator.hapticsEnabled = false

        func longPress(at point: CGPoint) {
            let press = MutableNativeMathPress(point: point)
            coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
            press.testState = .ended
            coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
        }

        longPress(at: try point(for: mRange))
        XCTAssertEqual(selected.last, "E=mc²", "The first press selects the bounded native visual formula line")
        longPress(at: try point(for: mRange))
        XCTAssertEqual(selected.last, "m", "The next press resolves the exact touched glyph")
        longPress(at: try point(for: superscriptRange))
        XCTAssertEqual(selected.last, "²", "A following press can resolve a sibling glyph under the same parent line")

        coordinator.dismissSelection()
        defaults.set(false, forKey: FeatureFlags.mathEnabledKey)
        longPress(at: try point(for: mRange))
        XCTAssertNotEqual(selected.last, "E=mc²", "Math expansion stays off when its setting is disabled")
        coordinator.dismissSelection()
    }

    func testLinkedFormulaDoesNotEnterTwoLevelMathSelection() throws {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("F = ma" as NSString).draw(at: CGPoint(x: 50, y: 170),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 28)])
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let source = try XCTUnwrap(page.string) as NSString
        let formulaRange = try XCTUnwrap(source.range(of: "F = ma").location == NSNotFound
            ? nil : source.range(of: "F = ma"))
        let formula = try XCTUnwrap(page.selection(for: formulaRange))
        let link = PDFAnnotation(bounds: formula.bounds(for: page), forType: .link, withProperties: nil)
        link.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.com/math")))
        page.addAnnotation(link)

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

        var selected: String?
        let coordinator = ReaderCoordinator(onPageChanged: { _ in }, onSelectionInfo: { selected = $0?.text })
        coordinator.pdfView = view
        coordinator.setContextReadingMode(true, generation: 1)
        coordinator.hapticsEnabled = false
        let firstGlyph = try XCTUnwrap(page.selection(for: NSRange(location: formulaRange.location, length: 1)))
        let rect = firstGlyph.bounds(for: page)
        let point = view.convert(CGPoint(x: rect.midX, y: rect.midY), from: page)
        let press = MutableNativeMathPress(point: point)
        coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
        XCTAssertNotEqual(selected, "F = ma", "Linked text keeps the existing native word selection behavior")
        press.testState = .ended
        coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
        coordinator.dismissSelection()
    }

    func testNativeMathPressTargetRejectsProseLongWordsAndStackedText() throws {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 360)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("The answer is x=1." as NSString).draw(at: CGPoint(x: 35, y: 290),
                                                    withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            ("force = mass × acceleration" as NSString).draw(at: CGPoint(x: 35, y: 230),
                                                             withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            ("x =" as NSString).draw(at: CGPoint(x: 35, y: 160),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            ("1" as NSString).draw(at: CGPoint(x: 95, y: 174),
                                   withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            ("2" as NSString).draw(at: CGPoint(x: 95, y: 142),
                                   withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            context.cgContext.fill(CGRect(x: 90, y: 165, width: 22, height: 1))
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let source = try XCTUnwrap(page.string) as NSString

        for token in ["x=1", "force", "1", "2"] {
            let range = source.range(of: token)
            XCTAssertNotEqual(range.location, NSNotFound, "Synthetic fixture includes \(token)")
            let selection = try XCTUnwrap(page.selection(for: range))
            let rect = selection.bounds(for: page)
            XCTAssertNil(SelectionGeometry.nativeMathPressTarget(
                on: page, at: CGPoint(x: rect.midX, y: rect.midY)),
                "Prose, long variable names, and stacked text do not qualify as one native formula line: \(token)")
        }
    }

    func testNativeMathTargetHandlesLongTextPagesAndDecimalFormulaLine() throws {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 600)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            for line in 0..<8 {
                ("Chapter (line) explains the surrounding physical model in ordinary prose." as NSString)
                    .draw(at: CGPoint(x: 35, y: 530 - CGFloat(line) * 34),
                          withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
            }
            ("8.86/9.50" as NSString).draw(at: CGPoint(x: 80, y: 90),
                                          withAttributes: [.font: UIFont.systemFont(ofSize: 26)])
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let source = try XCTUnwrap(page.string) as NSString
        XCTAssertGreaterThan(source.length, 256, "The page source is larger than a single short fixture")
        let formulaRange = try XCTUnwrap(source.range(of: "8.86/9.50").location == NSNotFound
            ? nil : source.range(of: "8.86/9.50"))
        let formula = try XCTUnwrap(page.selection(for: formulaRange))
        let rect = formula.bounds(for: page)

        let target = SelectionGeometry.nativeMathPressTarget(
            on: page, at: CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(target?.lineSelection.string?.trimmingCharacters(in: .whitespacesAndNewlines), "8.86/9.50",
                       "Decimal points between digits remain part of a compact math line")
    }
}

@MainActor
private final class MutableNativeMathPress: UILongPressGestureRecognizer {
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
