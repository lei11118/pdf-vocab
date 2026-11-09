import XCTest
import UIKit

final class ReaderRouteUITests:XCTestCase {
    func testWorkspaceNavigationAtPortraitAndLandscapeWidths() {
        let app = XCUIApplication()
        app.launchArguments = ["--reader-route-audit","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["添加文件夹或 PDF"].waitForExistence(timeout: 15))
        for (orientation,name) in [(UIDeviceOrientation.landscapeLeft,"workspace-landscape"),(.portrait,"workspace-portrait")] {
            XCUIDevice.shared.orientation = orientation
            let predicate = NSPredicate { _,_ in
                let frame = app.frame
                let expectedDirection = orientation == .portrait
                    ? frame.height > frame.width
                    : frame.width > frame.height
                let add = app.buttons["添加文件夹或 PDF"]
                return expectedDirection && add.isHittable
            }
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:predicate,object:app)],timeout:10),.completed)
            XCTAssertTrue(app.buttons["添加文件夹或 PDF"].waitForExistence(timeout: 5))
            // App-cropped captures can retain portrait crop coordinates after
            // rotation. Capture the composed display instead of that crop.
            let snapshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            snapshot.name = name; snapshot.lifetime = .keepAlways; add(snapshot)
        }
        XCUIDevice.shared.orientation = .portrait
    }
    func testContextAndDictionaryShareScrollableSurfaces() {
        let app = XCUIApplication()
        app.launchArguments = ["--context-display-audit","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch()

        let identifiers = ["word-bubble-scroll-content",
                            "contextual-hover-candidate",
                            "hover-dictionary-definition",
                            "compact-contextual-scroll-content",
                            "compact-contextual-term",
                            "compact-contextual-dictionary-definitions"]
        for identifier in identifiers {
            let element = app.descendants(matching:.any).matching(identifier:identifier).firstMatch
            XCTAssertTrue(element.waitForExistence(timeout:15),"Missing accessibility identifier: \(identifier)")
        }
        let contextualCandidates = app.descendants(matching:.any).matching(identifier:"contextual-hover-candidate")
        XCTAssertEqual(contextualCandidates.count,2,"Both surfaces expose their contextual meaning")

        let hoverSurface = app.descendants(matching:.any).matching(identifier:"word-bubble-scroll-content").firstMatch
        let compactSurface = app.descendants(matching:.any).matching(identifier:"compact-contextual-scroll-content").firstMatch
        let hoverDictionary = app.descendants(matching:.any).matching(identifier:"hover-dictionary-definition").firstMatch
        let compactDictionary = app.descendants(matching:.any).matching(identifier:"compact-contextual-dictionary-definitions").firstMatch
        let hoverDictionaryStartY = hoverDictionary.frame.minY
        let compactDictionaryStartY = compactDictionary.frame.minY
        let initialScreenshot = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        initialScreenshot.name = "context-dictionary-surfaces"
        initialScreenshot.lifetime = .keepAlways
        add(initialScreenshot)

        XCTAssertTrue(hoverSurface.exists)
        XCTAssertTrue(compactSurface.exists)
        for _ in 0..<8 { hoverSurface.swipeUp() }
        for _ in 0..<8 { compactSurface.swipeUp() }

        let hoverValue = [hoverDictionary.value as? String, hoverDictionary.label].compactMap { $0 }.joined(separator: " ")
        let compactValue = [compactDictionary.value as? String, compactDictionary.label].compactMap { $0 }.joined(separator: " ")
        XCTAssertTrue(hoverValue.contains("末尾定义：Hover 字典释义可达。"),
                      "value=\(String(describing:hoverDictionary.value)); label=\(hoverDictionary.label)")
        XCTAssertTrue(compactValue.contains("末尾定义：Compact 胶囊释义可达。"),
                      "value=\(String(describing:compactDictionary.value)); label=\(compactDictionary.label)")
        XCTAssertLessThan(hoverDictionary.frame.minY,hoverDictionaryStartY-4,
                          "The hover dictionary moves upward as its scroll surface advances")
        XCTAssertLessThan(compactDictionary.frame.minY,compactDictionaryStartY-4,
                          "The compact dictionary moves upward as its scroll surface advances")
        XCTAssertTrue(hoverDictionary.isHittable,"The hover dictionary remains reachable after scrolling")
        XCTAssertTrue(compactDictionary.isHittable,"The compact dictionary remains reachable after scrolling")

        let scrolledScreenshot = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        scrolledScreenshot.name = "scrolled-dictionary-content"
        scrolledScreenshot.lifetime = .keepAlways
        add(scrolledScreenshot)
    }
    func testReaderCanvasAndOverlayRootStayFullBleedAcrossOrientations() {
        let app = XCUIApplication()
        app.launchArguments = ["--reader-route-audit","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let document = app.buttons.containing(.staticText,identifier:"Reader-route-audit").firstMatch
        if document.waitForExistence(timeout:10) { document.tap() }
        _ = app.staticTexts["A function relates an input to an output."].waitForExistence(timeout:10)
        let initialScreenshot = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        initialScreenshot.name = "reader-canvas-before-assertions"
        initialScreenshot.lifetime = .keepAlways
        add(initialScreenshot)

        let canvasRoot = app.descendants(matching:.any).matching(identifier:"reader.canvas-root").firstMatch
        let pdfCanvas = app.descendants(matching:.any).matching(identifier:"reader.pdf-canvas").firstMatch
        let topAction = app.buttons.matching(identifier:"reader.more-menu").firstMatch
        let bottomMode = app.buttons["标记模式"].firstMatch
        XCTAssertTrue(canvasRoot.waitForExistence(timeout:20))
        XCTAssertTrue(pdfCanvas.waitForExistence(timeout:10))
        XCTAssertTrue(topAction.waitForExistence(timeout:10))
        XCTAssertTrue(bottomMode.waitForExistence(timeout:10))

        for (orientation, name) in [(UIDeviceOrientation.portrait,"reader-canvas-portrait"),
                                    (.landscapeLeft,"reader-canvas-landscape")] {
            XCUIDevice.shared.orientation = orientation
            let ready = NSPredicate { _,_ in
                let frame = app.frame
                let expected = orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
                return expected && canvasRoot.exists && pdfCanvas.exists
            }
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:ready,object:app)],timeout:10),.completed)

            let rootFrame = canvasRoot.frame
            let pdfFrame = pdfCanvas.frame
            XCTAssertEqual(pdfFrame.minX,rootFrame.minX,accuracy:1)
            XCTAssertEqual(pdfFrame.minY,rootFrame.minY,accuracy:1)
            XCTAssertEqual(pdfFrame.width,rootFrame.width,accuracy:2)
            XCTAssertEqual(pdfFrame.height,rootFrame.height,accuracy:2)
            XCTAssertEqual(rootFrame.minY,app.frame.minY,accuracy:1,"PDF and coordinate overlays reach the top system inset")
            XCTAssertEqual(rootFrame.maxY,app.frame.maxY,accuracy:1,"PDF and coordinate overlays reach the bottom system inset")
            XCTAssertGreaterThan(topAction.frame.minY,rootFrame.minY,"Top reader controls remain inside the safe area")
            XCTAssertLessThan(bottomMode.frame.maxY,rootFrame.maxY,"The bottom dock remains inside the safe area")

            let screenshot = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
            screenshot.name = name
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCUIDevice.shared.orientation = .portrait
    }
    func testResizeAcrossCapsuleThresholdAndKeepArcAnchoredWithSelectionBarOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["--gesture-audit","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch()
        let bar = app.otherElements["selection-edit-bar"].firstMatch
        let grip = app.otherElements["window-resize-grip"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout:10))
        XCTAssertTrue(grip.waitForExistence(timeout:10))
        let root = app.coordinate(withNormalizedOffset:.zero)
        let before = grip.frame
        let start = root.withOffset(CGVector(dx:before.midX,dy:before.midY))
        start.press(forDuration:0.15,thenDragTo:start.withOffset(CGVector(dx:100,dy:280)),withVelocity:.slow,thenHoldForDuration:0.2)
        XCTAssertGreaterThan(grip.frame.midY-before.midY,240,"resize continues past the compact/card threshold")
        XCTAssertTrue(bar.exists,"selection toolbar stays visible while resizing")
        let large = grip.frame
        let shrink = root.withOffset(CGVector(dx:large.midX,dy:large.midY))
        shrink.press(forDuration:0.1,thenDragTo:shrink.withOffset(CGVector(dx:-100,dy:-280)),withVelocity:.slow,thenHoldForDuration:0.1)
        XCTAssertLessThan(grip.frame.midY,large.midY-240)
        func resizeVertically(_ delta:CGFloat) {
            let frame = grip.frame
            let from = root.withOffset(CGVector(dx:frame.midX,dy:frame.midY))
            from.press(forDuration:0.1,thenDragTo:from.withOffset(CGVector(dx:0,dy:delta)),withVelocity:.slow,thenHoldForDuration:0.1)
        }
        resizeVertically(34) // 96 -> 130pt, below the layout threshold.
        let belowThreshold = grip.frame
        // Use a real 20pt pan rather than a 4pt nudge that could remain below
        // UIKit's recognition slop; assert vertical movement actually happened.
        resizeVertically(20)
        XCTAssertGreaterThan(grip.frame.midY-belowThreshold.midY,14)
        XCTAssertLessThan(abs(grip.frame.midX-belowThreshold.midX),18,"narrow capsule must cross the threshold without a width jump")
        XCTAssertTrue(bar.exists)
        resizeVertically(-54)
        let capsule = app.staticTexts["function 函数"].firstMatch
        XCTAssertTrue(capsule.exists)
        let capsuleBefore = capsule.frame
        root.withOffset(CGVector(dx:capsuleBefore.midX,dy:capsuleBefore.midY)).press(forDuration:0.1,
            thenDragTo:root.withOffset(CGVector(dx:capsuleBefore.midX+40,dy:capsuleBefore.midY+80)))
        XCTAssertGreaterThan(capsule.frame.midY,capsuleBefore.midY+50)
        XCTAssertTrue(bar.exists)
        let tool = app.buttons["荧光笔"].firstMatch
        XCTAssertTrue(tool.exists)
        let toolBefore = tool.frame
        root.withOffset(CGVector(dx:toolBefore.midX,dy:toolBefore.midY)).press(forDuration:0.1,
            thenDragTo:root.withOffset(CGVector(dx:toolBefore.midX-80,dy:toolBefore.midY-60)))
        XCTAssertLessThan(abs(toolBefore.midX-tool.frame.midX),5,"swiping over the arc does not reposition it")
        XCTAssertLessThan(abs(toolBefore.midY-tool.frame.midY),5,"swiping over the arc does not reposition it")
        XCTAssertTrue(bar.exists,"arc movement does not dismiss the selection bar")
    }
    func testReaderActionRailTogglesItsWindow() {
        let app = XCUIApplication()
        app.launchArguments = ["--reader-route-audit","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch()
        let document = app.buttons.containing(.staticText,identifier:"Reader-route-audit").firstMatch
        if document.waitForExistence(timeout:10) { document.tap() }
        let searchAction = app.buttons["全文搜索"].firstMatch
        XCTAssertTrue(searchAction.waitForExistence(timeout:20))
        searchAction.tap()
        let searchField = app.textFields["在文档中搜索"].firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout:10))

        // Move the floating search window away from the side rail so the same
        // rail action can be tapped again to close only its own window.
        let close = app.buttons["关闭窗口"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout:5))
        let root = app.coordinate(withNormalizedOffset:.zero)
        let panelInset = min(250, app.frame.width * 0.25)
        let dragStartX = close.frame.midX - panelInset
        let dragStartY = close.frame.minY + 2
        let dragStart = root.withOffset(CGVector(dx:dragStartX,dy:dragStartY))
        dragStart.press(forDuration:0.12,thenDragTo:root.withOffset(CGVector(dx:dragStartX-min(210,app.frame.width*0.35),dy:dragStartY+42)))
        XCTAssertTrue(searchAction.isHittable)
        searchAction.tap()
        let closed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:searchField)
        XCTAssertEqual(XCTWaiter.wait(for:[closed],timeout:8),.completed)
        XCTAssertTrue(app.buttons["更多"].exists,"the reader remains open after toggling search")
    }
    func testReaderFunctionsStayInDocumentInBothModes() {
        let app = XCUIApplication()
        app.launchArguments = ["--reader-route-audit","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch()
        let document = app.buttons.containing(.staticText,identifier:"Reader-route-audit").firstMatch
        if document.waitForExistence(timeout:10) { document.tap() }
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout:30))
        for writing in [false,true] {
            if writing { app.buttons["标记模式"].tap() }
            for label in ["全文搜索","目录与书签","生词本","弧形工具设置","知识图谱","词频分析","页面缩略图","设置","清空本页手写"] {
                app.buttons["更多"].tap()
                let action = app.cells.buttons[label].firstMatch
                XCTAssertTrue(action.waitForExistence(timeout:5),label)
                action.tap()
                let close = app.buttons["关闭窗口"].firstMatch
                XCTAssertTrue(close.waitForExistence(timeout:10),"window: \(label)")
                XCTAssertFalse(app.buttons["小胶囊模式"].exists,"function windows stay expanded")
                if label == "全文搜索" {
                    let search = app.textFields["在文档中搜索"].firstMatch
                    XCTAssertTrue(search.waitForExistence(timeout:5),"search field must be visible in the window")
                }
                if label == "弧形工具设置" {
                    let edit = app.buttons["arc-tools-edit"].firstMatch
                    XCTAssertTrue(edit.waitForExistence(timeout:5),"arc tool ordering remains editable")
                    XCTAssertTrue(edit.isHittable)
                    edit.tap()
                    XCTAssertEqual(edit.label,"完成编辑")
                    edit.tap()
                }
                if label == "知识图谱" {
                    let addText = app.buttons["文本框"].firstMatch
                    XCTAssertTrue(addText.waitForExistence(timeout:5),"graph must have an edit entry")
                    let ready = XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:addText)
                    XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:10),.completed)
                    addText.tap()
                    let editor = app.textViews["graph-node-editor"].firstMatch
                    XCTAssertTrue(editor.waitForExistence(timeout:5),"a new graph text box must be editable")
                    editor.tap()
                    editor.typeText("Graph note")
                    XCTAssertTrue((editor.value as? String ?? "").contains("Graph note"))
                    app.buttons["图谱操作"].firstMatch.tap()
                    let editSelected = app.buttons["编辑选中文本"].firstMatch
                    XCTAssertTrue(editSelected.waitForExistence(timeout:5),"selected text has an explicit edit action")
                    editSelected.tap()
                }
                close.tap()
                XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout:5),"must remain in document after \(label), writing=\(writing)")
            }
            if writing {
                for label in ["钢笔","毛笔","铅笔","荧光笔","橡皮"] {
                    let tool = app.buttons[label].firstMatch
                    if tool.exists && tool.isHittable { tool.tap(); if app.buttons["关闭窗口"].firstMatch.exists { app.buttons["关闭窗口"].firstMatch.tap() }; XCTAssertTrue(app.buttons["更多"].exists) }
                }
                app.buttons["回到阅读模式"].tap()
            }
        }
        app.buttons["返回文档库"].tap()
        let returned = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.buttons["更多"])
        let result = XCTWaiter.wait(for:[returned],timeout:8)
        if result != .completed {
            let hierarchy = XCTAttachment(string:app.debugDescription)
            hierarchy.name = "reader-return-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
            let screen = XCTAttachment(screenshot:app.screenshot())
            screen.name = "reader-return-screen"; screen.lifetime = .keepAlways; add(screen)
        }
        XCTAssertEqual(result,.completed,"Explicit back must return to the document library after navigation settles")
        let graphEntry = app.buttons.containing(.staticText,identifier:"知识图谱").firstMatch
        if !graphEntry.isHittable { app.scrollViews.firstMatch.swipeDown() }
        XCTAssertTrue(graphEntry.waitForExistence(timeout:10))
        graphEntry.tap()
        XCTAssertTrue(app.staticTexts["主知识图谱"].waitForExistence(timeout:10))
        let book = app.buttons.containing(.staticText,identifier:"Reader-route-audit").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout:10),"the master graph must contain the imported book")
        book.tap()
        XCTAssertTrue(app.staticTexts["知识图谱"].waitForExistence(timeout:10),"the book graph opens full screen")
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["主知识图谱"].waitForExistence(timeout:10),"closing the book graph returns to the master graph")
        app.buttons["完成"].firstMatch.tap()
    }
    func testReaderChromeToolAndWindowControlsStayInDocument() {
        let app = XCUIApplication()
        app.launchArguments = ["--reader-route-audit","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch()
        let document = app.buttons.containing(.staticText,identifier:"Reader-route-audit").firstMatch
        if document.waitForExistence(timeout:10) { document.tap() }
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout:30))
        app.buttons["进入专注模式"].tap()
        XCTAssertTrue(app.buttons["退出专注"].waitForExistence(timeout:5))
        app.buttons["退出专注"].tap()
        for zoom in ["100%","200%","400%","800%","1500%","2000%","4000%","适应宽度"] {
            app.buttons["更多"].tap(); app.cells.buttons["缩放"].firstMatch.tap(); app.cells.buttons[zoom].firstMatch.tap()
            XCTAssertTrue(app.buttons["更多"].exists)
        }
        for layout in ["横向连续","纵向连续"] {
            app.buttons["更多"].tap(); app.cells.buttons["页面排布"].firstMatch.tap(); app.cells.buttons[layout].firstMatch.tap()
            XCTAssertTrue(app.buttons["更多"].exists)
        }
        app.buttons["标记模式"].tap()
        let palette = app.scrollViews.containing(.button,identifier:"钢笔").firstMatch
        let pen = app.buttons["钢笔"].firstMatch
        for _ in 0..<4 where !pen.isHittable { palette.swipeLeft() }
        pen.tap()
        if app.buttons["收起笔刷选项"].exists { app.buttons["收起笔刷选项"].tap() }
        pen.tap()
        XCTAssertTrue(app.buttons["收起笔刷选项"].waitForExistence(timeout:5),"second tap shows inline settings")
        app.buttons["收起笔刷选项"].tap()
        for label in ["钢笔","毛笔","铅笔","荧光笔","蜡笔","套索","形状","激光笔","橡皮"] {
            let tool = app.buttons[label].firstMatch
            for _ in 0..<4 where !tool.isHittable { palette.swipeLeft() }
            XCTAssertTrue(tool.exists && tool.isHittable,label)
            tool.tap()
            if app.buttons["关闭窗口"].firstMatch.exists { app.buttons["关闭窗口"].firstMatch.tap() }
            XCTAssertTrue(app.buttons["更多"].exists)
        }
        for _ in 0..<4 where !app.buttons["打开直尺"].isHittable && !app.buttons["关闭直尺"].isHittable { palette.swipeLeft() }
        let ruler = app.buttons["打开直尺"].exists ? app.buttons["打开直尺"] : app.buttons["关闭直尺"]
        ruler.tap()
        app.buttons["撤销"].tap(); app.buttons["重做"].tap()
        app.buttons["回到阅读模式"].tap()
        app.buttons["更多"].tap(); app.cells.buttons["设置"].firstMatch.tap()
        let close = app.buttons["关闭窗口"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["小胶囊模式"].exists)
        func moveFromEdge(_ edge:String, dx:CGFloat, dy:CGFloat) {
            let before = close.frame
            let right = before.maxX, top = before.minY
            let point:CGPoint
            switch edge {
            case "top": point = CGPoint(x:right-280,y:top+8)
            case "bottom": point = CGPoint(x:right-280,y:top+592)
            case "left": point = CGPoint(x:right-552,y:top+300)
            default: point = CGPoint(x:right-8,y:top+300)
            }
            let start = app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:point.x,dy:point.y))
            let finish = start.withOffset(CGVector(dx:dx,dy:dy))
            start.press(forDuration:0.1,thenDragTo:finish)
            XCTAssertGreaterThan(abs(close.frame.minX-before.minX),10,"\(edge) edge should move the window")
        }
        moveFromEdge("top",dx:-40,dy:30)
        moveFromEdge("left",dx:20,dy:0)
        moveFromEdge("right",dx:-20,dy:0)
        moveFromEdge("bottom",dx:20,dy:0)
        close.tap()
        XCTAssertTrue(app.buttons["更多"].exists)
    }

}

