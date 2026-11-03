import XCTest

final class ReaderRouteUITests:XCTestCase {
    func testReaderFunctionsStayInDocumentInBothModes() {
        let app = XCUIApplication()
        app.launchArguments = ["--reader-route-audit","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout:30))
        for writing in [false,true] {
            if writing { app.buttons["标记模式"].tap() }
            for label in ["全文搜索","目录与书签","生词本","自定义手写工具","知识图谱","词频分析","页面缩略图","设置","清空本页手写"] {
                app.buttons["更多"].tap()
                let action = app.cells.buttons[label].firstMatch
                XCTAssertTrue(action.waitForExistence(timeout:5),label)
                action.tap()
                let close = app.buttons["关闭窗口"].firstMatch
                XCTAssertTrue(close.waitForExistence(timeout:10),"window: \(label)")
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
    }
    func testReaderChromeToolAndWindowControlsStayInDocument() {
        let app = XCUIApplication()
        app.launchArguments = ["--reader-route-audit","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch()
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
        let compact = app.buttons["小胶囊模式"].firstMatch
        XCTAssertTrue(compact.waitForExistence(timeout:5)); compact.tap()
        app.staticTexts["设置"].firstMatch.doubleTap()
        XCTAssertTrue(app.buttons["小胶囊模式"].firstMatch.waitForExistence(timeout:5))
        app.buttons["关闭窗口"].firstMatch.tap()
        XCTAssertTrue(app.buttons["更多"].exists)
    }

}
