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
