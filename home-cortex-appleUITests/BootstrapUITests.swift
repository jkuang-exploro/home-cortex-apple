import XCTest

final class BootstrapUITests: XCTestCase {
    @MainActor
    func testBootstrapLaunchAndRelaunch() {
        let app = XCUIApplication()
        app.launch()
        assertBootstrap(in: app)

        app.terminate()
        app.launch()
        assertBootstrap(in: app)
    }

    @MainActor
    private func assertBootstrap(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["bootstrap.title"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["bootstrap.running"].exists)
        XCTAssertEqual(app.staticTexts["bootstrap.integration"].label, "Not configured yet")
        XCTAssertEqual(app.staticTexts["bootstrap.version"].label, "Version 0.1.0 (build 1)")
        XCTAssertTrue(["iPhone", "iPad"].contains(app.staticTexts["bootstrap.platform"].label))
    }
}
