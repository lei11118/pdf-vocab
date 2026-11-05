import Foundation
import PDFKit
import UIKit
import XCTest
@testable import PdfVocab

@MainActor
final class ContextOCRSelectionTests: XCTestCase {
    func testCoordinatorPinsCompleteOCRSourceAcrossRefreshAndHoverKeepsAnchor() throws {
        let fixture = try makeBlankPDFView()

        let sha = "context-ocr-selection-\(UUID().uuidString)"
        var events: [SelectionInfo?] = []
        let coordinator = ReaderCoordinator(onPageChanged: { _ in }, onSelectionInfo: { events.append($0) })
        coordinator.pdfView = fixture.view
        coordinator.docSha = sha
        coordinator.hapticsEnabled = false
        coordinator.setContextReadingMode(true, generation: 7)
        coordinator.installGestures(on: fixture.view)
        defer { coordinator.prepareForTeardown(); fixture.close() }

        let original = try makePage(sha: sha, pageIndex: 0, mediaBox: fixture.mediaBox,
                                    blockID: "original-row", text: "charge charge 3.2 +",
                                    tokens: [
                                        TokenFixture(text: "charge", span: UTF16Span(location: 0, length: 6), kind: .word,
                                                     rect: CGRect(x: 40, y: 180, width: 44, height: 20)),
                                        TokenFixture(text: "charge", span: UTF16Span(location: 7, length: 6), kind: .word,
                                                     rect: CGRect(x: 100, y: 180, width: 44, height: 20)),
                                        TokenFixture(text: "3.2", span: UTF16Span(location: 14, length: 3), kind: .number,
                                                     rect: CGRect(x: 160, y: 180, width: 30, height: 20)),
                                        TokenFixture(text: "+", span: UTF16Span(location: 18, length: 1), kind: .symbol,
                                                     rect: CGRect(x: 205, y: 180, width: 18, height: 20))
                                    ])
        XCTAssertTrue(coordinator.installContextOCRPage(original, generation: 7))

        let secondChargePoint = fixture.view.convert(CGPoint(x: 122, y: 190), from: fixture.page)
        var hover: (term: String, anchor: CGPoint)?
        coordinator.onHoverUpdate = { term, _, anchor in hover = (term, anchor) }
        coordinator.perform(NSSelectorFromString("handleHover:"), with: ContextOCRHover(point: secondChargePoint))
        XCTAssertEqual(hover?.term, "charge")
        let secondWord = try XCTUnwrap(ContextOCRSelectionSource(page: original)?.words.dropFirst().first)
        let expectedAnchor = fixture.view.convert(
            OCRService.pageRect(from: secondWord, pageBounds: fixture.page.bounds(for: .mediaBox)),
            from: fixture.page).minY
        XCTAssertEqual(try XCTUnwrap(hover?.anchor.y), expectedAnchor, accuracy: 0.75)

        coordinator.perform(NSSelectorFromString("handleDoubleTap:"),
                            with: ContextOCRTap(point: secondChargePoint))
        let repeatedWord = try XCTUnwrap(events.compactMap { $0 }.last?.contextual)
        XCTAssertEqual(repeatedWord.displaySurface, "charge")
        XCTAssertEqual(repeatedWord.tokens.map(\.sourceSurface), ["charge"])
        XCTAssertEqual(repeatedWord.sourceSpans, [UTF16Span(location: 7, length: 6)])

        let startHandle = try XCTUnwrap(fixture.view.subviews.compactMap { $0 as? SelectionHandleView }
            .first { $0.isStart })
        let handlePan = ContextOCRHandlePan(point: secondChargePoint)
        startHandle.addGestureRecognizer(handlePan)
        coordinator.perform(NSSelectorFromString("handleHandlePan:"), with: handlePan)
        handlePan.point = fixture.view.convert(CGPoint(x: 62, y: 190), from: fixture.page)
        handlePan.testState = .changed
        coordinator.perform(NSSelectorFromString("handleHandlePan:"), with: handlePan)
        let handleSelection = try XCTUnwrap(events.compactMap { $0 }.last?.contextual)
        XCTAssertEqual(handleSelection.displaySurface, "charge charge")
        XCTAssertEqual(handleSelection.sourceSpans, [UTF16Span(location: 0, length: 13)])
        handlePan.testState = .ended
        coordinator.perform(NSSelectorFromString("handleHandlePan:"), with: handlePan)

        let bodyPress = ContextOCRPress(point: fixture.view.convert(CGPoint(x: 72, y: 190), from: fixture.page))
        coordinator.perform(NSSelectorFromString("handlePress:"), with: bodyPress)
        bodyPress.point = fixture.view.convert(CGPoint(x: 175, y: 190), from: fixture.page)
        bodyPress.testState = .changed
        coordinator.perform(NSSelectorFromString("handlePress:"), with: bodyPress)
        let bodySelection = try XCTUnwrap(events.compactMap { $0 }.last?.contextual)
        XCTAssertEqual(bodySelection.displaySurface, "charge 3.2")
        XCTAssertEqual(bodySelection.sourceSpans, [UTF16Span(location: 7, length: 10)])
        bodyPress.testState = .ended
        coordinator.perform(NSSelectorFromString("handlePress:"), with: bodyPress)

        coordinator.dismissSelection()
        let press = ContextOCRPress(point: secondChargePoint)
        coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
        XCTAssertEqual(events.compactMap { $0 }.last?.text, "charge")

        // Replace the cache while the old immutable snapshot is pinned. The
        // legacy OCR completion callback must not move the active selection.
        let replacement = try makePage(sha: sha, pageIndex: 0, mediaBox: fixture.mediaBox,
                                       blockID: "replacement-row", text: "omega delta",
                                       tokens: [
                                           TokenFixture(text: "omega", span: UTF16Span(location: 0, length: 5), kind: .word,
                                                        rect: CGRect(x: 220, y: 130, width: 55, height: 22)),
                                           TokenFixture(text: "delta", span: UTF16Span(location: 6, length: 5), kind: .word,
                                                        rect: CGRect(x: 290, y: 130, width: 48, height: 22))
                                       ])
        let eventCountBeforeRefresh = events.count
        let highlightBoundsBeforeRefresh = fixture.page.annotations.map(\.bounds)
        XCTAssertTrue(coordinator.installContextOCRPage(replacement, generation: 7))
        coordinator.ocrDidFinish()
        XCTAssertEqual(events.count, eventCountBeforeRefresh,
                       "Installing results and finishing legacy OCR are cache-only")
        XCTAssertEqual(fixture.page.annotations.map(\.bounds), highlightBoundsBeforeRefresh,
                       "A cache refresh must not move the active blue OCR selection")

        press.point = fixture.view.convert(CGPoint(x: 175, y: 190), from: fixture.page)
        press.testState = .changed
        coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
        let pinnedRange = try XCTUnwrap(events.compactMap { $0 }.last?.contextual)
        XCTAssertEqual(pinnedRange.displaySurface, "charge 3.2")
        XCTAssertEqual(pinnedRange.sourceSpans, [UTF16Span(location: 7, length: 10)])
        XCTAssertEqual(pinnedRange.tokens.map(\.sourceSurface), ["charge", "3.2"])

        press.testState = .ended
        coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
        coordinator.dismissSelection()

        let replacementPoint = fixture.view.convert(CGPoint(x: 245, y: 141), from: fixture.page)
        coordinator.perform(NSSelectorFromString("handleDoubleTap:"),
                            with: ContextOCRTap(point: replacementPoint))
        let refreshed = try XCTUnwrap(events.compactMap { $0 }.last?.contextual)
        XCTAssertEqual(refreshed.displaySurface, "omega",
                       "Clearing the selection releases the pin and exposes the newest page result")
        XCTAssertEqual(refreshed.tokens.first?.blockID, "replacement-row")
    }