extension ReaderRouteUITests {
    @objc func testHumanReadingAuditUsesLiveReaderDictionaryAndMath() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--human-reading-audit", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        let nativeDocument = app.buttons.containing(.staticText, identifier: "Human-reading-audit-text").firstMatch
        XCTAssertTrue(nativeDocument.waitForExistence(timeout: 20), "The DEBUG route imports the generated searchable PDF fixture through DocumentStore")
        nativeDocument.tap()
        let observer = app.descendants(matching: .any).matching(identifier: "human-reading-audit.snapshot").firstMatch
        let canvas = app.descendants(matching: .any).matching(identifier: "reader.pdf-canvas").firstMatch
        XCTAssertTrue(observer.waitForExistence(timeout: 15))
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        let pageIndicator = app.buttons["reader.page-indicator"].firstMatch
        XCTAssertTrue(pageIndicator.waitForExistence(timeout: 10))
        let initial = waitForAudit(observer, timeout: 20) { snapshot in
            self.point(in: snapshot, key: "wordPoints", text: "function", source: "text") != nil
                && self.point(in: snapshot, key: "wordPoints", text: "E=mc²", source: "text", edge: .start) != nil
                && self.point(in: snapshot, key: "wordPoints", text: "E=mc²", source: "text", edge: .end) != nil
                && self.point(in: snapshot, key: "linkPoints", text: "classroom", source: "link") != nil
        }
        XCTAssertNotNil(initial, "The read-only observer reports real text, line, and link geometry from the imported PDF")
        attachAuditScreenshot("synthetic-searchable-pdf-before-interaction", app: app)

