import XCTest

final class PhysicalEmbodimentUITests: XCTestCase {
    @MainActor func testExistingPhoneUsesProductionScreenAcrossForceQuit() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the provisioned physical iPhone.")
        #else
        let app = XCUIApplication()
        for _ in 0..<2 {
            app.launch()
            XCTAssertTrue(app.buttons["chat.manage-embodiment"].waitForExistence(timeout: 30))
            app.buttons["chat.manage-embodiment"].tap()
            XCTAssertTrue(app.staticTexts["embodiment.identity"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.switches["Embodiment Enabled"].exists)
            XCTAssertTrue(app.switches["Camera"].exists)
            XCTAssertTrue(app.staticTexts["老管家"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["Continue"].exists)
            XCTAssertFalse(app.buttons["Import DEVICE invitation"].isHittable)
            app.terminate()
        }
        app.launch()
        #endif
    }
}
