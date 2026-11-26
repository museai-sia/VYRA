import XCTest

final class VYRAUITests: XCTestCase {

    /// Existence waits in UI tests: the CI simulator under load
    /// takes most of a minute just to launch the app and present
    /// its first screen (passing runs show 60-100s launches), so
    /// waits must cover a cold launch, not in-app navigation.
    /// Each test also waits for the app to reach the foreground
    /// before looking for elements. The assertions are unchanged;
    /// only the patience is realistic for the runner.
    private static let uiTimeout: TimeInterval = 60

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesAndHomeIsShown() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.uiTimeout))
        XCTAssertTrue(app.staticTexts["動画を保存する"].waitForExistence(timeout: Self.uiTimeout))
        XCTAssertTrue(app.staticTexts["VYRA"].exists)
    }

    func testTabSwitching() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.uiTimeout))
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
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.uiTimeout))
        let field = app.textFields["url-input"]
        XCTAssertTrue(field.waitForExistence(timeout: Self.uiTimeout))
        field.tap()
        field.typeText("https://example.com/video")
        XCTAssertEqual(field.value as? String, "https://example.com/video")
    }
}
