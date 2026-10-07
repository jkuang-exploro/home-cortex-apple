import XCTest
import Security
@testable import HomeCortex

final class PhysicalEmbodimentTests: XCTestCase {
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ChatFailure.timeout
    }
    @MainActor
    func testRealCallerChatBeforeEmbodimentOptIn() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the provisioned physical phone before DEVICE enablement.")
        #else
        guard !AppRuntime.embodiment.isEnabled else { throw XCTSkip("Phone is already explicitly enabled.") }
        XCTAssertFalse(AppRuntime.embodiment.runtimeEnabled)
        let caller = AppRuntime.connection
        caller.setForeground(true)
        if caller.displayedState != .connected { caller.connect() }
        try await wait { caller.displayedState == .connected }
        XCTAssertNil(caller.credential?.embodimentID)
        let chat = AppRuntime.chat
        chat.load()
        try await wait { chat.state != .loading }
        XCTAssertEqual(chat.state, .ready)
        chat.draft = "我是谁"
        XCTAssertTrue(chat.canSend)
        chat.send()
        try await wait { chat.state != .sending }
        XCTAssertEqual(chat.state, .ready)
        let answer = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(answer.role, .assistant)
        XCTAssertEqual(answer.state, .complete)
        XCTAssertFalse(answer.content.isEmpty)
        XCTAssertFalse(AppRuntime.embodiment.isEnabled)
        #endif
    }
    @MainActor
    func testRealDualPrincipalsEmptyManifestAndIndependentDisable() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the phone after explicit DEVICE invitation import.")
        #else
        let caller = AppRuntime.connection
        let device = AppRuntime.embodiment
        guard device.isEnabled && device.runtimeEnabled else {
            throw XCTSkip("Enable the phone explicitly and import its DEVICE invitation first.")
        }
        let callerCredential = try XCTUnwrap(caller.credential)
        let deviceCredential = try XCTUnwrap(device.connection.credential)
        XCTAssertEqual(callerCredential.purpose, .caller)
        XCTAssertNil(callerCredential.embodimentID)
        XCTAssertEqual(deviceCredential.purpose, .device)
        let body = try XCTUnwrap(deviceCredential.embodimentID)
        XCTAssertNotEqual(deviceCredential.keyTag, callerCredential.keyTag)
        XCTAssertNotEqual(deviceCredential.clientID, callerCredential.clientID)
        XCTAssertNotEqual(deviceCredential.certificatePEM, callerCredential.certificatePEM)
        for (purpose, metadata) in [(CredentialPurpose.caller, callerCredential), (.device, deviceCredential)] {
            let store = KeychainCredentialStore(purpose: purpose)
            let material = try store.identity(for: metadata)
            var key: SecKey?
            XCTAssertEqual(SecIdentityCopyPrivateKey(material.identity, &key), errSecSuccess)
            let attributes = SecKeyCopyAttributes(try XCTUnwrap(key)) as? [String: Any]
            XCTAssertEqual(attributes?[kSecAttrTokenID as String] as? String, kSecAttrTokenIDSecureEnclave as String)
        }
        caller.setForeground(true); device.setForeground(true)
        if caller.displayedState != .connected { caller.connect() }
        try await wait { caller.displayedState == .connected && device.isOnline }
        let oldCallerSession = caller.session?.sessionID
        let oldDeviceSession = device.connection.session?.sessionID
        XCTAssertNotEqual(oldCallerSession, oldDeviceSession)
        XCTAssertEqual(device.connection.session?.embodimentID, body)
        XCTAssertTrue(Set(device.connection.session?.effectiveCapabilities ?? []).isSubset(of: deviceCredential.visionObserveGranted == true ? ["vision.observe"] : []))
        XCTAssertThrowsError(try device.connection.conversationAccess())
        let forbidden = try URLSessionConversationTransport(configuration: deviceCredential.configuration,
            caPEM: deviceCredential.trustedCAPEM, identity: KeychainCredentialStore(purpose: .device).identity(for: deviceCredential))
        do {
            _ = try await forbidden.selectOrCreate(sessionID: XCTUnwrap(oldDeviceSession))
            XCTFail("DEVICE must not access household chat")
        } catch { XCTAssertEqual(error as? ChatFailure, .authentication) }
        let access = try caller.conversationAccess()
        let document = try await access.transport.selectOrCreate(sessionID: access.sessionID)
        await device.disableRuntime()
        XCTAssertFalse(device.isOnline)
        XCTAssertTrue(device.isEnabled)
        XCTAssertEqual(caller.displayedState, .connected)
        _ = try await access.transport.history(id: document.id, sessionID: access.sessionID)
        let reopened = try XCTUnwrap(KeychainCredentialStore(purpose: .device).load())
        XCTAssertEqual(reopened.embodimentID, body)
        XCTAssertEqual(reopened.keyTag, deviceCredential.keyTag)
        XCTAssertFalse(try KeychainCredentialStore(purpose: .device).runtimeEnabled())
        device.enableRuntime()
        try await wait { device.isOnline }
        XCTAssertNotEqual(device.connection.session?.sessionID, oldDeviceSession)
        device.setForeground(false)
        XCTAssertFalse(device.isOnline)
        XCTAssertTrue(device.isEnabled)
        device.setForeground(true)
        try await wait { device.isOnline }
        XCTAssertEqual(device.embodimentID, body)
        XCTAssertEqual(device.connection.credential?.clientID, deviceCredential.clientID)
        XCTAssertEqual(caller.credential?.clientID, callerCredential.clientID)
        #endif
    }
}
