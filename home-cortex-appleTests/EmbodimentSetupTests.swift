import XCTest
@testable import HomeCortex

@MainActor final class EmbodimentSetupTests: XCTestCase {
    func testOnlyStructuredEnrollmentExpiryPermitsReplacingSavedAttempt() throws {
        let legitimate = Data(#"{"error":{"code":"PERMISSION_DENIED","message":"Localized wording","details":{"detail_code":"enrollment_expired"}}}"#.utf8)
        let expiry = EmbodimentSetupFailure.response(status: 403, path: "/embodiments/enrollments", data: legitimate, mimeType: "application/json")
        XCTAssertEqual(expiry.recovery, .expired)
        let prose = Data(#"{"error":{"code":"PERMISSION_DENIED","message":"enrollment_expired Setup expired.","details":{}}}"#.utf8)
        for data in [prose, Data("enrollment_expired".utf8), Data(#"{"error":{"code":"PERMISSION_DENIED","details":{"detail_code":"enrollment_expired","detail_code":"unknown"}}}"#.utf8)] {
            XCTAssertEqual(EmbodimentSetupFailure.response(status: 403, path: "/embodiments/enrollments", data: data, mimeType: "application/json").recovery, .resume)
        }
        for (status, path, mime) in [(403, "/embodiments/embodiment:phone", "application/json"), (409, "/embodiments/enrollments", "application/json"), (403, "/embodiments/enrollments", "text/plain")] {
            XCTAssertEqual(EmbodimentSetupFailure.response(status: status, path: path, data: legitimate, mimeType: mime).recovery, .resume)
        }
    }
    func testRuntimeReconciliationDoesNotInvalidateUnchangedCalibration() async throws {
        let store = try ProvisioningMemoryStore()
        store.metadata = CredentialMetadata(clientID: "client:device-test", keyTag: Data("test-key".utf8),
            configuration: store.config, certificatePEM: "MOCK", caChainPEM: "MOCK", trustedCAPEM: "test-only",
            expiresAt: Date().addingTimeInterval(3600), visionObserveGranted: true, embodimentID: "embodiment:test")
        store.participation = true
        let name = UUID().uuidString
        let prefs = UserDefaults(suiteName: name)!
        defer { prefs.removePersistentDomain(forName: name) }
        let configuration = EmbodimentConfiguration(embodiment_id: "embodiment:test", agent_id: "agent:test", agent_display_name: "Test",
            capabilities: ["vision.observe"], diagnostics: ["orientation.local", "localization.local"])
        try EmbodimentPreferences(storage: prefs).save(configuration, .configuration, body: "embodiment:test")
        let controller = EmbodimentController(store: store, factory: { _, _, _ in ProvisioningTransport() }, preferences: prefs)
        controller.reconcileRuntimes()
        let before = controller.localization.visualCalibration.generation
        controller.reconcileRuntimes()
        XCTAssertEqual(controller.localization.visualCalibration.generation, before)
        controller.setForeground(false)
        let stopped = controller.localization.visualCalibration.generation
        XCTAssertGreaterThan(stopped, before)
        controller.reconcileRuntimes()
        XCTAssertEqual(controller.localization.visualCalibration.generation, stopped)
        let caller = ConnectionController(store: try ProvisioningMemoryStore(), automaticallyConnect: false)
        await controller.changeCamera(false, caller: caller)
        XCTAssertEqual(controller.serverConfiguration?.cameraEnabled, true)
        XCTAssertFalse(controller.cameraSelected)
        XCTAssertFalse(controller.vision.configured)
        await controller.changeMotion(false, caller: caller)
        await controller.changeLocalization(false, caller: caller)
        let relaunched = EmbodimentController(store: store, preferences: prefs)
        XCTAssertFalse(relaunched.cameraSelected)
        XCTAssertFalse(relaunched.vision.configured)
        XCTAssertFalse(relaunched.motionSelected)
        XCTAssertFalse(relaunched.localizationSelected)
        await controller.disableRuntime()
    }
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