        let functionPoint = point(in: initial, key: "wordPoints", text: "function", source: "text")
        XCTAssertNotNil(functionPoint)
        coordinate(for: try XCTUnwrap(functionPoint), in: app).tap()
        XCTAssertNotNil(waitForAudit(observer, timeout: 10) { ($0["selectedText"] as? String ?? "").isEmpty })
        XCTAssertFalse(app.staticTexts["word-card-title"].exists, "A single tap on ordinary text does not open a word card")

        coordinate(for: try XCTUnwrap(functionPoint), in: app).doubleTap()
        XCTAssertNotNil(waitForAudit(observer, timeout: 15) { ($0["selectedText"] as? String) == "function" })
        let wordCardTitle = app.staticTexts["word-card-title"].firstMatch
        XCTAssertTrue(wordCardTitle.waitForExistence(timeout: 10))
        XCTAssertTrue(wordCardTitle.isHittable, "The selected word card title is visible")
        XCTAssertGreaterThan(wordCardTitle.frame.minY, pageIndicator.frame.maxY,
                             "The selected word card title appears below the reader top-bar page indicator")
        let dictionaryEntry = app.descendants(matching: .any).matching(identifier: "word-card-dictionary-entry").firstMatch
        XCTAssertTrue(dictionaryEntry.waitForExistence(timeout: 15), "The selection card uses the production DictionaryService")
        attachAuditScreenshot("synthetic-searchable-pdf-double-tap-dictionary", app: app)

