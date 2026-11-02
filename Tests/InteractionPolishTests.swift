import XCTest
import UIKit
import PDFKit
import MetalKit
import SwiftUI
@testable import PdfVocab

@MainActor
final class InteractionPolishTests:XCTestCase {
    func testLinkedTextLongPressSelectsAndSingleTapNavigates() throws {
        let url = try XCTUnwrap(Bundle(for:GlyphSelectionTests.self).url(forResource:"OpenStax-selection",withExtension:"pdf"))
        let document = try XCTUnwrap(PDFDocument(url:url))
        let page = try XCTUnwrap(document.page(at:0)), target = try XCTUnwrap(document.page(at:1))
        let view = VocabPDFView(frame:CGRect(x:0,y:0,width:900,height:1100))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene:scene), controller = UIViewController()
        window.frame = view.bounds; controller.view = view; window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        view.displayMode = .singlePage
        view.document = document
        view.scaleFactor = 1.5
        view.layoutDocumentView()
        for annotation in page.annotations where annotation.type == "Link" { page.removeAnnotation(annotation) }
        let link = PDFAnnotation(bounds:CGRect(x:160,y:370,width:50,height:18),forType:.link,withProperties:nil)
        let action = PDFActionGoTo(destination:PDFDestination(page:target,at:CGPoint(x:0,y:700)))
        link.action = action
        page.addAnnotation(link)
        view.go(to:page)
        var texts: [String] = []
        let coordinator = ReaderCoordinator(onPageChanged:{ _ in },onSelectionInfo:{ if let info = $0 { texts.append(info.text) } })
        coordinator.pdfView = view
        coordinator.hapticsEnabled = false
        let point = view.convert(CGPoint(x:183.4946,y:377.4785),from:page)
        let press = BeganWordPress(point:point)
        coordinator.perform(NSSelectorFromString("handlePress:"),with:press)
        XCTAssertEqual(texts.last,"Functions")
        XCTAssertTrue(view.currentPage === page,"selecting linked text must preserve page")
        press.testState = .ended
        coordinator.perform(NSSelectorFromString("handlePress:"),with:press)
        coordinator.clearTempHighlight()
        // Use a destination-only annotation too: not every PDF link has an action.
        page.removeAnnotation(link)
        let direct = PDFAnnotation(bounds:link.bounds,forType:.link,withProperties:nil)
        direct.destination = PDFDestination(page:target,at:CGPoint(x:0,y:700))
        page.addAnnotation(direct)
        coordinator.perform(NSSelectorFromString("handleTap:"),with:CompletedWordTap(point:point))
        XCTAssertTrue(view.currentPage === target,"single tap must preserve normal link navigation")
    }

    func testSingleTapCanMoveToAdjacentWordAndSelectPunctuation() throws {
        let bytes = UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:400,height:300)).pdfData { ctx in
            ctx.beginPage()
            ("word next +" as NSString).draw(at:CGPoint(x:30,y:60),withAttributes:[.font:UIFont.systemFont(ofSize:24)])
        }
        let document = try XCTUnwrap(PDFDocument(data:bytes)), page = try XCTUnwrap(document.page(at:0))
        let view = VocabPDFView(frame:CGRect(x:0,y:0,width:900,height:1100))
        view.document = document
        view.scaleFactor = 4.26
        view.layoutDocumentView()
        var picked: [String] = []
        let coordinator = ReaderCoordinator(onPageChanged:{ _ in },onSelectionInfo:{ if let info = $0 { picked.append(info.text) } })
        coordinator.pdfView = view
        coordinator.hapticsEnabled = false
        for range in [NSRange(location:0,length:4),NSRange(location:5,length:4),NSRange(location:10,length:1)] {
            let selection = try XCTUnwrap(page.selection(for:range)), rect = selection.bounds(for:page)
            let point = view.convert(CGPoint(x:rect.minX+1,y:rect.midY),from:page)
            coordinator.perform(NSSelectorFromString("handleTap:"),with:CompletedWordTap(point:point))
        }
        XCTAssertEqual(picked,["word","next","+"])
        coordinator.clearTempHighlight()
    }

    func testWordGeometryAcrossFontsAndSizes() throws {
        let words = ["Alpha", "beta", "gamma", "don't", "well-known", "2026"]
        for name in ["Helvetica", "Helvetica-Bold", "TimesNewRomanPSMT", "Courier"] {
            for size in [CGFloat(12),CGFloat(24)] {
                let font = try XCTUnwrap(UIFont(name:name,size:size))
                let data = UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:700,height:200)).pdfData { ctx in
                    ctx.beginPage()
                    (words.joined(separator:" ") as NSString).draw(at:CGPoint(x:30,y:40),withAttributes:[.font:font])
                }
                let document = try XCTUnwrap(PDFDocument(data:data)), page = try XCTUnwrap(document.page(at:0))
                let text = try XCTUnwrap(page.string) as NSString
                for word in words {
                    let range = text.range(of:word)
                    XCTAssertNotEqual(range.location,NSNotFound)
                    guard range.location != NSNotFound else { continue }
                    for i in range.location..<NSMaxRange(range) {
                        let rect = try XCTUnwrap(page.selection(for:NSRange(location:i,length:1))).bounds(for:page)
                        let selection = SelectionGeometry.initialWord(on:page,at:CGPoint(x:rect.midX,y:rect.midY),tolerance:0)
                        XCTAssertEqual(selection.map { SelectionGeometry.lookupText(for:$0) },word,"\(name) \(size) glyph=\(i)")
                    }
                }
            }
        }
    }

    func testLinkBlueOutlinesDoNotModifyPDF() async throws {
        let bytes = UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:400,height:300)).pdfData { ctx in
            ctx.beginPage()
            ("Linked text" as NSString).draw(at:CGPoint(x:30,y:60),withAttributes:[.font:UIFont.systemFont(ofSize:24)])
        }
        let document = try XCTUnwrap(PDFDocument(data:bytes)), page = try XCTUnwrap(document.page(at:0))
        let textRect = try XCTUnwrap(page.selection(for:NSRange(location:0,length:11))).bounds(for:page)
        let link = PDFAnnotation(bounds:textRect,forType:.link,withProperties:nil)
        link.action = PDFActionURL(url:try XCTUnwrap(URL(string:"https://example.com")))
        page.addAnnotation(link)
        let before = page.annotations.count
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene:scene)
        window.frame = CGRect(x:0,y:0,width:900,height:700)
        let controller = UIViewController(), view = VocabPDFView(frame:window.bounds)
        controller.view = view; window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        view.document = document; view.autoScales = true
        view.layoutDocumentView()
        try await Task.sleep(for:.milliseconds(200))
        view.refreshLinkOutlines()
        let outline = try XCTUnwrap(view.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.last)
        XCTAssertFalse(try XCTUnwrap(outline.path).isEmpty)
        XCTAssertEqual(outline.lineWidth,1)
        XCTAssertEqual(page.annotations.count,before)
        let image = UIGraphicsImageRenderer(size:view.bounds.size).image { _ in
            view.drawHierarchy(in:view.bounds,afterScreenUpdates:true)
        }
        let attachment = XCTAttachment(image:image)
        attachment.name = "linked-text-blue-outline"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testNativeControlTapAndScrollAndPinchRemainAvailable() {
        let view = VocabPDFView(frame:CGRect(x:0,y:0,width:900,height:1100))
        let content = UIView(frame:view.bounds)
        view.addSubview(content)
        let nativeLink = UITapGestureRecognizer()
        let pan = UIPanGestureRecognizer(), pinch = UIPinchGestureRecognizer()
        content.addGestureRecognizer(nativeLink)
        content.addGestureRecognizer(pan)
        content.addGestureRecognizer(pinch)
        let coordinator = ReaderCoordinator(onPageChanged:{ _ in },onSelectionInfo:{ _ in })
        coordinator.suppressNativeSelection(in:view)
        XCTAssertTrue(nativeLink.isEnabled)
        XCTAssertTrue(pan.isEnabled)
        XCTAssertTrue(pinch.isEnabled)
    }

    func testWordPickingStartsWithOneWordAndRejectsWhitespace() throws {
        XCTAssertTrue(SelectionGeometry.isSingleWordText("don't"))
        XCTAssertTrue(SelectionGeometry.isSingleWordText("well-known"))
        XCTAssertFalse(SelectionGeometry.isSingleWordText("word word"))
        XCTAssertFalse(SelectionGeometry.isSingleWordText("whole line selected"))
        let data=UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:400,height:300)).pdfData { ctx in
            ctx.beginPage()
            ("Hello world again" as NSString).draw(at:CGPoint(x:30,y:60),withAttributes:[.font:UIFont.systemFont(ofSize:24)])
        }
        let page=try XCTUnwrap(PDFDocument(data:data)?.page(at:0))
        let hello=try XCTUnwrap(page.selection(for:NSRange(location:0,length:5)))
        let bounds=hello.bounds(for:page)
        let picked=try XCTUnwrap(SelectionGeometry.initialWord(on:page,at:CGPoint(x:bounds.midX,y:bounds.midY)))
        XCTAssertEqual(picked.string?.trimmingCharacters(in:.whitespacesAndNewlines),"Hello")
        XCTAssertNil(SelectionGeometry.initialWord(on:page,at:CGPoint(x:350,y:250)))
    }
    func testRepeatedWordsHaveDistinctSelectionIdentity() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 300)).pdfData { ctx in
            ctx.beginPage()
            ("word word" as NSString).draw(at: CGPoint(x: 30, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let first = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 4)))
        let second = try XCTUnwrap(page.selection(for: NSRange(location: 5, length: 4)))
        XCTAssertEqual(first.string, second.string)
        XCTAssertNotEqual(SelectionGeometry.identity(for: first), SelectionGeometry.identity(for: second))
        let repeated = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 4)))
        XCTAssertEqual(SelectionGeometry.identity(for: first), SelectionGeometry.identity(for: repeated))
    }

    func testWordHitRecoversGapAndPrefersExactGlyphWithoutJumpingLines() {
        let text = "a b c" as NSString
        let boxes = [CGRect(x: 0, y: 0, width: 8, height: 20), .zero,
                     CGRect(x: 12, y: 0, width: 8, height: 20), .zero,
                     CGRect(x: 0, y: 40, width: 8, height: 20)]
        func hit(_ p: CGPoint, near: Int = 1) -> Int? {
            SelectionGeometry.wordCharacter(text: text, near: near, at: p, tolerance: 6, bounds: { boxes[$0] })
        }
        XCTAssertEqual(hit(CGPoint(x: 11, y: 10)), 2)
        XCTAssertEqual(hit(CGPoint(x: 13, y: 10), near: 0), 2)
        XCTAssertNil(hit(CGPoint(x: 30, y: 10)))
        XCTAssertNil(hit(CGPoint(x: 4, y: 30)))
        XCTAssertEqual(hit(CGPoint(x: 4, y: 45)), 4)
    }

    func testOCRExactBoxBeatsPaddedShortNeighbour() {
        let words = [OCRWord(text: "a", x: 0.1, y: 0.2, w: 0.01, h: 0.02, line: 0),
                     OCRWord(text: "extraordinary", x: 0.112, y: 0.2, w: 0.2, h: 0.02, line: 0)]
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        XCTAssertEqual(OCRService.wordIndex(at: CGPoint(x: 113, y: 790), in: words, pageBounds: bounds), 1)
        XCTAssertEqual(OCRService.wordIndex(at: CGPoint(x: 105, y: 790), in: words, pageBounds: bounds), 0)
        XCTAssertNil(OCRService.wordIndex(at: CGPoint(x: 500, y: 790), in: words, pageBounds: bounds))
    }

    func testDoubleTapMovesBetweenRepeatedWordsAfterRotationAndZoom() throws {
        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 500)).pdfData { ctx in
            ctx.beginPage()
            ("word word" as NSString).draw(at: CGPoint(x: 70, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }
        let document = try XCTUnwrap(PDFDocument(data: bytes)), page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(CGRect(x: 20, y: 30, width: 360, height: 440), for: .cropBox)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let view = PDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 1100))
            view.displayMode = .singlePageContinuous
            view.document = document
            view.scaleFactor = 1.5
            view.layoutDocumentView()
            var selected: [String] = []
            let coordinator = ReaderCoordinator(onPageChanged: { _ in }, onSelectionInfo: { info in
                if let info { selected.append(info.text) }
            })
            coordinator.pdfView = view
            coordinator.hapticsEnabled = false
            for start in [0, 5] {
                let word = try XCTUnwrap(page.selection(for: NSRange(location: start, length: 4)))
                let box = word.bounds(for: page)
                let tap = CompletedWordTap(point: view.convert(CGPoint(x: box.midX, y: box.midY), from: page))
                coordinator.perform(NSSelectorFromString("handleDoubleTap:"), with: tap)
                XCTAssertEqual(selected.count, start == 0 ? 1 : 2, "rotation=\(rotation), start=\(start)")
                XCTAssertEqual(page.annotations.count, 1, "rotation=\(rotation), start=\(start)")
                let highlight = try XCTUnwrap(page.annotations.first, "rotation=\(rotation), start=\(start)")
                XCTAssertEqual(highlight.bounds.midX, box.midX, accuracy: 1)
                XCTAssertEqual(highlight.bounds.midY, box.midY, accuracy: 1)
            }
            XCTAssertEqual(selected, ["word", "word"])
            coordinator.clearTempHighlight()
        }
    }

    func testSelectionCannotJumpFromEditionToHorizon() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 650, height: 300)).pdfData { ctx in
            ctx.beginPage()
            ("New Horizon College English Fourth Edition" as NSString).draw(at: CGPoint(x: 20, y: 80),
                withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
        }
        let document = try XCTUnwrap(PDFDocument(data: data)), page = try XCTUnwrap(document.page(at: 0))
        let text = try XCTUnwrap(page.string) as NSString
        let horizon = try XCTUnwrap(page.selection(for: text.range(of: "Horizon")))
        let edition = try XCTUnwrap(page.selection(for: text.range(of: "Edition")))
        let rect = edition.bounds(for: page), point = CGPoint(x: rect.midX, y: rect.midY)
        XCTAssertFalse(SelectionGeometry.containsTouch(horizon, on: page, point: point, tolerance: 2))
        XCTAssertTrue(SelectionGeometry.containsTouch(edition, on: page, point: point, tolerance: 2))
        let picked = try XCTUnwrap(SelectionGeometry.initialWord(on: page, at: point))
        XCTAssertEqual(picked.string, "Edition")
        // Simulate a corrupt PDFKit index, farther than the old +/-8 search.
        let index = SelectionGeometry.wordCharacter(text: text, near: 0, at: point, tolerance: 2,
                                                     bounds: { page.characterBounds(at: $0) })
        XCTAssertTrue(NSLocationInRange(try XCTUnwrap(index), text.range(of: "Edition")))
    }

    func testLaserRevivesAllVisibleStrokesButNotExpiredStrokes() {
        let laser = InkLaserOverlay(frame: .zero)
        var time: CFTimeInterval = 100
        laser.now = { time }
        laser.begin(at: .zero); laser.append(CGPoint(x: 10, y: 10)); laser.finish()
        time += 0.4
        laser.begin(at: CGPoint(x: 20, y: 20))
        XCTAssertEqual(laser.strokeCount, 2); XCTAssertEqual(laser.pointCount, 3)
        laser.finish(); time += 0.4
        laser.begin(at: CGPoint(x: 30, y: 30))
        XCTAssertEqual(laser.strokeCount, 3)
        laser.finish(); time += 0.65
        laser.begin(at: CGPoint(x: 40, y: 40))
        XCTAssertEqual(laser.strokeCount, 1); XCTAssertEqual(laser.pointCount, 1)
        laser.clear(); XCTAssertEqual(laser.strokeCount, 0)
    }

    func testWorkspaceFolderCRUDPreservesImportedDocumentAndReadingState() throws {
        let db = try XCTUnwrap(AppDatabase.shared), docs = DocumentStore(db: db), workspace = WorkspaceStore(db: db)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 500)).pdfData { ctx in
            for _ in 0..<3 {
                ctx.beginPage()
                (("Workspace test " + UUID().uuidString) as NSString).draw(at: CGPoint(x: 30, y: 60),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
        }
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try docs.importFile(from: url)
        defer { try? docs.delete(doc) }
        XCTAssertEqual(doc.pageCount, 3); XCTAssertTrue(doc.hasTextLayer)
        let file = try docs.pdfURL(for: doc)
        XCTAssertEqual(PDFKitView.openDocument(at: file)?.pageCount, 3)
        let folder = try workspace.save(name: "  Physics  ", icon: "atom")
        defer { try? workspace.delete(folder: folder) }
        XCTAssertEqual(folder.name, "Physics")
        try workspace.move(docSha: doc.sha256, to: folder.id)
        XCTAssertEqual(try workspace.membership()[doc.sha256], folder.id)
        let renamed = try workspace.save(id: folder.id, name: "English", icon: "books.vertical")
        XCTAssertEqual(renamed.id, folder.id); XCTAssertEqual(renamed.icon, "books.vertical")
        try docs.saveReadingState(ReadingState(page: 2, pageX: 0.1, pageY: 0.2, zoom: 2, zoomAuto: false), for: doc.sha256)
        try workspace.delete(folder: renamed)
        XCTAssertNil(try workspace.membership()[doc.sha256])
        XCTAssertEqual(try docs.document(sha256: doc.sha256)?.lastPage, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.removeItem(at: file)
        let repaired = try docs.importFile(from: url)
        XCTAssertEqual(repaired.sha256, doc.sha256); XCTAssertEqual(repaired.lastPage, 2)
        XCTAssertEqual(PDFKitView.openDocument(at: file)?.pageCount, 3)
        XCTAssertThrowsError(try workspace.save(name: " ", icon: "folder"))
        XCTAssertNil(PDFKitView.openDocument(at: url.appendingPathExtension("missing")))
    }

    /// Review actual SwiftUI renders alongside the geometric regression tests.
    func testPageLayoutReviewSnapshots() async throws {
        let db = try XCTUnwrap(AppDatabase.shared), store = VocabStore(db: db)
        var ids: [Int64] = []
        for surface in ["serendipity", "luminous", "resilience", "wanderlust"] {
            let lemma = "ui-review-" + UUID().uuidString.lowercased()
            ids.append(try XCTUnwrap(store.collectHeadword(lemma: lemma, surface: surface)))
        }
        defer { for id in ids { store.deleteWord(id: id) } }
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true).appendingPathComponent("UIReview")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Real imported sample exercises the reading chrome and populated home.
        let docs = DocumentStore(db: db)
        let sampleURL = FileManager.default.temporaryDirectory.appendingPathComponent("Reading workspace " + UUID().uuidString + ".pdf")
        let sample = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 820)).pdfData { ctx in
            ctx.beginPage()
            ("The architecture of language" as NSString).draw(at: CGPoint(x: 50, y: 100), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 26)])
            ("Every word connects to another idea. Read, annotate, and explore." as NSString).draw(in: CGRect(x: 50, y: 170, width: 480, height: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
        try sample.write(to: sampleURL)
        let record = try docs.importFile(from: sampleURL)
        defer { try? docs.delete(record); try? FileManager.default.removeItem(at: sampleURL) }
        let workspace = WorkspaceStore(db: db)
        let reviewFolder = try workspace.save(name: "Language & ideas", icon: "books.vertical")
        let physicsFolder = try workspace.save(name: "物理与世界", icon: "atom")
        defer { try? workspace.delete(folder: reviewFolder); try? workspace.delete(folder: physicsFolder) }
        try workspace.move(docSha: record.sha256, to: reviewFolder.id)
        let savedCompact = UserDefaults.standard.object(forKey: "vocabCompactLayout")
        defer {
            if let savedCompact { UserDefaults.standard.set(savedCompact, forKey: "vocabCompactLayout") }
            else { UserDefaults.standard.removeObject(forKey: "vocabCompactLayout") }
        }
        let markerReview = PencilToolSession()
        markerReview.kind = .marker
        markerReview.setWidth(4)
        let brushReview = PencilToolSession()
        brushReview.kind = .brush
        brushReview.setWidth(4)
        let cases: [(String, CGSize, AnyView)] = [
            ("palette-marker-expanded", CGSize(width: 360, height: 420), AnyView(PencilPaletteView(session: markerReview, onUndo: {}, onRedo: {}).stylePanel.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white))),
            ("palette-brush-expanded", CGSize(width: 320, height: 420), AnyView(PencilPaletteView(session: brushReview, onUndo: {}, onRedo: {}).stylePanel.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white))),
            ("library-ipad", CGSize(width: 834, height: 1194), AnyView(LibraryView(store: DocumentStore(db: db)))),
            ("workspace-folder-editor", CGSize(width: 480, height: 900), AnyView(WorkspaceFolderEditor(folder: reviewFolder, onSave: { _, _ in }))),
            ("vocab-ipad", CGSize(width: 834, height: 1194), AnyView(VocabListView(store: store))),
            ("vocab-split", CGSize(width: 480, height: 900), AnyView(VocabListView(store: store))),
            ("vocab-dark", CGSize(width: 834, height: 1194), AnyView(VocabListView(store: store).preferredColorScheme(.dark))),
            ("library-split", CGSize(width: 480, height: 900), AnyView(LibraryView(store: docs))),
            ("vocab-large-type", CGSize(width: 480, height: 1100), AnyView(VocabListView(store: store).dynamicTypeSize(.xxxLarge))),
            ("vocab-compact", CGSize(width: 834, height: 1194), AnyView(VocabListView(store: store))),
            ("graph-ipad", CGSize(width: 834, height: 1194), AnyView(VocabGraphView(store: store, words: store.listWords()))),
            ("graph-dark-split", CGSize(width: 480, height: 900), AnyView(VocabGraphView(store: store, words: store.listWords()).preferredColorScheme(.dark))),
            ("reader-ipad", CGSize(width: 834, height: 1194), AnyView(ReaderView(doc: record, store: docs))),
            ("reader-split", CGSize(width: 480, height: 900), AnyView(ReaderView(doc: record, store: docs))),
            ("palette-ipad", CGSize(width: 834, height: 240), AnyView(PencilPaletteView(session: PencilToolSession(), onUndo: {}, onRedo: {}).padding().background(DS.background1))),
            ("palette-split", CGSize(width: 480, height: 240), AnyView(PencilPaletteView(session: PencilToolSession(), onUndo: {}, onRedo: {}).padding().background(DS.background1)))
        ]
        for (name, size, content) in cases {
            UserDefaults.standard.set(name == "vocab-compact", forKey: "vocabCompactLayout")
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            let host = UIHostingController(rootView: content)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil
                previousKeyWindow?.makeKey()
            }
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(name.hasPrefix("graph-") ? 2500 : 500))
            var drawn = false
            let format = UIGraphicsImageRendererFormat()
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                drawn = host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
            }
            XCTAssertTrue(drawn, "\(name): hierarchy was not rendered")
            let cg = try XCTUnwrap(image.cgImage)
            let pixels = try XCTUnwrap(cg.dataProvider?.data) as Data
            let strideBytes = cg.bitsPerPixel / 8
            let samples = stride(from: 0, to: pixels.count, by: strideBytes).map { pixels[$0] }
            let spread = Int(samples.max() ?? 0) - Int(samples.min() ?? 0)
            XCTAssertGreaterThan(spread, 20, "\(name): screenshot is blank")
            if name == "palette-marker-expanded" || name == "palette-brush-expanded" {
                XCTAssertEqual(cg.bitsPerComponent,8,"Overflow checker requires standard 8-bit pixels")
                let scale = CGFloat(cg.width)/size.width
                let left = Int(((size.width-280)/2-1)*scale)
                let right = Int(((size.width+280)/2+1)*scale)
                var outsideColor = 0
                for y in stride(from: 0,to: cg.height,by: 2) {
                    for x in stride(from: 0,to: cg.width,by: 2) where x < left || x > right {
                        let offset = y*cg.bytesPerRow+x*strideBytes
                        let rgb = [pixels[offset],pixels[offset+1],pixels[offset+2]]
                        if Int(rgb.max()!)-Int(rgb.min()!) > 60 { outsideColor += 1 }
                    }
                }
                XCTAssertEqual(outsideColor,0,"\(name): colored content escaped the 280pt panel")
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(name + ".png"))
            XCTAssertEqual(image.size, size)
        }
    }

    func testOCRTilesCoverMediaBoxWithOverlap() {
        let bounds = CGRect(x: 31, y: -27, width: 1200, height: 1600)
        let tiles = OCRService.regions(for: bounds)
        XCTAssertEqual(tiles.count, 4)
        XCTAssertGreaterThan(tiles[0].intersection(tiles[1]).width, 0)
        for x in stride(from: bounds.minX, through: bounds.maxX - 1, by: 35) {
            for y in stride(from: bounds.minY, through: bounds.maxY - 1, by: 35) {
                XCTAssertTrue(tiles.contains { $0.contains(CGPoint(x: x, y: y)) })
            }
        }
    }

    func testOCRPageLevelDetectionAndSmallText() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 1200, height: 1600)).pdfData { context in
            context.beginPage()
            ("Small typography alignment" as NSString).draw(at: CGPoint(x: 300, y: 400), withAttributes: [.font: UIFont.systemFont(ofSize: 9)])
            context.beginPage()
        }
        let doc = try XCTUnwrap(PDFDocument(data: data))
        let text = try XCTUnwrap(doc.page(at: 0)), blank = try XCTUnwrap(doc.page(at: 1))
        XCTAssertFalse(OCRService.needsOCR(page: text))
        XCTAssertTrue(OCRService.needsOCR(page: blank))
        let words = OCRService.recognize(page: text)
        XCTAssertTrue(words.contains { $0.text.lowercased() == "typography" })
        XCTAssertTrue(words.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x+$0.w <= 1.001 && $0.y+$0.h <= 1.001 })
    }

    func testRulerTracksDocumentInsteadOfViewport() {
        let host=UIView(frame:CGRect(x:0,y:0,width:500,height:500))
        let document=UIView(frame:CGRect(x:0,y:0,width:500,height:1500));host.addSubview(document)
        let ruler=SmartRulerView(length:700,host:host);host.addSubview(ruler)
        ruler.bindDocument(document);ruler.setPose(position:CGPoint(x:150,y:250),angle:.pi/4)
        XCTAssertEqual(ruler.angleLabel,"45°")
        let anchor=document.convert(ruler.rulerPosition,from:ruler)
        document.frame.origin.y = -100;ruler.syncDocumentPose()
        XCTAssertEqual(ruler.rulerPosition.y,150,accuracy:0.001)
        XCTAssertEqual(document.convert(ruler.rulerPosition,from:ruler).y,anchor.y,accuracy:0.001)
        document.transform=CGAffineTransform(scaleX:2,y:2);ruler.syncDocumentPose()
        XCTAssertEqual(ruler.poseScale,2,accuracy:0.001)
        XCTAssertEqual(document.convert(ruler.rulerPosition,from:ruler).x,anchor.x,accuracy:0.001)
        ruler.resetInHost();XCTAssertEqual(ruler.rulerPosition,CGPoint(x:250,y:250))
    }
    func testGraphSpringsPinnedNodeDampingAndFiniteBounds() {
        var points:[Int64:CGPoint]=[1:.zero,2:CGPoint(x:400,y:0)]
        var velocities:[Int64:CGVector]=[:]
        let edge=VocabGraphEdge(id:"test",a:1,b:2,morphology:false,evidence:"")
        VocabGraphPhysics.step(positions:&points,velocities:&velocities,edges:[edge],pinned:[1])
        XCTAssertEqual(points[1],.zero);XCTAssertLessThan(points[2]!.x,400)
        for _ in 0..<300 { VocabGraphPhysics.step(positions:&points,velocities:&velocities,edges:[edge],pinned:[1]) }
        XCTAssertTrue(points.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertLessThan(abs(velocities[2]!.dx),2)
        var isolated:[Int64:CGPoint]=[1:.zero],motion:[Int64:CGVector]=[1:CGVector(dx:100,dy:0)]
        VocabGraphPhysics.step(positions:&isolated,velocities:&motion,edges:[],pinned:[])
        XCTAssertLessThan(motion[1]!.dx,100);XCTAssertGreaterThan(isolated[1]!.x,0)
    }
    func testRoundInkHasCoverageOutsideGeometricBoundary() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let canvas=InkMetalCanvasView();canvas.frame=CGRect(x:0,y:0,width:64,height:64);canvas.drawableSize=CGSize(width:256,height:256)
        let dot=InkPoint(x:32.2,y:32.2,width:20)
        canvas.renderItems=[InkRenderItem(stroke:InkStroke(kind:.pen,r:0,g:0,b:0,a:1,points:[dot,dot]),clip:canvas.bounds)]
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:256,height:256,mipmapped:false)
        descriptor.storageMode = .shared;descriptor.usage=[.renderTarget,.shaderRead]
        let target=try XCTUnwrap(device.makeTexture(descriptor:descriptor)),queue=try XCTUnwrap(device.makeCommandQueue()),command=try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(canvas.encodeFrame(to:target,commandBuffer:command));command.commit();command.waitUntilCompleted()
        var bytes=[UInt8](repeating:0,count:256*256*4)
        bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow:256*4,from:MTLRegionMake2D(0,0,256,256),mipmapLevel:0) }
        func alpha(_ x:Int,_ y:Int)->UInt8 {
            let row:Int=y*256
            let offset:Int=(row+x)*4+3
            return bytes[offset]
        }
        let edge:UInt8=alpha(88,128)
        XCTAssertGreaterThan(edge,0);XCTAssertLessThan(edge,255)
        XCTAssertEqual(alpha(128,128),255)
        XCTAssertEqual(alpha(80,128),0)
    }
    func testVisualWordRepairsSplitGlyphsButPreservesRealWordSpace() {
        let text="h e l l o world" as NSString
        let xs:[CGFloat]=[0,8,8,16,16,24,24,32,32,40,48,56,64,72,80]
        func box(_ i:Int)->CGRect { CGRect(x:xs[i],y:0,width:8,height:20) }
        XCTAssertEqual(SelectionGeometry.visualWordRange(text:text,at:4,bounds:box),NSRange(location:0,length:9))
        XCTAssertEqual(SelectionGeometry.visualWordRange(text:text,at:12,bounds:box),NSRange(location:10,length:5))
        XCTAssertNil(SelectionGeometry.visualWordRange(text:text,at:9,bounds:box))
        XCTAssertFalse(SelectionGeometry.joinsWord(CGRect(x:0,y:0,width:8,height:20),CGRect(x:8,y:30,width:8,height:20),acrossSpace:true))
    }

    func testFullGraphLabelsCannotOverlapEvenWhenLoadedAtOnePoint() {
        let ids=(1...60).map { Int64($0) }
        var points=Dictionary(uniqueKeysWithValues:ids.map { ($0,CGPoint.zero) })
        let sizes=Dictionary(uniqueKeysWithValues:ids.map { ($0,CGSize(width:CGFloat(60+Int($0%5)*30),height:34)) })
        var velocities:[Int64:CGVector]=[:]
        VocabGraphPhysics.resolveCollisions(positions:&points,velocities:&velocities,pinned:[30],sizes:sizes)
        XCTAssertEqual(points[30],.zero)
        func check() {
            for i in ids { for j in ids where j>i {
                let a=points[i]!,b=points[j]!,sa=sizes[i]!,sb=sizes[j]!
                XCTAssertTrue(abs(a.x-b.x)>=(sa.width+sb.width)/2+7.9 || abs(a.y-b.y)>=(sa.height+sb.height)/2+7.9)
            } }
        }
        check()
        let edges=ids.dropFirst().map { VocabGraphEdge(id:"\($0)",a:1,b:$0,morphology:false,evidence:"") }
        for _ in 0..<30 {
            VocabGraphPhysics.step(positions:&points,velocities:&velocities,edges:edges,pinned:[30],sizes:sizes)
            check()
        }
    }

    func testCurvedWideInkHasNoRadialCracks() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let canvas=InkMetalCanvasView();canvas.frame=CGRect(x:0,y:0,width:128,height:128);canvas.drawableSize=CGSize(width:512,height:512)
        let points=(0...80).map { i in
            let t=Double(i)/80*Double.pi*1.7
            return InkPoint(x:64+32*cos(t),y:64+32*sin(t),width:24)
        }
        canvas.renderItems=[InkRenderItem(stroke:InkStroke(kind:.pen,r:0,g:0,b:0,a:1,points:points),clip:canvas.bounds)]
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:512,height:512,mipmapped:false)
        descriptor.storageMode = .shared;descriptor.usage=[.renderTarget,.shaderRead]
        let texture=try XCTUnwrap(device.makeTexture(descriptor:descriptor)),command=try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        XCTAssertTrue(canvas.encodeFrame(to:texture,commandBuffer:command));command.commit();command.waitUntilCompleted()
        XCTAssertNil(command.error)
        var bytes=[UInt8](repeating:0,count:512*512*4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:512*4,from:MTLRegionMake2D(0,0,512,512),mipmapLevel:0) }
        var holes=0,sampled=0
        for i in 1..<800 {
            let angle=Double(i)/800*Double.pi*1.7
            for radius in stride(from:40.0,through:43.0,by:0.5) {
                let x=Int((64+radius*cos(angle))*4),y=Int((64+radius*sin(angle))*4)
                let offset=(y*512+x)*4+3
                sampled+=1
                if bytes[offset]<240 { holes+=1 }
            }
        }
        XCTAssertGreaterThan(sampled,5000);XCTAssertEqual(holes,0)
    }

    func testOCRCanonicalRasterIgnoresPageRotationAndCrop() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            context.beginPage()
            UIColor.black.setFill()
            UIBezierPath(rect: CGRect(x: 70, y: 100, width: 130, height: 40)).fill()
        }
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let size = OCRService.renderingSize(for: page.bounds(for: .mediaBox))
        let baseline = try XCTUnwrap(OCRService.recognitionImage(page: page, size: size)?.dataProvider?.data)
        page.setBounds(CGRect(x: 40, y: 60, width: 320, height: 480), for: .cropBox)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let image = try XCTUnwrap(OCRService.recognitionImage(page: page, size: size))
            XCTAssertEqual(try XCTUnwrap(image.dataProvider?.data) as Data, baseline as Data)
        }
    }

    func testOCRBoxesAlignWithRenderedText() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            context.beginPage()
            ("Alignment" as NSString).draw(at: CGPoint(x: 80, y: 120), withAttributes: [
                .font: UIFont.systemFont(ofSize: 32), .foregroundColor: UIColor.black])
        }
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        page.setBounds(CGRect(x: 40, y: 60, width: 320, height: 480), for: .cropBox)
        let words = OCRService.recognize(page: page)
        let word = try XCTUnwrap(words.first { $0.text.lowercased() == "alignment" })
        let rect = OCRService.pageRect(from: word, pageBounds: page.bounds(for: .mediaBox))
        XCTAssertEqual(rect.minX, 80, accuracy: 8)
        XCTAssertEqual(rect.midY, 458, accuracy: 12)
        XCTAssertGreaterThan(rect.width, 100)
        XCTAssertEqual(OCRService.wordIndex(at: CGPoint(x: rect.midX, y: rect.midY), in: words,
            pageBounds: page.bounds(for: .mediaBox)), words.firstIndex { $0.text == word.text })
    }

    func testOCRMediaOriginRoundTripAndLegacyCacheInvalidation() throws {
        let bounds = CGRect(x: 31, y: -27, width: 400, height: 600)
        let word = OCRWord(text: "test", x: 0.2, y: 0.3, w: 0.25, h: 0.05, line: 0)
        let rect = OCRService.pageRect(from: word, pageBounds: bounds)
        XCTAssertEqual(rect.minX, 111, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 363, accuracy: 0.001)
        XCTAssertEqual(OCRService.wordIndex(at: CGPoint(x: rect.midX, y: rect.midY), in: [word], pageBounds: bounds), 0)
        let db = try XCTUnwrap(AppDatabase.shared), sha = "ocr-test-" + UUID().uuidString
        defer { try? db.dbQueue.write { try $0.execute(sql: "DELETE FROM ocr_status WHERE docSha = ?", arguments: [sha]) } }
        try db.dbQueue.write { try $0.execute(sql: "INSERT INTO ocr_status (docSha, done, updatedAt) VALUES (?, 1, ?)", arguments: [sha, Date()]) }
        let store = OCRStore(db: db)
        XCTAssertFalse(store.isDone(docSha: sha))
        store.markDone(docSha: sha)
        XCTAssertTrue(store.isDone(docSha: sha))
    }

}

@MainActor
private final class CompletedWordTap: UITapGestureRecognizer {
    let point: CGPoint
    init(point: CGPoint) { self.point = point; super.init(target: nil, action: nil) }
    override var state: UIGestureRecognizer.State {
        get { .ended }
        set { }
    }
    override func location(in view: UIView?) -> CGPoint { point }
}

@MainActor
private final class BeganWordPress: UILongPressGestureRecognizer {
    private let hit: CGPoint
    init(point:CGPoint) { hit = point; super.init(target:nil,action:nil) }
    var testState: UIGestureRecognizer.State = .began
    override var state: UIGestureRecognizer.State { get { testState } set { testState = newValue } }
    override func location(in view:UIView?) -> CGPoint { hit }
}
