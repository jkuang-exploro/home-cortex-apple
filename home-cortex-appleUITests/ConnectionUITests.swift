import XCTest

final class ConnectionUITests: XCTestCase {
    @MainActor
    func testFreshClientIsUnprovisionedAndNeverClaimsAnActiveSession() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-unprovisioned"]
        app.launch()
        assertUnprovisioned(app)
        app.terminate()
        app.launch()
        assertUnprovisioned(app)
    }

    @MainActor
    private func assertUnprovisioned(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["login.submit"].isEnabled)
        app.buttons["login.advanced"].tap()
        XCTAssertTrue(app.staticTexts["connection.title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["connection.state"].label, "Not Provisioned")
        XCTAssertEqual(app.staticTexts["connection.protocol"].label, "1.0")
        XCTAssertEqual(app.staticTexts["connection.client"].label, "Not provisioned")
        XCTAssertEqual(app.staticTexts["connection.session"].label, "Not active")
        XCTAssertEqual(app.staticTexts["connection.embodiment"].label, "Not enabled")
        XCTAssertEqual(app.staticTexts["connection.discovery"].label, "Not checked")
        let provision = app.buttons["connection.provision"]
        if !provision.isHittable { app.swipeUp() }
        XCTAssertTrue(provision.exists)
        XCTAssertFalse(provision.isEnabled)
        let enable = app.buttons["embodiment.enable"]
        if !enable.isHittable { app.swipeUp() }
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Not enabled"].exists)
        XCTAssertFalse(app.buttons["embodiment.disable"].exists)
        enable.tap()
        XCTAssertTrue(app.staticTexts["embodiment.setup"].waitForExistence(timeout: 5))
        app.buttons["embodiment.import"].tap()
        let files = app.otherElements["Browse View (Picker)"]
        XCTAssertTrue(files.waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["embodiment.import"].waitForExistence(timeout: 5))
        app.navigationBars["Enable Embodiment"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["embodiment.enable"].exists)
        app.buttons["Done"].tap()
    }
}