    func testInstallRejectsStaleGenerationDocumentPageMediaAndRevision() throws {
        let fixture = try makeBlankPDFView()
        defer { fixture.close() }
        let sha = "context-ocr-validation-\(UUID().uuidString)"
        let coordinator = ReaderCoordinator(onPageChanged: { _ in }, onSelectionInfo: { _ in })
        coordinator.pdfView = fixture.view
        coordinator.docSha = sha
        coordinator.setContextReadingMode(true, generation: 11)

        let valid = try makePage(sha: sha, pageIndex: 0, mediaBox: fixture.mediaBox,
                                 blockID: "valid-row", text: "valid",
                                 tokens: [TokenFixture(text: "valid", span: UTF16Span(location: 0, length: 5), kind: .word,
                                                       rect: CGRect(x: 40, y: 180, width: 40, height: 20))])
        XCTAssertFalse(coordinator.installContextOCRPage(valid, generation: 10))
        let wrongDocument = try makePage(
            sha: "another-document", pageIndex: 0, mediaBox: fixture.mediaBox,
            blockID: "wrong-document", text: "valid",
            tokens: [TokenFixture(text: "valid", span: UTF16Span(location: 0, length: 5), kind: .word,
                                  rect: CGRect(x: 40, y: 180, width: 40, height: 20))])
        let wrongPage = try makePage(
            sha: sha, pageIndex: 1, mediaBox: fixture.mediaBox,
            blockID: "wrong-page", text: "valid",
            tokens: [TokenFixture(text: "valid", span: UTF16Span(location: 0, length: 5), kind: .word,
                                  rect: CGRect(x: 40, y: 180, width: 40, height: 20))])
        XCTAssertFalse(coordinator.installContextOCRPage(wrongDocument, generation: 11))
        XCTAssertFalse(coordinator.installContextOCRPage(wrongPage, generation: 11))
        let wrongMedia = try XCTUnwrap(SourceRect(x: fixture.mediaBox.x + 1, y: fixture.mediaBox.y,
                                                 width: fixture.mediaBox.width, height: fixture.mediaBox.height))
        let wrongMediaPage = try makePage(
            sha: sha, pageIndex: 0, mediaBox: wrongMedia,
            blockID: "wrong-media", text: "valid",
            tokens: [TokenFixture(text: "valid", span: UTF16Span(location: 0, length: 5), kind: .word,
                                  rect: CGRect(x: 40, y: 180, width: 40, height: 20))])
        XCTAssertFalse(coordinator.installContextOCRPage(wrongMediaPage, generation: 11))
        let unsupportedRevision = try makePage(sha: sha, pageIndex: 0, mediaBox: fixture.mediaBox,
                                               blockID: "wrong-revision", text: "valid",
                                               tokens: [TokenFixture(text: "valid", span: UTF16Span(location: 0, length: 5), kind: .word,
                                                                     rect: CGRect(x: 40, y: 180, width: 40, height: 20))],
                                               revision: ContextOCRPage.currentRevision + 1)
        XCTAssertFalse(coordinator.installContextOCRPage(unsupportedRevision, generation: 11))
        XCTAssertTrue(coordinator.installContextOCRPage(valid, generation: 11))

        coordinator.setContextReadingMode(false, generation: 12)
        XCTAssertFalse(coordinator.installContextOCRPage(valid, generation: 12),
                       "The master feature switch gates source installation")
    }

