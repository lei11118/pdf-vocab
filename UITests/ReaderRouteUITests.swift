import XCTest

final class ReaderRouteUITests:XCTestCase {
    func testReaderFunctionsStayInDocumentInBothModes() {
        let app = XCUIApplication()
        app.launchArguments = ["--reader-route-audit","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout:30))
        for writing in [false,true] {
            if writing { app.buttons["标记模式"].tap() }
            for label in ["全文搜索","目录与书签","生词本","全文翻译与校对","知识图谱","词频分析","页面缩略图","设置","清空本页手写"] {
                app.buttons["更多"].tap()
                let action = app.buttons[label].firstMatch
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
                    if tool.exists && tool.isHittable { tool.tap(); XCTAssertTrue(app.buttons["更多"].exists) }
                }
                app.buttons["回到阅读模式"].tap()
            }
        }
        app.buttons["返回文档库"].tap()
        XCTAssertFalse(app.buttons["更多"].exists)
    }
}
