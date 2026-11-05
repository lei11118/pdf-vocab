import XCTest
import UIKit
import PDFKit
import MetalKit
import SwiftUI
import PencilKit
@testable import PdfVocab

@MainActor
final class InteractionPolishTests:XCTestCase {
    func testInkUndoRestoresOriginalStackingOrderAroundPeerAdditions() {
        func stroke(_ x: Double) -> InkStroke {
            InkStroke(kind:.pen,r:0,g:0,b:0,a:1,points:[InkPoint(x:x,y:10,width:2)])
        }
        let a = stroke(1), b = stroke(2), peer = stroke(3), moved = stroke(4)
        let original = InkPage(strokes:[a,b])
        let erased = InkPage(strokes:[b])
        XCTAssertEqual(InkPage.applyingChanges(from:erased,to:original,onto:InkPage(strokes:[b,peer])).strokes,[a,b,peer])
        XCTAssertEqual(InkPage.applyingChanges(from:original,to:InkPage(strokes:[moved,b]),onto:InkPage(strokes:[a,b,peer])).strokes,[moved,b,peer])
    }

    func testNativeInkMergesStaleEditsAndUndoWithoutLosingPeerOrMasks() throws {
        let store = PencilInkStore(db:try XCTUnwrap(AppDatabase.shared))
        let sha = "native-windows-"+UUID().uuidString
        defer { store.delete(docSha:sha,page:0) }
        func stroke(_ x:CGFloat) -> PKStroke {
            let points = [CGFloat(10),CGFloat(30)].map { y in
                PKStrokePoint(location:CGPoint(x:x,y:y),timeOffset:Double(y)/100,size:CGSize(width:3,height:3),opacity:1,force:1,azimuth:0,altitude:.pi/2)
            }
            return PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date()),mask:UIBezierPath(rect:CGRect(x:0,y:0,width:100,height:100)))
        }
        let a = stroke(10), b = stroke(20)
        XCTAssertTrue(store.mergeNative(docSha:sha,page:0,before:PKDrawing(),after:PKDrawing(strokes:[a]),source:UUID()))
        XCTAssertTrue(store.mergeNative(docSha:sha,page:0,before:PKDrawing(),after:PKDrawing(strokes:[b]),source:UUID()))
        let record = try XCTUnwrap(store.drawing(docSha:sha,page:0))
        let both = try PKDrawing(data:record.data)
        XCTAssertEqual(both.strokes.count,2)
        XCTAssertTrue(NativeInkChanges.equal(both.strokes[0],a))
        XCTAssertTrue(NativeInkChanges.equal(both.strokes[1],b))
        XCTAssertTrue(store.mergeNative(docSha:sha,page:0,before:PKDrawing(strokes:[a]),after:PKDrawing(),source:UUID()))
        let saved = try PKDrawing(data:XCTUnwrap(store.drawing(docSha:sha,page:0)).data)
        XCTAssertEqual(saved.strokes.count,1)
        XCTAssertTrue(NativeInkChanges.equal(saved.strokes[0],b))
        let restored = NativeInkChanges.applying(from:PKDrawing(strokes:[b]),to:both,onto:saved)
        XCTAssertTrue(NativeInkChanges.equal(restored.strokes[0],a))
    }
    func testDocumentWindowsShareGraphSessionButDifferentBooksStayIndependent() throws {
        let db = try XCTUnwrap(AppDatabase.shared)
        let id = "window-graph-" + UUID().uuidString
        let first = KnowledgeGraphStore.session(docId: id, db: db)
        let peer = KnowledgeGraphStore.session(docId: id, db: db)
        let other = KnowledgeGraphStore.session(docId: id+"-other", db: db)
        XCTAssertTrue(first === peer)
        XCTAssertFalse(first === other)
    }
    func testRulerMeasuresAlongEdgeWithoutMovingDocumentPose() throws {
        let host = UIView(frame: CGRect(x: 0,y: 0,width: 500,height: 500))
        let ruler = SmartRulerView(length: 500,host: host)
        host.addSubview(ruler)
        ruler.isOn = true
        ruler.setPose(position: CGPoint(x: 250,y: 250),angle: 0)
        let project = try XCTUnwrap(ruler.projector(startingAt: CGPoint(x: 100,y: 210)))
        XCTAssertEqual(project(CGPoint(x: 220,y: 203)),CGPoint(x: 220,y: 210))
        XCTAssertEqual(try XCTUnwrap(ruler.measuredLength),120,accuracy: 0.01)
        XCTAssertEqual(ruler.rulerPosition,CGPoint(x: 250,y: 250))
        XCTAssertEqual(ruler.angle,0)
        XCTAssertEqual(ruler.poseScale,1)
        XCTAssertNil(ruler.projector(startingAt: CGPoint(x: 100,y: 100)))
    }
    func testIndependentPDFWindowRequestsKeepPageAndHaveUniqueIdentity() throws {
        let first = PDFReaderWindowRequest(docSha: "document", page: 42)
        let second = PDFReaderWindowRequest(docSha: "document", page: 42)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try JSONDecoder().decode(PDFReaderWindowRequest.self, from: JSONEncoder().encode(first)), first)
    }

    func testStaleInkEditorsMergeAdditionsEraseAndUndoWithoutReplacingPeerStrokes() throws {
        let store = PencilInkStore(db: try XCTUnwrap(AppDatabase.shared))
        let sha = "multiwindow-" + UUID().uuidString
        defer { store.delete(docSha: sha, page: 0) }
        func stroke(_ x: Double) -> InkStroke {
            InkStroke(kind: .pen, r: 0, g: 0, b: 0, a: 1, points: [InkPoint(x: x, y: 20, width: 2)])
        }
        let a = stroke(10), b = stroke(20), c = stroke(30)
        let empty = InkPage(), first = InkPage(strokes: [a])
        _ = store.merge(docSha: sha, page: 0, before: empty, after: first)
        let both = try XCTUnwrap(store.merge(docSha: sha, page: 0, before: empty, after: InkPage(strokes: [b])))
        XCTAssertEqual(both.strokes, [a,b])
        let erased = try XCTUnwrap(store.merge(docSha: sha, page: 0, before: first, after: empty))
        XCTAssertEqual(erased.strokes, [b])
        _ = store.merge(docSha: sha, page: 0, before: empty, after: InkPage(strokes: [c]))
        let undo = try XCTUnwrap(store.merge(docSha: sha, page: 0, before: empty, after: first))
        XCTAssertEqual(undo.strokes, [b,c,a])
        let ownUndo = InkPage.applyingChanges(from: InkPage(strokes: [c]), to: empty, onto: undo)
        XCTAssertEqual(ownUndo.strokes, [b,a])
    }

    func testHoverKeepsPartsOfSpeechAndAllChineseSenses() {
        let entry = DictEntry(word:"function",phonetic:"test",translation:"【通用】\nn. 函数；功能\nvi. 运转\n【医学】\nn. 生理功能",definition:"English definition",pos:nil,collins:0,oxford:false,tags:[],bnc:0,frq:0)
        XCTAssertEqual(WordInteraction.hoverDetail(entry),"n. 函数；功能\nvi. 运转\nn. 生理功能")
        XCTAssertFalse((WordInteraction.hoverDetail(entry) ?? "").contains("English definition"))
    }

    func testHoverIncludesEveryChineseSenseButNoEnglishDefinitionOrPhonetic() {
        let senses = (0..<120).map { "n. 中文释义\($0)" }.joined(separator:"\n")
        let entry = DictEntry(word:"term",phonetic:"test",translation:"【通用】\n\(senses)\n【医学】\n医学含义",definition:"English definition",pos:nil,collins:0,oxford:false,tags:[],bnc:0,frq:0)
        let detail = WordInteraction.chineseDetail(entry) ?? ""
        XCTAssertTrue(detail.contains("中文释义0"))
        XCTAssertTrue(detail.contains("中文释义119"))
        XCTAssertTrue(detail.contains("医学含义"))
        XCTAssertFalse(detail.contains("【通用】"))
        XCTAssertFalse(detail.contains("English definition"))
        XCTAssertFalse(detail.contains("test"))
        XCTAssertFalse(detail.contains("n. "))
        XCTAssertEqual(detail.components(separatedBy:"\n").count,121)
    }

    func testMasterGraphKeepsBookNodesPositionsAndLegacyData() throws {
        func document(_ sha:String,_ title:String) -> DocumentRecord {
            DocumentRecord(sha256:sha,title:title,fileName:sha+".pdf",pageCount:1,hasTextLayer:true,
                           importedAt:Date(),lastPage:0,pageX:0,pageY:0,zoom:1,zoomAuto:true)
        }
        let a = document("a","Book A"), b = document("b","Book B")
        var graph = KnowledgeGraph(id:KnowledgeGraph.libraryID,docId:KnowledgeGraph.libraryID)
        XCTAssertTrue(graph.syncDocuments([a,b]))
        XCTAssertFalse(graph.syncDocuments([a,b]))
        XCTAssertEqual(graph.nodes.count,2)
        let firstID = graph.nodes[0].id
        graph.nodes[0].frame.origin = CGPoint(x:900,y:200)
        graph.connect(from:firstID,anchor:.right,to:graph.nodes[1].id,target:.left)
        XCTAssertTrue(graph.syncDocuments([b,document("c","Book C")]))
        XCTAssertEqual(graph.nodes.count,3) // A missing book is preserved and can reappear.
        XCTAssertEqual(graph.nodes[0].id,firstID)
        XCTAssertEqual(graph.nodes[0].frame.origin,CGPoint(x:900,y:200))
        XCTAssertEqual(graph.edges.count,1)
        XCTAssertEqual(try JSONDecoder().decode(KnowledgeGraph.self,from:JSONEncoder().encode(graph)),graph)

        let oldNode = KnowledgeNode(graphId:"old",kind:.text,frame:CGRect(x:1,y:2,width:3,height:4),text:"legacy")
        let oldData = try JSONEncoder().encode(oldNode)
        let decoded = try JSONDecoder().decode(KnowledgeNode.self,from:oldData)
        XCTAssertEqual(decoded.text,"legacy")
        XCTAssertNil(decoded.sourceDocumentId)
    }

    func testSentenceTranslationRejectsStaleResults() {
        guard #available(iOS 18.0, *) else { return }
        let state = SentenceTranslationState()
        let first = SentenceTranslationRequest(text:"First sentence")
        let second = SentenceTranslationRequest(text:"Second sentence")
        state.start(first); state.start(second)
        state.finish("旧结果",request:first)
        XCTAssertNil(state.result)
        state.finish("新结果",request:second)
        XCTAssertEqual(state.displayText,"新结果")
        state.reset()
        XCTAssertNil(state.displayText)
    }

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
        var contextualSelections: [ContextualSelection] = []
        let coordinator = ReaderCoordinator(onPageChanged:{ _ in },onSelectionInfo:{ if let info = $0 {
            texts.append(info.text)
            if let contextual = info.contextual { contextualSelections.append(contextual) }
        } })
        coordinator.pdfView = view
        coordinator.docSha = "openstax-link-fixture"
        coordinator.contextReadingEnabled = true
        coordinator.contextReadingGeneration = 4
        coordinator.hapticsEnabled = false
        let point = view.convert(CGPoint(x:183.4946,y:377.4785),from:page)
        let press = BeganWordPress(point:point)
        coordinator.perform(NSSelectorFromString("handlePress:"),with:press)
        XCTAssertEqual(texts.last,"Functions")
        XCTAssertEqual(contextualSelections.last?.displaySurface, "Functions")
        XCTAssertEqual(contextualSelections.last?.tokens.map(\.sourceSurface), ["Functions"])
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

    func testSingleTapNeverSelectsWordsButDoubleTapStillSelectsPunctuation() throws {
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
            let before = picked.count
            coordinator.perform(NSSelectorFromString("handleTap:"),with:CompletedWordTap(point:point))
            XCTAssertEqual(picked.count,before,"A short single tap must not create or replace a word selection")
            coordinator.perform(NSSelectorFromString("handleDoubleTap:"),with:CompletedWordTap(point:point))
            coordinator.clearTempHighlight()
        }
        XCTAssertEqual(picked,["word","next","+"])
        coordinator.clearTempHighlight()
    }

    func testContextModeCoordinatorRoutesWordAndWholeTokenDragToSymbol() throws {
        let sourceText = "charge + beta"
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 300)).pdfData { context in
            context.beginPage()
            (sourceText as NSString).draw(at: CGPoint(x: 30, y: 90), withAttributes: [.font: UIFont.systemFont(ofSize: 26)])
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let source = try XCTUnwrap(page.string)
        let sourceNSString = source as NSString
        let chargeRange = sourceNSString.range(of: "charge")
        let symbolRange = sourceNSString.range(of: "+")
        XCTAssertNotEqual(chargeRange.location, NSNotFound)
        XCTAssertNotEqual(symbolRange.location, NSNotFound)

        let view = VocabPDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = view
        window.frame = view.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        view.displayMode = .singlePage
        view.document = document
        view.scaleFactor = 2.5
        view.layoutDocumentView()
        view.go(to: page)

        func point(for range: NSRange) throws -> CGPoint {
            let selection = try XCTUnwrap(page.selection(for: range))
            let rect = selection.bounds(for: page)
            XCTAssertTrue(SelectionGeometry.isValid(rect))
            return view.convert(CGPoint(x: rect.midX, y: rect.midY), from: page)
        }
        let chargePoint = try point(for: chargeRange)
        let symbolPoint = try point(for: symbolRange)
        var events: [SelectionInfo?] = []
        let coordinator = ReaderCoordinator(onPageChanged: { _ in }, onSelectionInfo: { events.append($0) })
        coordinator.pdfView = view
        coordinator.docSha = "context-coordinator-fixture"
        coordinator.contextReadingEnabled = true
        coordinator.contextReadingGeneration = 12
        coordinator.hapticsEnabled = false

        coordinator.perform(NSSelectorFromString("handleDoubleTap:"), with: CompletedWordTap(point: chargePoint))
        let doubleTapInfo = try XCTUnwrap(events.compactMap { $0 }.last)
        let doubleTapContext = try XCTUnwrap(doubleTapInfo.contextual)
        XCTAssertEqual(doubleTapContext.generation, 12)
        XCTAssertEqual(doubleTapContext.displaySurface.lowercased(), "charge")
        XCTAssertEqual(doubleTapContext.tokens.map(\.sourceSurface), ["charge"])
        XCTAssertEqual(doubleTapContext.tokens.first?.geometryQuality, .word)
        XCTAssertEqual(doubleTapContext.sourceSpans.first?.location, chargeRange.location)

        coordinator.dismissSelection()
        let beforeSingleTap = events.count
        coordinator.perform(NSSelectorFromString("handleTap:"), with: CompletedWordTap(point: chargePoint))
        XCTAssertEqual(events.count, beforeSingleTap, "Context mode must not change single-tap selection behavior")

        let press = MutableContextPress(point: chargePoint)
        coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
        XCTAssertEqual(events.compactMap { $0 }.last?.contextual?.tokens.map(\.sourceSurface), ["charge"])
        press.point = symbolPoint
        press.testState = .changed
        coordinator.perform(NSSelectorFromString("handlePress:"), with: press)
        let draggedContext = try XCTUnwrap(events.compactMap { $0 }.last?.contextual)
        XCTAssertEqual(draggedContext.tokens.map(\.sourceSurface), ["charge", "+"], "A punctuation seed must be selectable as the drag endpoint")
        XCTAssertFalse(draggedContext.tokens.contains { $0.sourceSurface == "beta" }, "The source range must stop at the visual endpoint token")
        XCTAssertTrue(draggedContext.tokens.allSatisfy { $0.geometryQuality == .approximate })
        press.testState = .ended
        coordinator.perform(NSSelectorFromString("handlePress:"), with: press)

        let pendingPress = MutableContextPress(point: chargePoint)
        coordinator.setContextReadingMode(true, generation: 13)
        coordinator.perform(NSSelectorFromString("handlePress:"), with: pendingPress)
        let beforeModeChange = events.count
        coordinator.setContextReadingMode(false, generation: 14)
        XCTAssertEqual(events.count, beforeModeChange, "A feature switch clears transient selection without a stale nil callback")
        pendingPress.point = symbolPoint
        pendingPress.testState = .changed
        coordinator.perform(NSSelectorFromString("handlePress:"), with: pendingPress)
        XCTAssertEqual(events.count, beforeModeChange, "A late drag update must not restore the cleared contextual selection")
        coordinator.setContextReadingMode(true, generation: 13)
        XCTAssertFalse(coordinator.contextReadingEnabled, "An older window generation must not restore a stale mode")
        XCTAssertEqual(coordinator.contextReadingGeneration, 14)
        coordinator.perform(NSSelectorFromString("handleDoubleTap:"), with: CompletedWordTap(point: chargePoint))
        let legacyInfo = try XCTUnwrap(events.compactMap { $0 }.last)
        XCTAssertNil(legacyInfo.contextual, "Turning context mode off restores the legacy selection payload")
    }

    func testHoverSizeFitsActualContentAndCapsLongDefinitions() {
        let short = HoverBubbleLayout.size(term:"a",detail:"一个",maximumWidth:400,maximumHeight:420)
        let long = HoverBubbleLayout.size(term:"function",detail:String(repeating:"函数及其所有专业释义。",count:100),maximumWidth:400,maximumHeight:420)
        XCTAssertLessThan(short.width,long.width)
        XCTAssertLessThan(short.height,100)
        XCTAssertEqual(long.height,420)
        let narrow = HoverBubbleLayout.size(term:"function",detail:"函数",maximumWidth:120,maximumHeight:80)
        XCTAssertLessThanOrEqual(narrow.width,120)
        XCTAssertLessThanOrEqual(narrow.height,80)
    }

    func testNarrowCapsuleWidthIsContinuousAcrossLayoutThreshold() {
        XCTAssertEqual(ReaderWindowGeometry.minimumWidth(height:96,allowsCompact:true),180)
        XCTAssertEqual(ReaderWindowGeometry.minimumWidth(height:220,allowsCompact:true),260)
        let before = ReaderWindowGeometry.minimumWidth(height:139.9,allowsCompact:true)
        let after = ReaderWindowGeometry.minimumWidth(height:140.1,allowsCompact:true)
        XCTAssertLessThan(after-before,0.2)
        for height in stride(from:CGFloat(64),through:500,by:1) {
            XCTAssertEqual(ReaderWindowGeometry.minimumWidth(height:height,allowsCompact:false),260)
        }
    }

    func testGridTracksNegativePanAndKeepsBoundedDensity() {
        for zoom in [CGFloat(0.01),0.1,1,4,40] {
            let spacing = GraphGridLayout.spacing(zoom:zoom)
            XCTAssertGreaterThanOrEqual(spacing,20)
            XCTAssertLessThanOrEqual(spacing,80)
            let a = GraphGridLayout.lines(length:1000,offset:-17,spacing:spacing)
            let b = GraphGridLayout.lines(length:1000,offset:-17+spacing,spacing:spacing)
            XCTAssertEqual(a.count,b.count)
            for (x,y) in zip(a,b) { XCTAssertEqual(x,y,accuracy:0.0001) }
            XCTAssertLessThanOrEqual(a.count,51)
            XCTAssertTrue(a.allSatisfy { $0 >= 0 && $0 <= 1000 })
        }
    }

    func testSelectionBarDoesNotInstallModalEditInteractionOrCoverOtherViews() throws {
        let parent = UIView(frame:CGRect(x:0,y:0,width:900,height:900))
        let host = UIView(frame:parent.bounds); parent.addSubview(host)
        let menu = SelectionMenuController()
        menu.textProvider = { "function" }
        menu.targetRectProvider = { _ in CGRect(x:300,y:300,width:100,height:30) }
        menu.install(on:host); menu.present(at:CGPoint(x:350,y:300))
        XCTAssertTrue(menu.isPresented)
        XCTAssertFalse(host.interactions.contains { $0 is UIEditMenuInteraction })
        let bar = try XCTUnwrap(host.subviews.first { $0.accessibilityIdentifier == "selection-edit-bar" })
        XCTAssertFalse(bar.frame.contains(CGPoint(x:50,y:600)))
        XCTAssertTrue(host.hitTest(CGPoint(x:50,y:600),with:nil) === host)
        menu.updatePosition(animated:false)
        XCTAssertTrue(menu.isPresented)
        menu.dismiss(); XCTAssertNil(bar.superview)
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
                let decoded = PDFTextLayout.glyphs(on:page).map { $0.text }.joined().filter { !$0.isWhitespace }
                XCTAssertEqual(decoded,words.joined(),"Content stream decoding: \(name) \(size)")
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

    func testFormTextInheritsResourcesAndAppliesMatrices() throws {
        let content = "q 2 0 0 2 5 7 cm /Form Do Q"
        let form = "BT /Body 12 Tf 1 0 0 1 10 40 Tm (Alpha beta) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /Body 6 0 R >> /XObject << /Form 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 200 100] /Matrix [1 0 0 1 20 30] /Length \(form.utf8.count) >>\nstream\n\(form)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
        ]
        var data = Data("%PDF-1.4\n".utf8), offsets = [0]
        for (i, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(i+1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let start = data.count
        var trailer = "xref\n0 \(objects.count+1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { trailer += String(format:"%010d 00000 n \n",offset) }
        trailer += "trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF"
        data.append(Data(trailer.utf8))
        let document = try XCTUnwrap(PDFDocument(data:data)), page = try XCTUnwrap(document.page(at:0))
        let glyphs = PDFTextLayout.glyphs(on:page)
        XCTAssertEqual(glyphs.map { $0.text }.joined(),"Alpha beta")
        let first = try XCTUnwrap(glyphs.first)
        XCTAssertEqual(first.rect.minX,65,accuracy:0.01)
        // The PDF declares the baseline, not a font descriptor's descent.
        XCTAssertEqual(first.baseline.x,65,accuracy:0.01)
        XCTAssertEqual(first.baseline.y,147,accuracy:0.01)
        XCTAssertEqual(first.rect.height,24,accuracy:0.01)
        let selection = SelectionGeometry.initialWord(on:page,at:CGPoint(x:first.rect.midX,y:first.rect.midY))
        XCTAssertEqual(selection.map { SelectionGeometry.lookupText(for:$0) },"Alpha")
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
        let existingIDs = Set(store.listWords().map(\.id))
        for surface in ["serendipity", "luminous", "resilience", "wanderlust"] {
            let id = try XCTUnwrap(store.collectHeadword(lemma: surface, surface: surface))
            if !existingIDs.contains(id) { ids.append(id) }
        }
        defer { for id in ids { store.deleteWord(id: id) } }
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true).appendingPathComponent("UIReview")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Real imported sample exercises the reading chrome and populated home.
        let docs = DocumentStore(db: db)
        let sampleURL = FileManager.default.temporaryDirectory.appendingPathComponent("The architecture of language.pdf")
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
        let graphReview = KnowledgeGraphStore(docId: "review-" + UUID().uuidString, db: db)
        await graphReview.load()
        graphReview.graph.migrationVersion = 1
        let first = KnowledgeNode(graphId:graphReview.graph.id,kind:.text,frame:CGRect(x:0,y:0,width:290,height:200),text:"Derivative\n导数\nThe instantaneous rate of change.")
        let second = KnowledgeNode(graphId:graphReview.graph.id,kind:.text,frame:CGRect(x:340,y:200,width:290,height:210),text:"Integral\n积分\nConnect ideas by dragging a side anchor.")
        graphReview.graph.nodes = [first,second]
        graphReview.graph.connect(from:first.id,anchor:.right,to:second.id,target:.top)
        let sentenceState = SentenceTranslationState()
        if #available(iOS 18.0, *) {
            let request = SentenceTranslationRequest(text:"Every word connects to another idea.")
            sentenceState.start(request); sentenceState.finish("每个单词都与另一个概念相联系。",request:request)
        }
        let contextCanonical = SemanticTokenizer.canonicalize("charge", documentSHA256: "ui-fixture", pageIndex: 0)
        let contextToken = try XCTUnwrap(contextCanonical.tokens.first).withGeometryQuality(.word)
        let contextFixture = ContextualSelection(documentSHA256: contextCanonical.documentSHA256,
                                                 pageIndex: contextCanonical.pageIndex,
                                                 sourceSpans: [contextToken.span],
                                                 tokens: [contextToken],
                                                 displaySurface: "charge",
                                                 generation: 1)
        let cases: [(String, CGSize, AnyView)] = [
            ("hover-short",CGSize(width:480,height:600),AnyView(HoverTipView(term:"function",detail:"函数；功能",anchor:CGPoint(x:240,y:450),bounds:CGSize(width:480,height:600)).background(DS.background1))),
            ("hover-long",CGSize(width:480,height:600),AnyView(HoverTipView(term:"function",detail:String(repeating:"函数；功能；作用；职责。\n",count:40),anchor:CGPoint(x:240,y:500),bounds:CGSize(width:480,height:600)).background(DS.background1))),
            ("library-dark",CGSize(width:834,height:1194),AnyView(LibraryView(store:docs).environment(\.colorScheme,.dark))),
            ("palette-marker-expanded", CGSize(width: 360, height: 420), AnyView(PencilPaletteView(session: markerReview, onUndo: {}, onRedo: {}).stylePanel.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white))),
            ("palette-brush-expanded", CGSize(width: 320, height: 420), AnyView(PencilPaletteView(session: brushReview, onUndo: {}, onRedo: {}).stylePanel.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white))),
            ("library-ipad", CGSize(width: 834, height: 1194), AnyView(LibraryView(store: DocumentStore(db: db)))),
            ("workspace-folder-editor", CGSize(width: 480, height: 900), AnyView(WorkspaceFolderEditor(folder: reviewFolder, onSave: { _, _ in }))),
            ("vocab-ipad", CGSize(width: 834, height: 1194), AnyView(VocabListView(store: store))),
            ("vocab-split", CGSize(width: 480, height: 900), AnyView(VocabListView(store: store))),
            ("vocab-window-narrow", CGSize(width: 300, height: 700), AnyView(VocabListView(store: store).environment(\.readerPanelClose, {}))),
            ("library-narrow", CGSize(width: 320, height: 900), AnyView(LibraryView(store: docs))),
            ("word-window", CGSize(width: 834, height: 900), AnyView(FloatingCardWindow(content:.word("function"),bounds:CGSize(width:834,height:900),onClose:{},onSelectWord:{_ in}))),
            ("context-card-light", CGSize(width: 480, height: 600), AnyView(FloatingCardWindow(content:.contextual(contextFixture),bounds:CGSize(width:480,height:600),onClose:{},onSelectWord:{_ in}).background(DS.background1))),
            ("context-card-narrow-dark", CGSize(width: 320, height: 600), AnyView(FloatingCardWindow(content:.contextual(contextFixture),bounds:CGSize(width:320,height:600),onClose:{},onSelectWord:{_ in}).background(DS.background1).preferredColorScheme(.dark))),
            ("word-capsule", CGSize(width: 360, height: 96), AnyView(CompactCardView(content:.word("function"),onClose:{}).background(DS.background3))),
            ("sentence-capsule",CGSize(width:480,height:96),AnyView(CompactCardView(content:.sentence("Every word connects to another idea.",6),onClose:{},sentenceTranslation:"每个单词都与另一个概念相联系。").background(DS.background3))),
            ("sentence-card",CGSize(width:480,height:600),AnyView(WordCardPanel(content:.sentence("Every word connects to another idea.",6),onClose:{},onSelectWord:{_ in}).environmentObject(sentenceState).environment(\.readerPanelClose,{}))),
            ("function-window", CGSize(width: 834, height: 900), AnyView(ReaderCapsulePanel(title:"设置",bounds:CGSize(width:834,height:900),onClose:{}) { SettingsView(db:db) })),
            ("export-window-narrow",CGSize(width:320,height:700),AnyView(AnkiExportSheet(store:store,words:store.listWords()))),
            ("translation-window",CGSize(width:320,height:600),AnyView(ReaderSentenceTranslationView(text:"Every word connects to another idea.",cached:"每个单词都与另一个概念相联系。"))),
            ("search-window-narrow",CGSize(width:320,height:600),AnyView(ReaderSearchSheet(url:try docs.pdfURL(for:record),docSha:record.sha256,docTitle:record.title,ocrStore:OCRStore(db:db)))),
            ("graph-window-narrow", CGSize(width: 300, height: 650), AnyView(KnowledgeGraphView(model:graphReview,tools:PencilToolSession(),vocab:store).environment(\.readerPanelClose,{}))),
            ("master-graph-ipad",CGSize(width:834,height:1194),AnyView(KnowledgeGraphLibrary(store:docs))),
            ("vocab-dark", CGSize(width: 834, height: 1194), AnyView(VocabListView(store: store).preferredColorScheme(.dark))),
            ("library-split", CGSize(width: 480, height: 900), AnyView(LibraryView(store: docs))),
            ("vocab-large-type", CGSize(width: 480, height: 1100), AnyView(VocabListView(store: store).dynamicTypeSize(.xxxLarge))),
            ("vocab-compact", CGSize(width: 834, height: 1194), AnyView(VocabListView(store: store))),
            ("arc-reading", CGSize(width:834,height:600),AnyView(PencilArcMenu(session:markerReview,anchor:CGPoint(x:417,y:400),bounds:CGSize(width:834,height:600),onDismiss:{}).background(DS.background1))),
            ("arc-marking", CGSize(width:480,height:600),AnyView(PencilArcMenu(session:brushReview,anchor:CGPoint(x:240,y:400),bounds:CGSize(width:480,height:600),marking:true,canUndo:true,onDismiss:{}).background(DS.background1))),
            ("dictionary-combination",CGSize(width:834,height:1194),AnyView(SettingsView(db:db))),
            ("graph-ipad", CGSize(width: 834, height: 1194), AnyView(KnowledgeGraphView(model: graphReview, tools: PencilToolSession(), vocab: store))),
            ("graph-dark-split", CGSize(width: 480, height: 900), AnyView(KnowledgeGraphView(model: graphReview, tools: PencilToolSession(), vocab: store).preferredColorScheme(.dark))),
            ("reader-ipad", CGSize(width: 834, height: 1194), AnyView(ReaderView(doc: record, store: docs))),
            ("reader-split", CGSize(width: 480, height: 900), AnyView(ReaderView(doc: record, store: docs))),
            ("palette-ipad", CGSize(width: 834, height: 240), AnyView(PencilPaletteView(session: PencilToolSession(), onUndo: {}, onRedo: {}).padding().background(DS.background1))),
            ("palette-split", CGSize(width: 480, height: 240), AnyView(PencilPaletteView(session: PencilToolSession(), onUndo: {}, onRedo: {}).padding().background(DS.background1))),
            ("palette-window-narrow", CGSize(width:320,height:240),AnyView(PencilPaletteView(session:PencilToolSession(),onUndo:{},onRedo:{},onExitWriting:{}).padding().background(DS.background1)))
        ]
        for (name, size, content) in cases {
            UserDefaults.standard.set(name == "vocab-compact", forKey: "vocabCompactLayout")
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            let host = UIHostingController(rootView:content.tint(DS.accent).buttonStyle(DSPressableButtonStyle()))
            host.overrideUserInterfaceStyle = name.contains("dark") ? .dark : .light
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
            try await Task.sleep(for:.milliseconds(name.hasPrefix("graph-") ? 2500 : name.hasPrefix("library-") ? 1800 : 700))
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

    func testRulerSoftSnapIsContinuousAtToleranceBoundary() {
        let target = 30.0 * Double.pi / 180
        let tolerance = SmartRulerView.snapToleranceDegrees * Double.pi / 180
        let epsilon = 0.001 * Double.pi / 180
        let midpoint = SmartRulerView.calculateSoftSnappedAngle(current: target + tolerance / 2)
        XCTAssertEqual(midpoint.angle, target + tolerance / 4, accuracy: 1e-12)

        let inside = SmartRulerView.calculateSoftSnappedAngle(current: target + tolerance - epsilon)
        let outside = SmartRulerView.calculateSoftSnappedAngle(current: target + tolerance + epsilon)
        XCTAssertTrue(inside.didSnap)
        XCTAssertFalse(outside.didSnap)
        XCTAssertLessThan(abs(inside.angle - outside.angle), 3 * epsilon)
    }

    func testRulerRotationUsesSnappedAngleDeltaAroundDistantPivot() {
        let initialPivot = CGPoint(x:40,y:50)
        let currentPivot = CGPoint(x:45,y:58)
        let initialPosition = CGPoint(x:700,y:320)
        let rotation = CGFloat(37 * Double.pi / 180)
        var session = SmartRulerRotationSession(position:initialPosition,angle:0,pivot:initialPivot,recognizerRotation:0)

        let pose = session.update(pivot:currentPivot,recognizerRotation:rotation)
        XCTAssertNotNil(pose)
        let dx = initialPosition.x - initialPivot.x
        let dy = initialPosition.y - initialPivot.y
        let expected = CGPoint(
            x:currentPivot.x + dx*cos(rotation) - dy*sin(rotation),
            y:currentPivot.y + dx*sin(rotation) + dy*cos(rotation)
        )
        XCTAssertEqual(pose?.position.x ?? 0,expected.x,accuracy:1e-5)
        XCTAssertEqual(pose?.position.y ?? 0,expected.y,accuracy:1e-5)
        XCTAssertEqual(pose?.angle ?? 0,rotation,accuracy:1e-5)
    }

    func testRulerSoftSnapCrossesZeroAndOneEightyWithoutFlip() throws {
        let pivot = CGPoint(x:50,y:40)
        let initialPosition = CGPoint(x:420,y:260)
        let initialAngle = CGFloat(179 * Double.pi / 180)
        var session = SmartRulerRotationSession(position:initialPosition,angle:initialAngle,pivot:pivot,recognizerRotation:0)

        let first = session.update(pivot:pivot,recognizerRotation:CGFloat(2 * Double.pi / 180))
        let firstAngle = SmartRulerView.normalizedAngle(Double(first?.angle ?? 0))
        XCTAssertGreaterThan(firstAngle,0)
        XCTAssertLessThan(firstAngle,Double.pi / 180)

        let second = session.update(pivot:pivot,recognizerRotation:CGFloat(3 * Double.pi / 180))
        let secondAngle = SmartRulerView.normalizedAngle(Double(second?.angle ?? 0))
        XCTAssertGreaterThan(secondAngle,Double.pi / 180)
        XCTAssertLessThan(secondAngle,2 * Double.pi / 180)
        let initialRadius = hypot(initialPosition.x-pivot.x,initialPosition.y-pivot.y)
        let finalPosition = try XCTUnwrap(second?.position)
        XCTAssertEqual(hypot(finalPosition.x-pivot.x,finalPosition.y-pivot.y),initialRadius,accuracy:1e-5)
    }

    func testRulerRotationFinishKeepsLastTwoFingerPoseAndPanRebasesOnTouchCountChange() throws {
        let initialPivot = CGPoint(x:20,y:30)
        let lastPivot = CGPoint(x:35,y:44)
        var rotation = SmartRulerRotationSession(
            position:CGPoint(x:500,y:260),angle:0,pivot:initialPivot,recognizerRotation:0
        )
        let updated = rotation.update(pivot:lastPivot,recognizerRotation:CGFloat(23 * Double.pi / 180))
        let changed = try XCTUnwrap(updated)
        let final = rotation.finish()
        XCTAssertEqual(final.position,changed.position)
        XCTAssertEqual(final.angle,changed.angle)
        XCTAssertNil(rotation.angleBadgeCenter)

        var pan = SmartRulerPanBaseline()
        pan.begin(at:CGPoint(x:100,y:100),touchCount:1)
        XCTAssertTrue(pan.rebaseIfTouchCountChanged(2,at:CGPoint(x:120,y:130)))
        XCTAssertEqual(pan.origin,CGPoint(x:120,y:130))
        XCTAssertFalse(pan.rebaseIfTouchCountChanged(2,at:CGPoint(x:140,y:150)))
        XCTAssertTrue(pan.rebaseIfTouchCountChanged(1,at:CGPoint(x:130,y:140)))
        XCTAssertEqual(pan.origin,CGPoint(x:130,y:140))
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

@MainActor
private final class MutableContextPress: UILongPressGestureRecognizer {
    var point: CGPoint
    var testState: UIGestureRecognizer.State = .began
    init(point: CGPoint) { self.point = point; super.init(target: nil, action: nil) }
    override var state: UIGestureRecognizer.State { get { testState } set { testState = newValue } }
    override func location(in view: UIView?) -> CGPoint { point }
}
