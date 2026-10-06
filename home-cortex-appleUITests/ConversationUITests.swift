import XCTest

final class ConversationUITests: XCTestCase {
    @MainActor
    func testProvisionedChatScreenRelaunchAndSessionInterruption() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real provisioned identity and backend are required; no mock conversation UI.")
        #else
        let app = XCUIApplication()
        app.launch()
        let state = app.staticTexts["chat.connection"]
        XCTAssertTrue(state.waitForExistence(timeout: 45))
        let connected = NSPredicate(format: "label == %@", "Connected")
        expectation(for: connected, evaluatedWith: state)
        waitForExpectations(timeout: 45)
        XCTAssertTrue(app.textFields["chat.input"].exists || app.textViews["chat.input"].exists)
        app.buttons["Connection"].tap()
        XCTAssertTrue(app.staticTexts["connection.provisioning"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["connection.provisioning"].label, "Provisioned")
        XCTAssertEqual(app.staticTexts["connection.embodiment"].label, "Not enabled")
        let disconnect = app.buttons["Disconnect"]
        if !disconnect.isHittable { app.swipeUp() }
        disconnect.tap()
        app.buttons["Done"].tap()
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        app.terminate()
        app.launch()
        XCTAssertTrue(state.waitForExistence(timeout: 45))
        expectation(for: connected, evaluatedWith: state)
        waitForExpectations(timeout: 45)
        XCTAssertFalse(app.buttons["connection.provision"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        #endif
    }
}