    func testSharedOCRWordGeometryCoalescesTokensWithoutInventingCharacterBoxes() throws {
        let media = try XCTUnwrap(SourceRect(x: 0, y: 0, width: 400, height: 300))
        let shared = CGRect(x: 50, y: 180, width: 34, height: 20)
        let page = try makePage(sha: "grouped-geometry", pageIndex: 2, mediaBox: media,
                                blockID: "decimal-row", text: "3.2 +",
                                tokens: [
                                    TokenFixture(text: "3", span: UTF16Span(location: 0, length: 1), kind: .number, rect: shared),
                                    TokenFixture(text: ".", span: UTF16Span(location: 1, length: 1), kind: .punctuation, rect: shared),
                                    TokenFixture(text: "2", span: UTF16Span(location: 2, length: 1), kind: .number, rect: shared),
                                    TokenFixture(text: "+", span: UTF16Span(location: 4, length: 1), kind: .symbol,
                                                 rect: CGRect(x: 100, y: 180, width: 16, height: 20))
                                ])
        let source = try XCTUnwrap(ContextOCRSelectionSource(page: page))
        XCTAssertEqual(source.words.map(\.text), ["3.2", "+"])
        XCTAssertEqual(source.entries.first?.tokens.map(\.sourceSurface), ["3", ".", "2"])
        XCTAssertEqual(source.entries.first?.tokens.map(\.geometryQuality), [.word, .word, .word])
        let selection = try XCTUnwrap(source.contextualSelection(for: 0...0, generation: 4))
        XCTAssertEqual(selection.displaySurface, "3.2")
        XCTAssertEqual(selection.tokens.map(\.sourceSurface), ["3", ".", "2"])
        XCTAssertTrue(selection.tokens.allSatisfy { $0.geometryQuality != .verifiedCharacter })

        let sharedPhraseBox = CGRect(x: 150, y: 120, width: 84, height: 20)
        let phrasePage = try makePage(sha: "grouped-whitespace-geometry", pageIndex: 2, mediaBox: media,
                                      blockID: "shared-phrase-row", text: "charge plus",
                                      tokens: [
                                          TokenFixture(text: "charge", span: UTF16Span(location: 0, length: 6), kind: .word,
                                                       rect: sharedPhraseBox),
                                          TokenFixture(text: "plus", span: UTF16Span(location: 7, length: 4), kind: .word,
                                                       rect: sharedPhraseBox)
                                      ])
        let phraseSource = try XCTUnwrap(ContextOCRSelectionSource(page: phrasePage))
        XCTAssertEqual(phraseSource.words.map(\.text), ["charge plus"],
                       "A shared word-level box with a whitespace gap remains one conservative hit group")
        XCTAssertEqual(phraseSource.entries.first?.tokens.map(\.sourceSurface), ["charge", "plus"])
        XCTAssertEqual(try XCTUnwrap(phraseSource.contextualSelection(for: 0...0, generation: 4)).displaySurface,
                       "charge plus")
    }