        let linkPoint = point(in: initial, key: "linkPoints", text: "classroom", source: "link")
        XCTAssertNotNil(linkPoint)
        coordinate(for: try XCTUnwrap(linkPoint), in: app).tap()
        XCTAssertEqual(waitForAudit(observer, timeout: 15) { ($0["page"] as? Int) == 1 }?["page"] as? Int, 1,
                       "A single tap on the actual PDF link annotation navigates to its destination")

        XCTAssertTrue(pageIndicator.waitForExistence(timeout: 10))
        pageIndicator.tap()
        let pageInput = app.textFields.firstMatch
        XCTAssertTrue(pageInput.waitForExistence(timeout: 10))
        pageInput.tap()
        pageInput.typeText("1")
        app.buttons["跳转"].tap()
        XCTAssertEqual(waitForAudit(observer, timeout: 15) { ($0["page"] as? Int) == 0 }?["page"] as? Int, 0)

        let pageZero = waitForAudit(observer, timeout: 10) { ($0["page"] as? Int) == 0 }
        let classroomWord = point(in: pageZero, key: "wordPoints", text: "classroom", source: "text")
        XCTAssertNotNil(classroomWord)
        coordinate(for: try XCTUnwrap(classroomWord), in: app).press(forDuration: 1.0)
        XCTAssertNotNil(waitForAudit(observer, timeout: 15) { ($0["selectedText"] as? String) == "classroom" },
                         "Long press on linked text selects it instead of following the link")
        attachAuditScreenshot("synthetic-searchable-pdf-long-press-linked-word", app: app)

        closeReaderWindow(in: app)
        openReaderSettings(app)
        let cacheButton = app.buttons["clear-context-translation-cache"].firstMatch
        XCTAssertTrue(cacheButton.waitForExistence(timeout: 10))
        cacheButton.tap()
        let cacheResult = app.descendants(matching: .any).matching(identifier: "context-translation-cache-result").firstMatch
        XCTAssertTrue(cacheResult.waitForExistence(timeout: 20), "Cache clearing reports its actual success or failure")
        let cacheMessage = [(cacheResult.value as? String), cacheResult.label]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let cacheAttachment = XCTAttachment(string: "human-reading-audit cache clear: \(cacheMessage)")
        cacheAttachment.lifetime = .keepAlways
        add(cacheAttachment)
        XCTAssertTrue(cacheMessage.contains("语境翻译缓存已清理"), "Cache clear should succeed on the healthy audit database; actual result: \(cacheMessage)")

