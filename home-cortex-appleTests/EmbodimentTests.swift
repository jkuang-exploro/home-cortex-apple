import XCTest
import Security
@testable import HomeCortex

@MainActor
final class EmbodimentTests: XCTestCase {
    static let body = "embodiment:opaque-phone-test"
    static func invitation() throws -> Data {
        let original = String(decoding: try ProvisioningTests.invitation(), as: UTF8.self)
        return Data(original.replacingOccurrences(of: "CALLER", with: "DEVICE")
            .replacingOccurrences(of: "\"embodiment_id\":null", with: "\"embodiment_id\":\"\(body)\"").utf8)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ChatFailure.timeout
    }
    private func device() throws -> (EmbodimentController, ProvisioningMemoryStore, RoleTransport) {
        let store = try ProvisioningMemoryStore()
        store.metadata = CredentialMetadata(clientID: "client:device-test", keyTag: Data("independent-device-key".utf8),
            configuration: store.config, certificatePEM: "MOCK-device", caChainPEM: "MOCK-chain", trustedCAPEM: "test-only",
            expiresAt: Date().addingTimeInterval(3600), embodimentID: Self.body)
        store.participation = true
        let transport = RoleTransport(clientID: "client:device-test", embodimentID: Self.body)
        let controller = EmbodimentController(store: store, factory: { _, _, metadata in
            if let metadata { XCTAssertEqual(metadata.purpose, .device) }
            return transport
        })
        return (controller, store, transport)
    }

