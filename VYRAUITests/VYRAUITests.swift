import XCTest

final class VYRAUITests: XCTestCase {

    /// Existence waits in UI tests: 5s proved too tight for the
    /// CI simulator under load — testTabSwitching failed once at
    /// 16.6s total and passed once at 89.0s total on the same
    /// commit (runs 45732692783 / 45732726567), purely on how
    /// long the app took to present each tab. The assertions are
    /// unchanged; only the patience is realistic for the runner.
    private static let uiTimeout: TimeInterval = 30

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesAndHomeIsShown() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["動画を保存する"].waitForExistence(timeout: Self.uiTimeout))
        XCTAssertTrue(app.staticTexts["VYRA"].exists)
    }

    func testTabSwitching() throws {
        let app = XCUIApplication()
        app.launch()
        let libraryTab = app.buttons["tab-library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: Self.uiTimeout))
        libraryTab.tap()
        XCTAssertTrue(app.staticTexts["保存済みファイルはありません"].waitForExistence(timeout: Self.uiTimeout))
        app.buttons["tab-settings"].tap()
        XCTAssertTrue(app.staticTexts["アプリ情報"].waitForExistence(timeout: Self.uiTimeout))
        app.buttons["tab-home"].tap()
        XCTAssertTrue(app.staticTexts["動画を保存する"].waitForExistence(timeout: Self.uiTimeout))
    }

    func testURLInputAcceptsText() throws {
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["url-input"]
        XCTAssertTrue(field.waitForExistence(timeout: Self.uiTimeout))
        field.tap()
        field.typeText("https://example.com/video")
        XCTAssertEqual(field.value as? String, "https://example.com/video")
    }
}
