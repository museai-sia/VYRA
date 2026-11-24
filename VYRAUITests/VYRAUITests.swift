import XCTest

final class VYRAUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesAndHomeIsShown() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["動画を保存する"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["VYRA"].exists)
    }

    func testTabSwitching() throws {
        let app = XCUIApplication()
        app.launch()
        let libraryTab = app.buttons["tab-library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 5))
        libraryTab.tap()
        XCTAssertTrue(app.staticTexts["保存済みファイルはありません"].waitForExistence(timeout: 5))
        app.buttons["tab-settings"].tap()
        XCTAssertTrue(app.staticTexts["アプリ情報"].waitForExistence(timeout: 5))
        app.buttons["tab-home"].tap()
        XCTAssertTrue(app.staticTexts["動画を保存する"].waitForExistence(timeout: 5))
    }

    func testURLInputAcceptsText() throws {
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["url-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://example.com/video")
        XCTAssertEqual(field.value as? String, "https://example.com/video")
    }
}