    func testNoAutomaticEnableAndStrictInvitationAuthority() async throws {
        let store = try ProvisioningMemoryStore()
        let device = EmbodimentController(store: store, factory: { _, _, _ in RoleTransport() })
        device.setForeground(true)
        XCTAssertFalse(device.isEnabled)
        XCTAssertFalse(device.runtimeEnabled)
        XCTAssertEqual(store.prepareCount, 0)
        XCTAssertThrowsError(try ProvisioningInvitation(data: Self.invitation(), configuration: store.config))
        XCTAssertThrowsError(try ProvisioningInvitation(data: ProvisioningTests.invitation(), configuration: store.config, purpose: .device))
        XCTAssertNoThrow(try ProvisioningInvitation(data: Self.invitation(), configuration: store.config, purpose: .device))
        let expanded = String(decoding: try Self.invitation(), as: UTF8.self).replacingOccurrences(of: "session", with: "publish")
        await device.provision(Data(expanded.utf8), profile: try SoftwareLoginTests.profile())
        XCTAssertEqual(store.prepareCount, 0)
        XCTAssertFalse(store.participation)
        XCTAssertFalse(device.isEnabled)
    }
    func testExplicitDeviceProvisioningStoresBodyAndEmptyManifest() async throws {
        let store = try ProvisioningMemoryStore()
        let transport = RoleTransport(clientID: "client:device-test", embodimentID: Self.body)
        let device = EmbodimentController(store: store, factory: { _, _, _ in transport })
        device.setForeground(true)
        await device.provision(try Self.invitation(), profile: try SoftwareLoginTests.profile())
        try await wait { device.isOnline }
        XCTAssertEqual(store.prepareCount, 1)
        XCTAssertEqual(device.embodimentID, Self.body)
        XCTAssertEqual(store.metadata?.purpose, .device)
        XCTAssertTrue(store.participation)
        XCTAssertTrue(device.connection.session?.effectiveCapabilities.isEmpty == true)
        XCTAssertThrowsError(try device.connection.conversationAccess())
        await device.disableRuntime()
    }
    func testDisableRelaunchForegroundNetworkRestartAndReplacementRetainIdentity() async throws {
        let (device, store, transport) = try device()
        device.setForeground(true)
        try await wait { device.isOnline }
        let original = try XCTUnwrap(store.metadata)
        let firstSession = device.connection.session?.sessionID
        device.setForeground(false)
        XCTAssertFalse(device.isOnline)
        XCTAssertTrue(device.isEnabled)
        device.setForeground(true)
        try await wait { device.isOnline }
        XCTAssertNotEqual(firstSession, device.connection.session?.sessionID)
        await transport.setMode(.offline)
        try await wait { device.connection.state == .reconnecting }
        XCTAssertTrue(device.isEnabled)
        XCTAssertFalse(device.isOnline)
        await transport.setMode(.available)
        try await wait { device.isOnline }
        await transport.setMode(.restart)
        try await wait { device.connection.state == .reconnecting }
        try await wait { device.isOnline }
        await transport.setMode(.replaced)
        try await wait { device.connection.state == .failed(.replaced) }
        device.setForeground(false); device.setForeground(true)
        XCTAssertFalse(device.isOnline)
        await device.disableRuntime()
        XCTAssertFalse(store.participation)
        XCTAssertEqual(store.metadata?.keyTag, original.keyTag)
        XCTAssertEqual(device.embodimentID, original.embodimentID)
        let relaunched = EmbodimentController(store: store, factory: { _, _, _ in transport })
        relaunched.setForeground(true)
        XCTAssertTrue(relaunched.isEnabled)
        XCTAssertFalse(relaunched.isOnline)
        XCTAssertFalse(relaunched.runtimeEnabled)
        await transport.setMode(.available)
        relaunched.enableRuntime()
        try await wait { relaunched.isOnline }
        XCTAssertEqual(relaunched.embodimentID, original.embodimentID)
        await relaunched.disableRuntime()
    }
    func testSeparateSessionsAndDeviceRevocationLeaveCallerActive() async throws {
        let (device, deviceStore, deviceTransport) = try device()
        let callerStore = try ProvisioningMemoryStore()
        callerStore.metadata = try V1ProtocolTests.metadata()
        let callerTransport = RoleTransport()
        let caller = ConnectionController(store: callerStore, factory: { _, _, _ in callerTransport })
        caller.setForeground(true)
        device.setForeground(true)
        try await wait { caller.displayedState == .connected && device.isOnline }
        XCTAssertNotEqual(caller.session?.sessionID, device.connection.session?.sessionID)
        XCTAssertNotEqual(caller.credential?.clientID, device.connection.credential?.clientID)
        XCTAssertNotEqual(caller.credential?.keyTag, device.connection.credential?.keyTag)
        await deviceTransport.setMode(.revoked)
        try await wait { deviceStore.metadata?.authenticationRejected == true }
        XCTAssertTrue(device.isEnabled)
        XCTAssertFalse(device.isOnline)
        XCTAssertEqual(caller.displayedState, .connected)
        XCTAssertFalse(callerStore.metadata?.authenticationRejected == true)
        let deviceBody = device.embodimentID
        await callerTransport.setMode(.revoked)
        try await wait { callerStore.metadata?.authenticationRejected == true }
        XCTAssertEqual(device.embodimentID, deviceBody)
        await device.disableRuntime()
        await caller.disconnect()
    }
    func testRoleNamespacesHaveIndependentKeysCredentialsAndRevocationFlags() throws {
        let service = "HomeCortex.DualPrincipalTests." + UUID().uuidString
        let caller = KeychainCredentialStore(service: service)
        let device = KeychainCredentialStore(service: service, purpose: .device)
        defer { try? caller.forget(); try? device.forget() }
        let config = try V1ProtocolTests.config()
        let ca = try SoftwareLoginTests.profile().caPEM
        let callerInvitation = try ProvisioningInvitation(data: ProvisioningTests.invitation(), configuration: config)
        let deviceInvitation = try ProvisioningInvitation(data: Self.invitation(), configuration: config, purpose: .device)
        let callerKey = try caller.prepare(invitation: callerInvitation, configuration: config, caPEM: ca)
        let deviceKey = try device.prepare(invitation: deviceInvitation, configuration: config, caPEM: ca)
        XCTAssertNotEqual(callerKey.keyTag, deviceKey.keyTag)
        XCTAssertNotEqual(callerKey.csrPEM, deviceKey.csrPEM)
        var callerMetadata = try V1ProtocolTests.metadata()
        callerMetadata = CredentialMetadata(clientID: callerMetadata.clientID, keyTag: callerKey.keyTag, configuration: config,
            certificatePEM: "test-only", caChainPEM: ca, trustedCAPEM: ca, expiresAt: Date().addingTimeInterval(3600))
        let deviceMetadata = CredentialMetadata(clientID: "client:device-test", keyTag: deviceKey.keyTag, configuration: config,
            certificatePEM: "test-only-device", caChainPEM: ca, trustedCAPEM: ca, expiresAt: Date().addingTimeInterval(3600),
            authenticationRejected: true, embodimentID: Self.body)
        try caller.save(callerMetadata)
        try device.save(deviceMetadata)
        XCTAssertThrowsError(try caller.save(deviceMetadata))
        XCTAssertThrowsError(try device.save(callerMetadata))
        let relabeledDevice = CredentialMetadata(clientID: deviceMetadata.clientID, keyTag: callerKey.keyTag, configuration: config,
            certificatePEM: deviceMetadata.certificatePEM, caChainPEM: ca, trustedCAPEM: ca,
            expiresAt: Date().addingTimeInterval(3600), embodimentID: Self.body)
        XCTAssertThrowsError(try device.validateStoredIdentity(relabeledDevice))
        XCTAssertFalse(try XCTUnwrap(caller.load()).authenticationRejected)
        XCTAssertEqual(try device.load()?.embodimentID, Self.body)
        try device.forget()
        XCTAssertEqual(try caller.load()?.clientID, callerMetadata.clientID)
        // Old CALLER JSON without embodimentID remains readable.
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(callerMetadata)) as! [String: Any]
        encoded.removeValue(forKey: "embodimentID")
        XCTAssertEqual(try JSONDecoder().decode(CredentialMetadata.self, from: JSONSerialization.data(withJSONObject: encoded)).purpose, .caller)
    }
    func testCredentialRoleAndCorrelatedBodyCannotBeInterchanged() throws {
        let store = try ProvisioningMemoryStore()
        store.metadata = CredentialMetadata(clientID: "client:device-test", keyTag: Data("key".utf8), configuration: store.config,
            certificatePEM: "mock", caChainPEM: "mock", trustedCAPEM: "test-only", expiresAt: Date().addingTimeInterval(3600), embodimentID: Self.body)
        let caller = ConnectionController(store: store)
        XCTAssertEqual(caller.state, .failed(.invalidCertificate))
        let request = V1Request(operation: "session.register", clientID: "client:device-test", version: "1", embodimentID: Self.body)
        let wrong = try V1ProtocolTests.softwareResponse(request: request)
        XCTAssertThrowsError(try V1Response(.object(wrong), request: request))
    }
}

