//___FILEHEADER___

import XCTest

final class SmartTableUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    /// 2.0: the login keyboard has «Готово», so the code keyboard no longer hides «Подтвердить».
    @MainActor
    func testLoginKeyboardHasDoneButton() throws {
        let app = XCUIApplication()
        app.launch()
        let login = app.textFields["login.username"]
        if !login.waitForExistence(timeout: 8) {
            app.tabBars.buttons["Настройки"].tap()
            app.buttons["Войти в аккаунт"].tap()
            XCTAssertTrue(app.buttons["login.savedData"].waitForExistence(timeout: 8))
            XCTAssertTrue(login.waitForExistence(timeout: 8))
        }
        login.tap()
        let done = app.toolbars.buttons["Готово"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        done.tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 2))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