    func testSharedWordBoxCoalescesAcrossUnknownUnboxedTokenAndPreservesRawText() throws {
        let media = try XCTUnwrap(SourceRect(x: 0, y: 0, width: 400, height: 300))
        let shared = CGRect(x: 50, y: 180, width: 40, height: 20)
        let page = try makePage(sha: "shared-box-unknown-gap", pageIndex: 0, mediaBox: media,
                                blockID: "unknown-gap-row", text: "x_i",
                                tokens: [
                                    TokenFixture(text: "x", span: UTF16Span(location: 0, length: 1), kind: .word,
                                                 rect: shared),
                                    TokenFixture(text: "_", span: UTF16Span(location: 1, length: 1), kind: .symbol,
                                                 geometryQuality: .unknown),
                                    TokenFixture(text: "i", span: UTF16Span(location: 2, length: 1), kind: .word,
                                                 rect: shared)
                                ])

        let source = try XCTUnwrap(ContextOCRSelectionSource(page: page))
        XCTAssertEqual(source.words.map(\.text), ["x_i"])
        XCTAssertEqual(source.entries.first?.sourceSpan, UTF16Span(location: 0, length: 3))
        XCTAssertEqual(source.entries.first?.tokens.map(\.sourceSurface), ["x", "_", "i"])
        XCTAssertEqual(source.entries.first?.tokens.map(\.geometryQuality), [.word, .unknown, .word])
        XCTAssertEqual(try XCTUnwrap(source.contextualSelection(for: 0...0, generation: 3)).displaySurface,
                       "x_i")
    }

    func testSharedWordBoxClosesAcrossIntermediateDistinctSmallerSeed() throws {
        let media = try XCTUnwrap(SourceRect(x: 0, y: 0, width: 400, height: 300))
        let shared = CGRect(x: 50, y: 180, width: 40, height: 20)
        let smaller = CGRect(x: 67, y: 180, width: 5, height: 20)
        let page = try makePage(sha: "shared-box-small-seed", pageIndex: 0, mediaBox: media,
                                blockID: "small-seed-row", text: "x_i",
                                tokens: [
                                    TokenFixture(text: "x", span: UTF16Span(location: 0, length: 1), kind: .word,
                                                 rect: shared),
                                    TokenFixture(text: "_", span: UTF16Span(location: 1, length: 1), kind: .symbol,
                                                 rect: smaller),
                                    TokenFixture(text: "i", span: UTF16Span(location: 2, length: 1), kind: .word,
                                                 rect: shared)
                                ])

        let source = try XCTUnwrap(ContextOCRSelectionSource(page: page))
        XCTAssertEqual(source.words.map(\.text), ["x_i"])
        XCTAssertEqual(source.entries.first?.tokens.map(\.sourceSurface), ["x", "_", "i"])
        let groupedWord = try XCTUnwrap(source.words.first)
        XCTAssertEqual(groupedWord.x, 0.125, accuracy: 0.000_001)
        XCTAssertEqual(groupedWord.w, 0.1, accuracy: 0.000_001)
    }

