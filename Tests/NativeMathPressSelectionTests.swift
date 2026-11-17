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

        func pagePoint(for range: NSRange) throws -> CGPoint {
            let selection = try XCTUnwrap(page.selection(for: range))
            let rect = selection.bounds(for: page)
            XCTAssertTrue(SelectionGeometry.isValid(rect))
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        func point(for range: NSRange) throws -> CGPoint {
            view.convert(try pagePoint(for: range), from: page)
        }

        var selected: [String] = []
        let coordinator = ReaderCoordinator(onPageChanged: { _ in }, onSelectionInfo: {
            if let info = $0 { selected.append(info.text) }
        })
        coordinator.pdfView = view
        coordinator.setContextReadingMode(true, generation: 1)
        coordinator.hapticsEnabled = false

        let mPagePoint = try pagePoint(for: mRange)
        let helperTarget = try XCTUnwrap(
            SelectionGeometry.nativeMathPressTarget(on: page, at: mPagePoint),
            "SelectionGeometry rejected E=mc² before ReaderCoordinator routing")
        XCTAssertEqual(helperTarget.lineRange, formulaRange,
                       "The geometry helper must recover the complete source range after PDFKit line fragmentation")
        XCTAssertEqual(source.substring(with: helperTarget.lineRange), "E=mc²",
                       "The geometry helper target must be the parser-verified visual formula")
        let coordinatorTarget = try XCTUnwrap(
            coordinator.nativeMathPressTarget(on: page, at: mPagePoint),
            "ReaderCoordinator rejected the valid helper target; inspect feature, document, or action guards")
        XCTAssertEqual(coordinatorTarget.lineRange, formulaRange,
                       "Coordinator routing must preserve the complete helper range")

        func longPress(at point: CGPoint) {
            let press = MutableNativeMathPress(point: point)
            coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
            press.testState = .ended
            coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
        }

        longPress(at: try point(for: mRange))
        XCTAssertEqual(selected.last, "E=mc²",
                       "Both helper and coordinator accepted the target, so the first press must apply the whole line")
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

#if DEBUG
    func testHumanReadingAuditFormulaHitAtFirstGlyphAfterWordSelection() throws {
        let data = HumanReadingAuditFixture.nativePDF()
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let source = try XCTUnwrap(page.string) as NSString
        let formulaRange = try XCTUnwrap(source.range(of: "E=mc²").location == NSNotFound
            ? nil : source.range(of: "E=mc²"))
        let classroomRange = try XCTUnwrap(source.range(of: "classroom").location == NSNotFound
            ? nil : source.range(of: "classroom"))
        let eRange = NSRange(location: formulaRange.location, length: 1)
        let mRange = try XCTUnwrap(source.range(of: "m", options: [], range: formulaRange).location == NSNotFound
            ? nil : source.range(of: "m", options: [], range: formulaRange))
        let superscriptRange = try XCTUnwrap(source.range(of: "²", options: [], range: formulaRange).location == NSNotFound
            ? nil : source.range(of: "²", options: [], range: formulaRange))

        let eGlyph = try XCTUnwrap(page.selection(for: eRange))
        let eBounds = eGlyph.bounds(for: page)
        XCTAssertTrue(SelectionGeometry.isValid(eBounds))
        let ePagePoint = CGPoint(x: eBounds.midX, y: eBounds.midY)
        func pagePoint(for range: NSRange) throws -> CGPoint {
            let selection = try XCTUnwrap(page.selection(for: range))
            let rect = selection.bounds(for: page)
            XCTAssertTrue(SelectionGeometry.isValid(rect))
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        var coldDiagnostics: [String] = []
        let coldTarget = try XCTUnwrap(
            SelectionGeometry.nativeMathPressTarget(
                on: page, at: ePagePoint, diagnostic: { coldDiagnostics.append($0) }),
            "The first-glyph center must resolve while this DEBUG fixture page has no cached word geometry\n"
                + coldDiagnostics.joined(separator: "\n"))
        XCTAssertEqual(coldTarget.lineRange, formulaRange,
                       "A cold E-center hit must map to the exact complete formula source range")
        XCTAssertEqual(coldTarget.glyphRange, eRange,
                       "A cold hit at the leading glyph center must retain the E source range")

        let classroomPagePoint = try pagePoint(for: classroomRange)
        let classroomSelection = try XCTUnwrap(
            SelectionGeometry.initialWord(on: page, at: classroomPagePoint),
            "The DEBUG fixture's linked classroom word must build the same warm glyph map as prior reader selection")
        XCTAssertEqual(SelectionGeometry.lookupText(for: classroomSelection), "classroom")
        var warmDiagnostics: [String] = []
        let warmTarget = try XCTUnwrap(
            SelectionGeometry.nativeMathPressTarget(
                on: page, at: ePagePoint, diagnostic: { warmDiagnostics.append($0) }),
            "The same raw E-center hit must still resolve after initialWord has warmed placed glyph geometry\n"
                + warmDiagnostics.joined(separator: "\n"))
        XCTAssertEqual(warmTarget.lineRange, formulaRange,
                       "A warm E-center hit must map to the exact complete formula source range")
        XCTAssertEqual(warmTarget.glyphRange, eRange,
                       "A warm hit at the leading glyph center must retain the E source range")

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
            view.convert(try pagePoint(for: range), from: page)
        }

        var selected: [String] = []
        let coordinator = ReaderCoordinator(onPageChanged: { _ in }, onSelectionInfo: {
            if let info = $0 { selected.append(info.text) }
        })
        coordinator.pdfView = view
        coordinator.setContextReadingMode(true, generation: 1)
        coordinator.hapticsEnabled = false
        let coordinatorTarget = try XCTUnwrap(
            coordinator.nativeMathPressTarget(on: page, at: ePagePoint),
            "ReaderCoordinator must accept the warm helper target before the E-center long press")
        XCTAssertEqual(coordinatorTarget.lineRange, formulaRange,
                       "Coordinator routing must preserve the exact DEBUG fixture formula range")
        defer { coordinator.dismissSelection() }

        func longPress(at range: NSRange) throws {
            let press = MutableNativeMathPress(point: try point(for: range))
            coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
            press.testState = .ended
            coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
        }

        try longPress(at: eRange)
        XCTAssertEqual(selected.last, "E=mc²",
                       "The first long press at the DEBUG audit's leading E center must select the whole formula")
        try longPress(at: eRange)
        XCTAssertEqual(selected.last, "E", "The next press at E resolves its exact touched glyph")
        try longPress(at: mRange)
        XCTAssertEqual(selected.last, "m", "A subsequent press at m resolves that exact glyph")
        try longPress(at: superscriptRange)
        XCTAssertEqual(selected.last, "²", "A following press at ² resolves that exact glyph")
    }
#endif

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
        XCTAssertNotNil(SelectionGeometry.nativeMathPressTarget(
            on: page, at: CGPoint(x: rect.midX, y: rect.midY)),
            "The linked formula fixture should qualify in the geometry helper before action guards")
        XCTAssertNil(coordinator.nativeMathPressTarget(on: page, at: CGPoint(x: rect.midX, y: rect.midY)),
                     "Any tappable non-widget action overlapping the formula must block two-level math selection")
        let press = MutableNativeMathPress(point: point)
        coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
        XCTAssertNotEqual(selected, "F = ma", "Linked text keeps the existing native word selection behavior")
        press.testState = .ended
        coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
        coordinator.dismissSelection()
    }

    func testNativeMathPressTargetExpandsSpacedLineFromRightmostGlyph() throws {
        let bounds = CGRect(x: 0, y: 0, width: 360, height: 240)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("F = ma" as NSString).draw(at: CGPoint(x: 45, y: 135),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 30)])
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let source = try XCTUnwrap(page.string) as NSString
        let formulaRange = try XCTUnwrap(source.range(of: "F = ma").location == NSNotFound
            ? nil : source.range(of: "F = ma"))
        let aRange = try XCTUnwrap(source.range(of: "a", options: [], range: formulaRange).location == NSNotFound
            ? nil : source.range(of: "a", options: [], range: formulaRange))
        let glyph = try XCTUnwrap(page.selection(for: aRange))
        let rect = glyph.bounds(for: page)

        let target = try XCTUnwrap(SelectionGeometry.nativeMathPressTarget(
            on: page, at: CGPoint(x: rect.midX, y: rect.midY)),
            "A right-edge hit must recover the complete spaced formula from verified neighboring glyph geometry")
        XCTAssertEqual(target.lineRange, formulaRange,
                       "The leftward scan must preserve every operator and intervening space")
        XCTAssertEqual(source.substring(with: target.lineRange), "F = ma")
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
            let target = SelectionGeometry.nativeMathPressTarget(
                on: page, at: CGPoint(x: rect.midX, y: rect.midY))
            let details = target.map {
                "line=\(NSStringFromRange($0.lineRange)) glyph=\(NSStringFromRange($0.glyphRange))"
            } ?? "nil"
            XCTAssertNil(target,
                         "Prose, long variable names, and stacked text do not qualify as one native formula line: \(token); target=\(details)")
        }

        let stackedLine = source.range(of: "x =")
        XCTAssertNotEqual(stackedLine.location, NSNotFound)
        let xGlyph = try XCTUnwrap(page.selection(for: NSRange(location: stackedLine.location, length: 1)))
        let xRect = xGlyph.bounds(for: page)
        let xTarget = SelectionGeometry.nativeMathPressTarget(
            on: page, at: CGPoint(x: xRect.midX, y: xRect.midY))
        XCTAssertNil(xTarget,
                     "A press on the equation's x must also reject the nearby stacked fraction; got \(xTarget.map { NSStringFromRange($0.lineRange) } ?? "nil")")
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
        let targetDetails = target.map {
            "line=\(NSStringFromRange($0.lineRange)) text=\($0.lineSelection.string ?? "nil")"
        } ?? "nil"
        XCTAssertEqual(target?.lineSelection.string?.trimmingCharacters(in: .whitespacesAndNewlines), "8.86/9.50",
                       "Decimal points between digits remain part of a compact math line; target=\(targetDetails)")
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
