import XCTest
import Security
@testable import HomeCortex

final class PhysicalSelfProvisioningTests: XCTestCase {
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<900 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ChatFailure.timeout
    }
    @MainActor func testRealAdoptionAndFreshInAppEnrollment() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires unlocked, authenticated physical iPhone and production backend.")
        #else
        let caller = AppRuntime.connection
        let original = AppRuntime.embodiment
        caller.setForeground(true)
        caller.connect()
        try await wait { caller.displayedState == .connected }
        let callerIdentity = try XCTUnwrap(caller.credential)
        let originalIdentity = try XCTUnwrap(original.connection.credential)
        await original.refreshConfiguration(caller: caller)
        XCTAssertNotNil(original.serverConfiguration)
        XCTAssertEqual(original.embodimentID, originalIdentity.embodimentID)
        original.setForeground(false) // Pause camera while the acceptance fixture uses the same hardware.
        let preferences = UserDefaults(suiteName: "HomeCortex.PhysicalSelfProvisioning")!
        let store = KeychainCredentialStore(service: "com.jiankuang.homecortex.self-provision-acceptance", purpose: .device)
        let phone = EmbodimentController(store: store, preferences: preferences)
        phone.setForeground(true)
        if phone.connection.credential == nil {
            await phone.loadSetup(caller: caller)
            XCTAssertNotNil(phone.setupOptions)
            phone.selectedAgentID = try XCTUnwrap(phone.setupOptions?.eligible_agents.first?.agent_id)
            phone.selectedCamera = true
            phone.onboarding = .confirming
            await phone.confirmSetup(caller: caller)
        }
        guard let issued = phone.connection.credential else {
            original.setForeground(true)
            return XCTFail(phone.setupMessage ?? phone.error?.localizedDescription ?? "Enrollment failed")
        }
        do {
            if !phone.runtimeEnabled { phone.enableRuntime() }
            try await wait { phone.isOnline }
            XCTAssertNotEqual(issued.keyTag, callerIdentity.keyTag)
            XCTAssertNotEqual(issued.clientID, callerIdentity.clientID)
            XCTAssertNotEqual(issued.certificatePEM, callerIdentity.certificatePEM)
            let material = try store.identity(for: issued)
            var key: SecKey?
            XCTAssertEqual(SecIdentityCopyPrivateKey(material.identity, &key), errSecSuccess)
            XCTAssertEqual((SecKeyCopyAttributes(try XCTUnwrap(key)) as? [String: Any])?[kSecAttrTokenID as String] as? String, kSecAttrTokenIDSecureEnclave as String)
            let body = try XCTUnwrap(issued.embodimentID)
            await phone.refreshConfiguration(caller: caller)
            XCTAssertEqual(phone.serverConfiguration?.agent_id, phone.selectedAgentID)
            let (transport, session, _) = try caller.embodimentSetupAccess()
            let chatAccess = try caller.conversationAccess()
            let document = try await chatAccess.transport.selectOrCreate(sessionID: chatAccess.sessionID)
            _ = try await chatAccess.transport.setActive(id: document.id, embodimentID: body, sessionID: chatAccess.sessionID)
            try await chatAccess.transport.stream(id: document.id, content: "我是谁", sessionID: chatAccess.sessionID) { _ in }
            let answered = try await chatAccess.transport.history(id: document.id, sessionID: chatAccess.sessionID)
            XCTAssertFalse(answered.messages.last?.content.isEmpty ?? true)
            let captures = phone.vision.captures
            try await chatAccess.transport.stream(id: document.id, content: "你现在能看到什么？", sessionID: chatAccess.sessionID) { _ in }
            XCTAssertGreaterThan(phone.vision.captures, captures)
            XCTAssertNotNil(phone.vision.lastEvidenceID)
            await phone.changeCamera(false, caller: caller)
            XCTAssertFalse(phone.cameraSelected)
            XCTAssertEqual(phone.embodimentID, body)
            await phone.changeCamera(true, caller: caller)
            try await wait { phone.isOnline && phone.connection.session?.effectiveCapabilities == ["vision.observe"] }
            await phone.disableRuntime()
            XCTAssertNotNil(try store.load())
            let relaunched = EmbodimentController(store: store, preferences: preferences)
            XCTAssertEqual(relaunched.embodimentID, body)
            XCTAssertFalse(relaunched.runtimeEnabled)
            relaunched.enableRuntime()
            try await wait { relaunched.isOnline }
            XCTAssertEqual(relaunched.connection.credential?.clientID, issued.clientID)
            await relaunched.disableRuntime()
            _ = try await chatAccess.transport.setActive(id: document.id, embodimentID: originalIdentity.embodimentID, sessionID: chatAccess.sessionID)
            _ = try await transport.send("/embodiments/" + body + "/remove", sessionID: session, method: "POST", body: Data("{}".utf8))
            try store.removeEmbodiment()
            preferences.removePersistentDomain(forName: "HomeCortex.PhysicalSelfProvisioning")
            XCTAssertEqual(caller.credential?.keyTag, callerIdentity.keyTag)
            XCTAssertEqual(original.connection.credential?.keyTag, originalIdentity.keyTag)
            original.setForeground(true)
        } catch {
            await phone.disableRuntime()
            original.setForeground(true)
            throw error
        }
        #endif
    }
    @MainActor func testRealBackendRestartRecovery() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the production restart window on a physical phone.")
        #else
        let caller = AppRuntime.connection
        let phone = AppRuntime.embodiment
        caller.setForeground(true); phone.setForeground(true)
        caller.connect(); phone.enableRuntime()
        try await wait { caller.displayedState == .connected && phone.isOnline }
        let originalCaller = try XCTUnwrap(caller.credential)
        let originalPhone = try XCTUnwrap(phone.connection.credential)
        let oldCallerSession = caller.session?.sessionID
        let oldDeviceSession = phone.connection.session?.sessionID
        print("PHYSICAL BACKEND RESTART WINDOW READY")
        try await wait { caller.session?.sessionID != oldCallerSession && phone.connection.session?.sessionID != oldDeviceSession && caller.displayedState == .connected && phone.isOnline }
        XCTAssertEqual(caller.credential?.keyTag, originalCaller.keyTag)
        XCTAssertEqual(phone.connection.credential?.keyTag, originalPhone.keyTag)
        XCTAssertEqual(phone.embodimentID, originalPhone.embodimentID)
        await phone.refreshConfiguration(caller: caller)
        XCTAssertNotNil(phone.serverConfiguration)
        #endif
    }
    @MainActor func testRealWiFiRecovery() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a manual Wi-Fi off/on on the physical phone.")
        #else
        let caller = AppRuntime.connection
        let phone = AppRuntime.embodiment
        caller.setForeground(true); phone.setForeground(true)
        caller.connect(); phone.enableRuntime()
        try await wait { caller.displayedState == .connected && phone.isOnline }
        let originalCaller = try XCTUnwrap(caller.credential)
        let originalPhone = try XCTUnwrap(phone.connection.credential)
        print("PHYSICAL WIFI RECOVERY WINDOW READY")
        try await wait { caller.displayedState != .connected && !phone.isOnline }
        try await wait { caller.displayedState == .connected && phone.isOnline }
        XCTAssertEqual(caller.credential?.keyTag, originalCaller.keyTag)
        XCTAssertEqual(phone.connection.credential?.keyTag, originalPhone.keyTag)
        XCTAssertEqual(phone.embodimentID, originalPhone.embodimentID)
        #endif
    }

}