    func testRepeatedTextInDifferentColumnsKeepsSeparateHitTargets() throws {
        let media = try XCTUnwrap(SourceRect(x: 0, y: 0, width: 800, height: 300))
        let page = try makePage(sha: "repeated-text-columns", pageIndex: 0, mediaBox: media,
                                blockID: "two-columns", text: "x x",
                                tokens: [
                                    TokenFixture(text: "x", span: UTF16Span(location: 0, length: 1), kind: .word,
                                                 rect: CGRect(x: 80, y: 180, width: 30, height: 20)),
                                    TokenFixture(text: "x", span: UTF16Span(location: 2, length: 1), kind: .word,
                                                 rect: CGRect(x: 620, y: 180, width: 30, height: 20))
                                ])

        let source = try XCTUnwrap(ContextOCRSelectionSource(page: page))
        XCTAssertEqual(source.words.map(\.text), ["x", "x"])
        XCTAssertEqual(source.entries.map(\.sourceSpan), [
            UTF16Span(location: 0, length: 1),
            UTF16Span(location: 2, length: 1)
        ])
    }

    func testLegacyFallbackKeepsPayloadNilWithMasterOffAndOn() throws {
        let fixture = try makeBlankPDFView()
        defer { fixture.close() }
        let db = try XCTUnwrap(AppDatabase.shared)
        let sha = "context-ocr-legacy-\(UUID().uuidString)"
        let store = OCRStore(db: db)
        let word = OCRWord(text: "legacy", x: 0.1, y: 0.2, w: 0.2, h: 0.08, line: 0)
        store.save(docSha: sha, page: 0, words: [word])
        defer {
            try? db.dbQueue.write { database in
                try database.execute(sql: "DELETE FROM ocr_word WHERE docSha = ?", arguments: [sha])
            }
        }

        var events: [SelectionInfo?] = []
        let coordinator = ReaderCoordinator(onPageChanged: { _ in }, onSelectionInfo: { events.append($0) })
        coordinator.pdfView = fixture.view
        coordinator.docSha = sha
        coordinator.ocrStore = store
        XCTAssertFalse(coordinator.contextReadingEnabled)

        let rect = OCRService.pageRect(from: word, pageBounds: fixture.page.bounds(for: .mediaBox))
        let point = fixture.view.convert(CGPoint(x: rect.midX, y: rect.midY), from: fixture.page)
        coordinator.perform(NSSelectorFromString("handleDoubleTap:"), with: ContextOCRTap(point: point))
        let info = try XCTUnwrap(events.compactMap { $0 }.last)
        XCTAssertEqual(info.text, "legacy")
        XCTAssertNil(info.contextual, "The off path retains its legacy OCR card payload")

        coordinator.dismissSelection()
        coordinator.setContextReadingMode(true, generation: 1)
        coordinator.perform(NSSelectorFromString("handleDoubleTap:"), with: ContextOCRTap(point: point))
        let fallbackInfo = try XCTUnwrap(events.compactMap { $0 }.last)
        XCTAssertEqual(fallbackInfo.text, "legacy")
        XCTAssertNil(fallbackInfo.contextual,
                     "Context mode without a complete page source falls back to legacy OCR without a false payload")
    }