private actor RoleTransport: V1Transport {
    enum Mode { case available, offline, restart, replaced, revoked }
    let clientID: String
    let embodimentID: String?
    var mode = Mode.available
    var registrations = 0
    init(clientID: String = "client:apple-test", embodimentID: String? = nil) {
        self.clientID = clientID; self.embodimentID = embodimentID
    }
    func setMode(_ mode: Mode) { self.mode = mode }
    func send(path: String, body: JSONValue?) async throws -> JSONValue {
        if mode == .offline { throw ClientFailure.transport }
        if path == "/client-interface/v1/discovery" { return try V1ProtocolTests.fixture("discovery") }
        if path == "/client-interface/v1/enroll" {
            return .object(["client_id": .string(clientID), "embodiment_id": embodimentID.map(JSONValue.string) ?? .null,
                "certificate_pem": .string("MOCK-device-certificate"), "ca_chain_pem": .string("MOCK-chain"),
                "server_endpoint": .string("https://home-cortex-0:8443"), "protocol_versions": .array([.string("1.0")]),
                "credential_expires_at": .string(V1Time.format(Date().addingTimeInterval(3600))),
                "grants": .array([.object(["embodiment_id": embodimentID.map(JSONValue.string) ?? .null, "verb": .string("session"), "capability": .null])])])
        }
        guard case .object(let raw) = body else { throw ClientFailure.invalidResponse }
        let op = try raw.field("operation").string()
        let target = try raw.field("target").object(required: ["embodiment_id", "session_id"])
        guard target["embodiment_id"] == (embodimentID.map(JSONValue.string) ?? .null) else { throw ClientFailure.invalidResponse }
        if mode == .revoked { throw denied("PERMISSION_DENIED", "certificate_revoked") }
        if mode == .restart && op == "session.heartbeat" { mode = .available; throw denied("CONFLICT", "stale_session") }
        if op == "session.register" {
            registrations += 1
            let arguments = try raw.field("arguments").object(required: ["identity", "manifest"])
            XCTAssertEqual(try arguments.field("manifest").object(required: ["revision", "capabilities"])["capabilities"], .array([]))
        }
        let sid = target["session_id"] == .null ? nil : try target.field("session_id").string()
        let request = V1Request(operation: op, sessionID: sid, clientID: clientID, version: "1", embodimentID: embodimentID)
        let state: SessionState = mode == .replaced ? .replaced : (op == "session.disconnect" ? .disconnected : .active)
        var response = try V1ProtocolTests.softwareResponse(request: request, state: state,
            sessionID: "runtime-session:\(clientID):\(registrations)")
        response["request_id"] = raw["request_id"]
        response["target"] = raw["target"]
        var view = try response.field("result").object(required: ["client_id", "embodiment_id", "session_id", "state", "connected_at", "last_seen_at", "server_time", "lease_expires_at", "heartbeat_interval_ms", "lease_duration_ms", "manifest_revision", "effective_capabilities"])
        view["client_id"] = .string(clientID)
        view["embodiment_id"] = embodimentID.map(JSONValue.string) ?? .null
        response["result"] = .object(view)
        return .object(response)
    }
    private func denied(_ code: String, _ detail: String) -> ClientFailure {
        .remote(try! V1Error(.object(["code": .string(code), "detail_code": .string(detail), "message": .string("ignored"),
            "retryable": .bool(false), "retry_after_ms": .null])))
    }
}