        let masterSwitch = app.switches["context-reading-toggle"]
        let mathSwitch = app.switches["math-reading-toggle"]
        XCTAssertTrue(masterSwitch.waitForExistence(timeout: 10))
        XCTAssertTrue(mathSwitch.waitForExistence(timeout: 10))
        guard setSwitch(masterSwitch, to: true, in: app) else { return }
        let mathSwitchBecameEnabled = waitForEnabled(mathSwitch, to: true, timeout: 5)
        if !mathSwitchBecameEnabled {
            attachSwitchDiagnostic("math-switch-not-enabled-after-master",
                                   control: mathSwitch,
                                   expectedEnabled: true,
                                   in: app)
        }
        XCTAssertTrue(mathSwitchBecameEnabled, "The math subfeature is enabled only under the master switch")
        guard mathSwitchBecameEnabled else { return }
        guard setSwitch(mathSwitch, to: true, in: app) else { return }
        closeReaderPanel(in: app, title: "设置")

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.68)).tap()
        let clearedOldSelection = waitForAudit(observer, timeout: 10) {
            ($0["selectedText"] as? String ?? "").isEmpty
        }
        XCTAssertNotNil(clearedOldSelection,
                        "Clear the previous linked-word selection by tapping blank PDF content before selecting the formula")
        guard clearedOldSelection != nil else {
            attachAuditDiagnostics("formula-selection-not-cleared", app: app, observer: observer)
            return
        }

        let formulaSnapshot = waitForAudit(observer, timeout: 10) {
            ($0["page"] as? Int) == 0 && (($0["selectedText"] as? String) ?? "").isEmpty
        }
        XCTAssertNotNil(formulaSnapshot, "The formula geometry is read after the previous selection is cleared")
        guard formulaSnapshot != nil else {
            attachAuditDiagnostics("formula-geometry-unavailable", app: app, observer: observer)
            return
        }
        let formulaLine = point(in: formulaSnapshot, key: "wordPoints", text: "E=mc²", source: "text")
        XCTAssertNotNil(formulaLine)
        let formulaText = try XCTUnwrap(formulaLine).text
        let formulaStart = point(in: formulaSnapshot, key: "wordPoints", text: formulaText, source: "text", edge: .start)
        let formulaEnd = point(in: formulaSnapshot, key: "wordPoints", text: formulaText, source: "text", edge: .end)
        XCTAssertNotNil(formulaStart)
        XCTAssertNotNil(formulaEnd)
        coordinate(for: try XCTUnwrap(formulaStart), in: app).press(
            forDuration: 0.8,
            thenDragTo: coordinate(for: try XCTUnwrap(formulaEnd), in: app),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )
        let selectedFormula = waitForAudit(observer, timeout: 15) {
            ($0["selectedText"] as? String) == formulaText
        }
        let selectedFormulaText = selectedFormula?["selectedText"] as? String
        XCTAssertEqual(selectedFormulaText, formulaText,
                       "A long-press drag from the first to last actual PDF character selects the complete formula")
        guard selectedFormulaText == formulaText else {
            attachAuditDiagnostics("formula-selection-failed", app: app, observer: observer)
            attachReaderGestureDiagnosticsFromLibrary("formula-selection-failed", app: app)
            return
        }
        let mathSource = app.staticTexts["math-card-source"]
        let mathCardVisible = mathSource.waitForExistence(timeout: 15)
        XCTAssertTrue(mathCardVisible, "Selecting the full PDF formula routes it through MathReadingService")
        guard mathCardVisible else {
            attachAuditDiagnostics("math-card-not-created-after-formula-selection", app: app, observer: observer)
            return
        }
        XCTAssertTrue(mathSource.label.contains(formulaText))
        XCTAssertTrue(app.staticTexts["math-card-status"].label.contains("已解析"))
        let latexCopy = app.buttons["math-card-copy-latex"]
        XCTAssertTrue(latexCopy.waitForExistence(timeout: 10))
        latexCopy.tap()
        XCTAssertTrue(latexCopy.label.contains("已复制"), "The LaTeX copy action writes to UIPasteboard")
        attachAuditScreenshot("synthetic-searchable-pdf-math-card", app: app)

        let resizeGrip = app.otherElements["window-resize-grip"].firstMatch
        XCTAssertTrue(resizeGrip.waitForExistence(timeout: 10))
        let resizeRoot = app.coordinate(withNormalizedOffset: .zero)
        let gripBefore = resizeGrip.frame
        let gripStart = resizeRoot.withOffset(CGVector(dx: gripBefore.midX, dy: gripBefore.midY))
        gripStart.press(forDuration: 0.12,
                        thenDragTo: gripStart.withOffset(CGVector(dx: 0, dy: -360)),
                        withVelocity: .slow,
                        thenHoldForDuration: 0.1)
        let compactMath = app.descendants(matching: .any).matching(identifier: "compact-math-card").firstMatch
        XCTAssertTrue(compactMath.waitForExistence(timeout: 10), "The capsule exposes a compact math source and parse status")
        XCTAssertTrue(app.staticTexts["compact-math-source"].label.contains("E=mc²"))
        attachAuditScreenshot("synthetic-searchable-pdf-compact-math-summary", app: app)
        app.staticTexts["compact-math-source"].firstMatch.tap(withNumberOfTaps: 2, numberOfTouches: 1)
        XCTAssertTrue(mathSource.waitForExistence(timeout: 10))

        openReaderSettings(app)
        guard setSwitch(app.switches["math-reading-toggle"], to: false, in: app) else { return }
        XCTAssertFalse(app.staticTexts["math-card-source"].exists, "Turning math off clears its card")
        XCTAssertNotNil(waitForAudit(observer, timeout: 10) { ($0["selectedText"] as? String ?? "").isEmpty },
                         "Turning math off also clears the live PDF selection")
        guard setSwitch(app.switches["math-reading-toggle"], to: true, in: app) else { return }
        closeReaderPanel(in: app, title: "设置")

        let formulaAgainSnapshot = waitForAudit(observer, timeout: 10) { ($0["page"] as? Int) == 0 }
        let formulaAgain = point(in: formulaAgainSnapshot, key: "wordPoints", text: "E=mc²", source: "text")
        XCTAssertNotNil(formulaAgain)
        let formulaAgainText = try XCTUnwrap(formulaAgain).text
        let formulaAgainStart = point(in: formulaAgainSnapshot, key: "wordPoints", text: formulaAgainText, source: "text", edge: .start)
        let formulaAgainEnd = point(in: formulaAgainSnapshot, key: "wordPoints", text: formulaAgainText, source: "text", edge: .end)
        XCTAssertNotNil(formulaAgainStart)
        XCTAssertNotNil(formulaAgainEnd)
        coordinate(for: try XCTUnwrap(formulaAgainStart), in: app).press(
            forDuration: 0.8,
            thenDragTo: coordinate(for: try XCTUnwrap(formulaAgainEnd), in: app),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )
        let selectedFormulaAgain = waitForAudit(observer, timeout: 15) {
            ($0["selectedText"] as? String) == formulaAgainText
        }
        let selectedFormulaAgainText = selectedFormulaAgain?["selectedText"] as? String
        XCTAssertEqual(selectedFormulaAgainText, formulaAgainText,
                       "The second selection also spans the formula's first and last actual PDF characters")
        guard selectedFormulaAgainText == formulaAgainText else {
            attachAuditDiagnostics("second-formula-selection-failed", app: app, observer: observer)
            attachReaderGestureDiagnosticsFromLibrary("second-formula-selection-failed", app: app)
            return
        }
        let secondMathCardVisible = mathSource.waitForExistence(timeout: 15)
        XCTAssertTrue(secondMathCardVisible)
        guard secondMathCardVisible else {
            attachAuditDiagnostics("second-math-card-not-created", app: app, observer: observer)
            return
        }
        openReaderSettings(app)
        guard setSwitch(app.switches["context-reading-toggle"], to: false, in: app) else { return }
        let mathSwitchDisabled = waitForEnabled(mathSwitch, to: false, timeout: 5)
        if !mathSwitchDisabled {
            attachSwitchDiagnostic("math-switch-not-disabled-after-master",
                                   control: mathSwitch,
                                   expectedEnabled: false,
                                   in: app)
        }
        XCTAssertTrue(mathSwitchDisabled, "The math subfeature is disabled when the master switch is off")
        guard mathSwitchDisabled else { return }
        XCTAssertFalse(app.staticTexts["math-card-source"].exists, "Turning master off clears its math card")
        XCTAssertNotNil(waitForAudit(observer, timeout: 10) { ($0["selectedText"] as? String ?? "").isEmpty },
                         "Turning master off also clears the live PDF selection")
        guard setSwitch(app.switches["context-reading-toggle"], to: true, in: app) else { return }
        guard setSwitch(app.switches["math-reading-toggle"], to: false, in: app) else { return }
        closeReaderPanel(in: app, title: "设置")
    }

    @objc func testHumanReadingAuditUsesLiveTranslationSearchZoomLayoutAndVisionOCR() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--human-reading-audit", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        let nativeDocument = app.buttons.containing(.staticText, identifier: "Human-reading-audit-text").firstMatch
        XCTAssertTrue(nativeDocument.waitForExistence(timeout: 20), "The DEBUG route imports the generated searchable PDF fixture through DocumentStore")
        nativeDocument.tap()
        let observer = app.descendants(matching: .any).matching(identifier: "human-reading-audit.snapshot").firstMatch
        let canvas = app.descendants(matching: .any).matching(identifier: "reader.pdf-canvas").firstMatch
        XCTAssertTrue(observer.waitForExistence(timeout: 15))
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        let initial = waitForAudit(observer, timeout: 20) { snapshot in
            self.point(in: snapshot, key: "wordPoints", text: "function", source: "text") != nil
        }
        XCTAssertNotNil(initial, "The imported searchable PDF exposes real text geometry for live translation")
        attachAuditScreenshot("synthetic-searchable-pdf-translation-before-interaction", app: app)

        openReaderSettings(app)
        let masterSwitch = app.switches["context-reading-toggle"]
        let mathSwitch = app.switches["math-reading-toggle"]
        XCTAssertTrue(masterSwitch.waitForExistence(timeout: 10))
        XCTAssertTrue(mathSwitch.waitForExistence(timeout: 10))
        guard setSwitch(masterSwitch, to: true, in: app) else { return }
        XCTAssertFalse(switchValue(mathSwitch) ?? true, "The DEBUG audit fixture starts with math reading off")
        closeReaderPanel(in: app, title: "设置")

        let dictionaryEntry = app.descendants(matching: .any).matching(identifier: "word-card-dictionary-entry").firstMatch
        let currentSnapshot = waitForAudit(observer, timeout: 10) { ($0["page"] as? Int) == 0 }
        let functionAgain = point(in: currentSnapshot, key: "wordPoints", text: "function", source: "text")
        XCTAssertNotNil(functionAgain)
        coordinate(for: try XCTUnwrap(functionAgain), in: app).doubleTap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "contextual-translation-section").firstMatch
            .waitForExistence(timeout: 15), "Contextual translation uses the production ReaderView card and TranslationSession adapter")
        XCTAssertTrue(dictionaryEntry.waitForExistence(timeout: 15), "The dictionary fallback remains available")

        let candidate = app.staticTexts["contextual-translation-candidate"].firstMatch
        let preparation = app.staticTexts["contextual-translation-status-preparation"].firstMatch
        let unavailable = app.staticTexts["contextual-translation-status-unavailable"].firstMatch
        let unsupported = app.staticTexts["contextual-translation-status-unsupported"].firstMatch
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let olderThanTranslationAlignmentOS = osVersion.majorVersion < 26
            || (osVersion.majorVersion == 26 && osVersion.minorVersion < 4)
        let translationSettled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            candidate.exists || preparation.exists || unsupported.exists
                || (unavailable.exists && olderThanTranslationAlignmentOS
                    && unavailable.label.contains("iPadOS 26.4"))
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [translationSettled], timeout: 60), .completed,
                       "Record a live candidate or its actual language/system preparation state")
        let translationState = [candidate, preparation, unavailable, unsupported]
            .filter(\.exists)
            .map { "\($0.identifier)=\($0.label)" }
            .joined(separator: "\n")
        print("HUMAN_READING_AUDIT_TRANSLATION_STATE\n\(translationState)")
        let translationAttachment = XCTAttachment(string: "Production TranslationSession state (a candidate is a real system result; other states are not translation success):\n\(translationState)")
        translationAttachment.lifetime = .keepAlways
        add(translationAttachment)
        XCTAssertTrue(candidate.exists || preparation.exists || unsupported.exists
                      || (unavailable.exists && olderThanTranslationAlignmentOS
                          && unavailable.label.contains("iPadOS 26.4")),
                      "An unavailable translation state must identify the actual pre-26.4 OS requirement; state: \(translationState)")
        attachAuditScreenshot("synthetic-searchable-pdf-live-context-translation-state", app: app)

        closeReaderWindow(in: app)
        app.buttons["reader.more-menu"].tap()
        app.cells.buttons["全文搜索"].tap()
        XCTAssertTrue(app.textFields["在文档中搜索"].waitForExistence(timeout: 10))
        closeReaderPanel(in: app, title: "全文搜索")
        XCTAssertTrue(app.buttons["reader.page-indicator"].exists, "Closing search leaves the production Reader open")

        app.buttons["reader.more-menu"].tap()
        app.cells.buttons["缩放"].tap()
        app.buttons["200%"].tap()
        XCTAssertTrue(canvas.exists, "Zoom leaves the same Reader canvas installed")
        app.buttons["reader.more-menu"].tap()
        app.cells.buttons["页面排布"].tap()
        app.cells.buttons["横向连续"].tap()
        XCTAssertTrue(canvas.exists)
        app.buttons["reader.more-menu"].tap()
        app.cells.buttons["页面排布"].tap()
        app.cells.buttons["纵向连续"].tap()
        XCTAssertTrue(app.buttons["reader.page-indicator"].exists)

        app.buttons["返回文档库"].tap()
        let scanDocument = app.buttons.containing(.staticText, identifier: "Human-reading-audit-scan").firstMatch
        XCTAssertTrue(scanDocument.waitForExistence(timeout: 20))
        scanDocument.tap()
        let scanCanvas = app.descendants(matching: .any).matching(identifier: "reader.pdf-canvas").firstMatch
        XCTAssertTrue(scanCanvas.waitForExistence(timeout: 15))
        let scanSnapshot = app.descendants(matching: .any).matching(identifier: "human-reading-audit.snapshot").firstMatch
        XCTAssertTrue(scanSnapshot.waitForExistence(timeout: 10))
        let ocrReady = waitForAudit(scanSnapshot, timeout: 90) {
            self.point(in: $0, key: "wordPoints", text: "classroom", source: "ocr") != nil
        }
        XCTAssertNotNil(ocrReady, "The raster-only PDF exposes words returned by the existing Vision OCR path")
        attachAuditScreenshot("synthetic-raster-pdf-after-vision-ocr", app: app)
        let ocrPoint = point(in: ocrReady, key: "wordPoints", text: "classroom", source: "ocr")
        XCTAssertNotNil(ocrPoint)
        coordinate(for: try XCTUnwrap(ocrPoint), in: app).doubleTap()
        XCTAssertNotNil(waitForAudit(scanSnapshot, timeout: 20) { ($0["selectedText"] as? String)?.contains("classroom") == true },
                         "Double tap uses the current Vision word rectangle through ReaderCoordinator")
        attachAuditScreenshot("synthetic-raster-pdf-vision-word-selection", app: app)
    }

    private func openReaderSettings(_ app: XCUIApplication) {
        let more = app.buttons["reader.more-menu"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        if !more.isHittable {
            let close = app.buttons["关闭窗口"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: close.frame.midX - 280, dy: close.frame.minY + 6))
            start.press(forDuration: 0.12,
                        thenDragTo: start.withOffset(CGVector(dx: -320, dy: 500)),
                        withVelocity: .slow,
                        thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(more.isHittable)
        more.tap()
        let settings = app.cells.buttons["设置"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
    }

    private func closeReaderWindow(in app: XCUIApplication) {
        let close = app.buttons["关闭窗口"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
    }

    private func closeReaderPanel(in app: XCUIApplication, title: String) {
        let panel = app.descendants(matching: .any)
            .matching(identifier: "reader-panel.\(title)")
            .firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "The \(title) panel must be open before closing it")
        let close = panel.buttons["关闭窗口"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Close the \(title) panel, leaving any word or math card intact")
        close.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: panel)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed)
    }

    private func setSwitch(_ control: XCUIElement,
                           to enabled: Bool,
                           in app: XCUIApplication) -> Bool {
        guard control.waitForExistence(timeout: 10) else {
            attachSwitchDiagnostic("switch-not-found",
                                   control: control,
                                   expectedEnabled: enabled,
                                   in: app)
            XCTFail("Switch \(control.identifier) did not appear")
            return false
        }

        let settingsPanel = app.descendants(matching: .any)
            .matching(identifier: "reader-panel.设置")
            .firstMatch
        guard settingsPanel.waitForExistence(timeout: 5) else {
            attachSwitchDiagnostic("settings-panel-not-found",
                                   control: control,
                                   expectedEnabled: enabled,
                                   in: app)
            XCTFail("The reader settings panel is required to change \(control.identifier)")
            return false
        }

        let scrollViews = settingsPanel.descendants(matching: .scrollView).allElementsBoundByIndex
        for _ in 0..<6 where !control.isHittable {
            guard let scrollView = scrollViews.first(where: { $0.exists && $0.isHittable }) else { break }
            if control.frame.midY < scrollView.frame.minY {
                scrollView.swipeDown()
            } else {
                scrollView.swipeUp()
            }
        }
        guard control.isHittable else {
            attachSwitchDiagnostic("switch-not-hittable",
                                   control: control,
                                   expectedEnabled: enabled,
                                   in: app)
            XCTFail("Switch \(control.identifier) is not hittable in the reader settings panel")
            return false
        }
        guard waitForEnabled(control, to: true, timeout: 5) else {
            attachSwitchDiagnostic("switch-disabled",
                                   control: control,
                                   expectedEnabled: enabled,
                                   in: app)
            XCTFail("Switch \(control.identifier) is disabled and cannot be changed")
            return false
        }

        guard let currentValue = switchValue(control) else {
            attachSwitchDiagnostic("switch-value-unreadable",
                                   control: control,
                                   expectedEnabled: enabled,
                                   in: app)
            XCTFail("Switch \(control.identifier) has no readable accessibility value")
            return false
        }
        if currentValue == enabled { return true }

        // SwiftUI exposes this Toggle across its Form row; tap the visible switch at the trailing edge.
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        guard waitForSwitchValue(control, to: enabled, timeout: 5) else {
            attachSwitchDiagnostic("switch-value-did-not-change",
                                   control: control,
                                   expectedEnabled: enabled,
                                   in: app)
            XCTFail("Switch \(control.identifier) did not reach accessibility value \(enabled)")
            return false
        }
        return true
    }

    private func switchValue(_ control: XCUIElement) -> Bool? {
        if let value = control.value as? String {
            switch value.lowercased() {
            case "1", "on", "true", "yes":
                return true
            case "0", "off", "false", "no":
                return false
            default:
                return nil
            }
        }
        if let value = control.value as? NSNumber { return value.boolValue }
        return nil
    }

    private func waitForSwitchValue(_ control: XCUIElement,
                                    to enabled: Bool,
                                    timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.switchValue(control) == enabled
        }, object: control)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForEnabled(_ control: XCUIElement,
                                to enabled: Bool,
                                timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            control.isEnabled == enabled
        }, object: control)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attachSwitchDiagnostic(_ name: String,
                                        control: XCUIElement,
                                        expectedEnabled: Bool,
                                        in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "\(name)-screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let details = """
        switch: \(control.identifier)
        expected value: \(expectedEnabled)
        actual AX value: \(String(describing: control.value))
        enabled: \(control.isEnabled)
        hittable: \(control.isHittable)
        frame: \(String(describing: control.frame))

        \(app.debugDescription)
        """
        let hierarchy = XCTAttachment(string: details)
        hierarchy.name = "\(name)-accessibility-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func attachAuditDiagnostics(_ name: String,
                                        app: XCUIApplication,
                                        observer: XCUIElement) {
        attachAuditScreenshot(name, app: app)
        let snapshot = auditJSON(observer)
        let details = """
        Audit snapshot: \(String(describing: snapshot))
        Selected text: \(String(describing: snapshot?["selectedText"]))

        \(app.debugDescription)
        """
        let attachment = XCTAttachment(string: details)
        attachment.name = "\(name)-audit-and-accessibility-hierarchy"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachReaderGestureDiagnosticsFromLibrary(_ name: String, app: XCUIApplication) {
        let returnToLibrary = app.buttons["返回文档库"].firstMatch
        guard returnToLibrary.waitForExistence(timeout: 3), returnToLibrary.isHittable else {
            attachDiagnosticsUIFallback(name, stage: "return-to-library-unavailable", app: app)
            return
        }
        returnToLibrary.tap()

        let moreSettings = app.buttons["更多设置"].firstMatch
        guard moreSettings.waitForExistence(timeout: 4), moreSettings.isHittable else {
            attachDiagnosticsUIFallback(name, stage: "library-more-settings-unavailable", app: app)
            return
        }
        moreSettings.tap()

        let diagnostics = app.buttons["诊断日志"].firstMatch
        guard diagnostics.waitForExistence(timeout: 4), diagnostics.isHittable else {
            attachDiagnosticsUIFallback(name, stage: "diagnostics-menu-item-unavailable", app: app)
            return
        }
        diagnostics.tap()

        let diagnosticsTitle = app.navigationBars["诊断日志"].firstMatch
        guard diagnosticsTitle.waitForExistence(timeout: 4) else {
            attachDiagnosticsUIFallback(name, stage: "diagnostics-page-unavailable", app: app)
            return
        }

        let logPredicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR label MATCHES %@",
            "press.began",
            "(?s).*[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{3}.*"
        )
        let logLabels = app.staticTexts.matching(logPredicate).allElementsBoundByIndex
            .map(\.label)
            .filter { !$0.isEmpty }
        guard !logLabels.isEmpty else {
            attachDiagnosticsUIFallback(name, stage: "timestamped-log-static-text-unavailable", app: app)
            return
        }

        let gestureLines = logLabels.joined(separator: "\n")
            .split(whereSeparator: \.isNewline)
            .filter {
                $0.localizedCaseInsensitiveContains("press.began") ||
                $0.localizedCaseInsensitiveContains("press.end") ||
                $0.localizedCaseInsensitiveContains("handle.drag")
            }
        guard !gestureLines.isEmpty else {
            attachDiagnosticsUIFallback(name, stage: "gesture-events-not-found-in-diagnostics", app: app)
            return
        }

        let tail = gestureLines.suffix(24).map { String($0.suffix(512)) }.joined(separator: "\n")
        let attachment = XCTAttachment(
            string: "Matched log text elements: \(logLabels.count)\nGesture event tail:\n\(tail)"
        )
        attachment.name = "\(name)-reader-gesture-log-tail"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachDiagnosticsUIFallback(_ name: String, stage: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "\(name)-diagnostics-ui-fallback-screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(string: "stage: \(stage)\n\n\(app.debugDescription)")
        hierarchy.name = "\(name)-diagnostics-ui-accessibility-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func auditJSON(_ observer: XCUIElement) -> [String: Any]? {
        let value = (observer.value as? String) ?? observer.label
        guard let data = value.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func waitForAudit(_ observer: XCUIElement,
                              timeout: TimeInterval,
                              condition: @escaping ([String: Any]) -> Bool) -> [String: Any]? {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let snapshot = self.auditJSON(observer) else { return false }
            return condition(snapshot)
        }, object: observer)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else { return nil }
        return auditJSON(observer)
    }

    private func point(in snapshot: [String: Any]?,
                       key: String,
                       text: String,
                       source: String,
                       edge: HumanAuditPointEdge? = nil) -> HumanAuditPoint? {
        let coordinateKeys: (x: String, y: String) = edge?.coordinateKeys ?? (x: "x", y: "y")
        guard let snapshot,
              let entries = snapshot[key] as? [[String: Any]],
              let match = entries.first(where: {
                  $0["text"] as? String == text && $0["source"] as? String == source
              }),
              let x = match[coordinateKeys.x] as? NSNumber,
              let y = match[coordinateKeys.y] as? NSNumber else { return nil }
        return HumanAuditPoint(text: text, source: source, x: CGFloat(truncating: x), y: CGFloat(truncating: y))
    }

    private func coordinate(for point: HumanAuditPoint, in app: XCUIApplication) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y))
    }

    private func attachAuditScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct HumanAuditPoint {
    let text: String
    let source: String
    let x: CGFloat
    let y: CGFloat
}

private enum HumanAuditPointEdge {
    case start
    case end

    var coordinateKeys: (x: String, y: String) {
        switch self {
        case .start: return ("startX", "startY")
        case .end: return ("endX", "endY")
        }
    }
}
