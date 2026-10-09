import XCTest
@testable import HomeCortex

@MainActor final class EmbodimentSetupTests: XCTestCase {
    func testServerOptionsAndSupportedSensorMapping() throws {
        let options = try JSONDecoder().decode(EmbodimentSetupOptions.self, from: Data(#"{"eligible_agents":[{"agent_id":"agent:other","display_name":"Another Agent"}],"allowed_capabilities":["vision.observe"]}"#.utf8))
        XCTAssertEqual(options.eligible_agents.first?.id, "agent:other")
        XCTAssertTrue(options.cameraAllowed)
        XCTAssertEqual(EmbodimentSetupAttempt.capabilities(camera: true), ["vision.observe"])
        XCTAssertEqual(EmbodimentSetupAttempt.capabilities(camera: false), [])
    }
    func testAttemptPersistenceRetainsIdAndSelectionWithoutTokenOrKey() throws {
        let attempt = EmbodimentSetupAttempt(agentID: "agent:other", camera: true,
            clientID: "client:caller", origin: URL(string: "https://example.test:8443")!)
        let data = try JSONEncoder().encode(attempt)
        let restored = try JSONDecoder().decode(EmbodimentSetupAttempt.self, from: data)
        XCTAssertEqual(attempt, restored)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("token"))
        XCTAssertNotNil(UUID(uuidString: restored.enrollment_id))
        let prefs = UserDefaults(suiteName: "EmbodimentSetupTests")!
        defer { prefs.removePersistentDomain(forName: "EmbodimentSetupTests") }
        prefs.set(data, forKey: "HomeCortex.embodiment.setup-attempt")
        let controller = EmbodimentController(store: try ProvisioningMemoryStore(), preferences: prefs)
        XCTAssertTrue(controller.hasSavedSetup)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.canStartNewAttempt)
        controller.startNewAttempt()
        XCTAssertTrue(controller.hasSavedSetup) // Ambiguous failure must retain the recovery ID.
    }
    func testOnboardingAndFailedEnrollmentStayOffline() async throws {
        XCTAssertTrue(EmbodimentOnboardingState.requestingPermissions.busy)
        XCTAssertTrue(EmbodimentOnboardingState.enrolling.busy)
        XCTAssertFalse(EmbodimentOnboardingState.failed("Unavailable").busy)
        let controller = EmbodimentController(store: try ProvisioningMemoryStore())
        let caller = ConnectionController(store: try ProvisioningMemoryStore(), automaticallyConnect: false)
        await controller.loadSetup(caller: caller)
        guard case .failed = controller.onboarding else { return XCTFail("Disconnected CALLER must fail setup") }
        XCTAssertFalse(controller.runtimeEnabled)
        XCTAssertFalse(controller.isOnline)
        XCTAssertNil(controller.connection.credential)
    }
}