    private func makePage(sha: String,
                          pageIndex: Int,
                          mediaBox: SourceRect,
                          blockID: String,
                          text: String,
                          tokens fixtures: [TokenFixture],
                          revision: Int = ContextOCRPage.currentRevision) throws -> ContextOCRPage {
        let tokens = fixtures.map { fixture in
            SourceToken(documentSHA256: sha,
                       pageIndex: pageIndex,
                       span: fixture.span,
                       sourceSurface: fixture.text,
                       kind: fixture.kind,
                       blockID: blockID,
                       geometryQuality: fixture.geometryQuality)
        }
        let geometry = zip(tokens, fixtures).compactMap { pair -> SourceTokenGeometry? in
            guard let rect = pair.1.rect,
                  let sourceRect = SourceRect(rect: rect) else { return nil }
            return SourceTokenGeometry(tokenID: pair.0.id,
                                       span: pair.0.span,
                                       rect: sourceRect,
                                       quality: pair.1.geometryQuality)
        }
        let combinedRect = fixtures.compactMap(\.rect).reduce(CGRect.null) { $0.union($1) }
        let lineRect = try XCTUnwrap(SourceRect(rect: combinedRect))
        let line = OCRLine(blockID: blockID,
                           candidates: [OCRCandidate(text: text, confidence: 0.95)],
                           regionRect: mediaBox,
                           pageRect: lineRect,
                           tokens: tokens,
                           tokenGeometry: geometry)
        return ContextOCRPage(documentSHA256: sha,
                              pageIndex: pageIndex,
                              revision: revision,
                              mediaBox: mediaBox,
                              lines: [line])
    }

    private func makeBlankPDFView() throws -> PDFViewFixture {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { $0.beginPage() }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let actualMediaBox = try XCTUnwrap(SourceRect(rect: page.bounds(for: .mediaBox)))

        let view = VocabPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = view
        window.frame = view.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        view.displayMode = .singlePage
        view.document = document
        view.scaleFactor = 1.5
        view.layoutDocumentView()
        view.go(to: page)

        return PDFViewFixture(document: document, page: page, view: view, window: window,
                              controller: controller, previousKeyWindow: previous, mediaBox: actualMediaBox)
    }
}

private struct TokenFixture {
    let text: String
    let span: UTF16Span
    let kind: SourceTokenKind
    let rect: CGRect?
    let geometryQuality: SourceGeometryQuality

    init(text: String,
         span: UTF16Span,
         kind: SourceTokenKind,
         rect: CGRect? = nil,
         geometryQuality: SourceGeometryQuality = .word) {
        self.text = text
        self.span = span
        self.kind = kind
        self.rect = rect
        self.geometryQuality = geometryQuality
    }
}

@MainActor
private struct PDFViewFixture {
    let document: PDFDocument
    let page: PDFPage
    let view: VocabPDFView
    let window: UIWindow
    let controller: UIViewController
    let previousKeyWindow: UIWindow?
    let mediaBox: SourceRect

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
        _ = document
        _ = controller
    }
}

@MainActor
private final class ContextOCRTap: UITapGestureRecognizer {
    private let point: CGPoint
    init(point: CGPoint) { self.point = point; super.init(target: nil, action: nil) }
    override var state: UIGestureRecognizer.State { get { .ended } set {} }
    override func location(in view: UIView?) -> CGPoint { point }
}

@MainActor
private final class ContextOCRPress: UILongPressGestureRecognizer {
    var point: CGPoint
    var testState: UIGestureRecognizer.State = .began
    init(point: CGPoint) { self.point = point; super.init(target: nil, action: nil) }
    override var state: UIGestureRecognizer.State { get { testState } set { testState = newValue } }
    override func location(in view: UIView?) -> CGPoint { point }
}

@MainActor
private final class ContextOCRHandlePan: UIPanGestureRecognizer {
    var point: CGPoint
    var testState: UIGestureRecognizer.State = .began
    init(point: CGPoint) { self.point = point; super.init(target: nil, action: nil) }
    override var state: UIGestureRecognizer.State { get { testState } set { testState = newValue } }
    override func location(in view: UIView?) -> CGPoint { point }
}

@MainActor
private final class ContextOCRHover: UIHoverGestureRecognizer {
    private let point: CGPoint
    init(point: CGPoint) { self.point = point; super.init(target: nil, action: nil) }
    override var state: UIGestureRecognizer.State { get { .began } set {} }
    override func location(in view: UIView?) -> CGPoint { point }
}
