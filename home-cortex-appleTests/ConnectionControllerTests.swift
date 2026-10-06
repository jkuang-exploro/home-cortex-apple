import XCTest
@testable import HomeCortex

@MainActor
final class ConnectionControllerTests: XCTestCase {
    private func controller() throws -> (ConnectionController, MemoryStore, MockV1Transport) {
        let store = try MemoryStore()
        let transport = MockV1Transport()
        return (ConnectionController(store: store, factory: { _, _, _ in transport }), store, transport)
    }
    private func wait(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Expected state before timeout")
    }

    func testConnectedRequiresActiveAuthenticatedSessionAndRenewsLease() async throws {
        let (model, _, transport) = try controller()
        XCTAssertEqual(model.state, .disconnected)
        XCTAssertNil(model.session)
        model.connect()
        try await wait { model.displayedState == .connected }
        XCTAssertEqual(model.discovery, .compatible)
        XCTAssertEqual(model.session?.state, .active)
        XCTAssertTrue(model.session?.effectiveCapabilities.isEmpty == true)
        try await Task.sleep(for: .milliseconds(1200))
        let beats = await transport.heartbeats
        XCTAssertGreaterThanOrEqual(beats, 1)
        await model.disconnect()
        XCTAssertEqual(model.displayedState, .disconnected)
        XCTAssertNil(model.lease)
    }

    func testBackgroundClearsAuthorityAndForegroundRegistersNewSession() async throws {
        let (model, _, _) = try controller()
        model.connect()
        try await wait { model.state == .connected }
        let old = model.session?.sessionID
        model.setForeground(false)
        XCTAssertEqual(model.displayedState, .disconnected)
        XCTAssertNil(model.session)
        model.setForeground(true)
        try await wait { model.state == .connected }
        XCTAssertNotEqual(model.session?.sessionID, old)
        await model.disconnect()
    }

    func testNetworkLossClearsConnectedThenRecovers() async throws {
        let (model, _, transport) = try controller()
        model.connect()
        try await wait { model.state == .connected }
        await transport.setMode(.offline)
        try await wait { model.state == .reconnecting }
        XCTAssertNil(model.lease)
        XCTAssertNotEqual(model.displayedState, .connected)
        await transport.setMode(.available)
        try await wait { model.state == .connected }
        await model.disconnect()
    }

    func testStalledHeartbeatCannotKeepConnectedBeyondLease() async throws {
        let (model, _, transport) = try controller()
        model.connect()
        try await wait { model.state == .connected }
        await transport.setMode(.stalledHeartbeat)
        try await wait { model.state == .reconnecting }
        XCTAssertNotEqual(model.displayedState, .connected)
        XCTAssertNil(model.lease)
        await model.disconnect()
    }

    func testBackendRestartRejectsFenceThenReregisters() async throws {
        let (model, _, transport) = try controller()
        model.connect()
        try await wait { model.state == .connected }
        let old = model.session?.sessionID
        await transport.setMode(.restartOnce)
        try await wait { model.state == .reconnecting }
        try await wait { model.state == .connected }
        XCTAssertNotEqual(model.session?.sessionID, old)
        await model.disconnect()
    }

    func testRevocationIsPersistedAndCannotReconnectOnRelaunch() async throws {
        let (model, store, transport) = try controller()
        model.connect()
        try await wait { model.state == .connected }
        await transport.setMode(.revoked)
        try await wait { if case .failed = model.state { return true }; return false }
        XCTAssertTrue(store.metadata?.authenticationRejected == true)
        XCTAssertNil(model.lease)
        model.setForeground(false)
        model.setForeground(true)
        XCTAssertNotEqual(model.displayedState, .connected)
        if case .failed = model.state { } else { XCTFail("Revocation must remain visible after backgrounding") }
        let relaunched = ConnectionController(store: store, factory: { _, _, _ in transport })
        relaunched.setForeground(true)
        XCTAssertEqual(relaunched.state, .failed(.authenticationRequired))
        relaunched.connect()
        XCTAssertNotEqual(relaunched.displayedState, .connected)
        await model.disconnect()
    }

    func testReplacedSessionStopsAutomaticRetry() async throws {
        let (model, _, transport) = try controller()
        model.connect()
        try await wait { model.state == .connected }
        await transport.setMode(.replaced)
        try await wait { model.state == .failed(.replaced) }
        XCTAssertNil(model.session)
        model.setForeground(false)
        model.setForeground(true)
        XCTAssertNotEqual(model.state, .connected)
        await model.disconnect()
    }

    func testDisconnectFencesLateRegistrationResponse() async throws {
        let (model, _, transport) = try controller()
        await transport.setMode(.slowRegister)
        model.connect()
        try await wait { model.state == .registering }
        await model.disconnect()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.state, .disconnected)
        XCTAssertNil(model.session)
    }

    func testForgettingCredentialFencesLateRegistrationResponse() async throws {
        let (model, store, transport) = try controller()
        await transport.setMode(.slowRegister)
        model.connect()
        try await wait { model.state == .registering }
        await model.forgetCredential()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(store.metadata)
        XCTAssertNil(model.credential)
        XCTAssertNil(model.session)
        XCTAssertEqual(model.state, .unconfigured)
        model.connect()
        XCTAssertEqual(model.state, .unconfigured)
    }

    func testUnprovisionedDiscoveryIsNotConnected() async throws {
        let (model, store, _) = try controller()
        store.metadata = nil
        let transport = MockV1Transport()
        let fresh = ConnectionController(store: store, factory: { _, _, _ in transport })
        await fresh.discover()
        XCTAssertEqual(fresh.discovery, .compatible)
        XCTAssertEqual(fresh.state, .unconfigured)
        XCTAssertNil(fresh.session)
        await model.disconnect()
    }
}

@MainActor
private final class MemoryStore: CredentialStoring {
    var metadata: CredentialMetadata?
    let config: ClientConfiguration
    init() throws { metadata = try V1ProtocolTests.metadata(); config = try V1ProtocolTests.config() }
    func load() throws -> CredentialMetadata? { metadata }
    func save(_ metadata: CredentialMetadata) throws { self.metadata = metadata }
    func identity(for metadata: CredentialMetadata) throws -> IdentityMaterial { throw ClientFailure.invalidCertificate }
    func prepare(invitation: ProvisioningInvitation, configuration: ClientConfiguration, caPEM: String) throws -> PendingEnrollment { throw ClientFailure.keyGeneration }
    func finish(bundle: EnrollmentBundle, pending: PendingEnrollment) throws -> CredentialMetadata { throw ClientFailure.invalidCertificate }
    func trustedCA() throws -> String? { "test-only" }
    func storeTrustedCA(_ pem: String) throws { }
    func configuration() throws -> ClientConfiguration? { config }
    func storeConfiguration(_ configuration: ClientConfiguration) throws { }
    func forget() throws { metadata = nil }
}

private actor MockV1Transport: V1Transport {
    enum Mode { case available, offline, revoked, restartOnce, replaced, slowRegister, stalledHeartbeat }
    var mode = Mode.available
    var heartbeats = 0
    var registrations = 0
    func setMode(_ mode: Mode) { self.mode = mode }

    func send(path: String, body: JSONValue?) async throws -> JSONValue {
        if mode == .offline { throw ClientFailure.transport }
        if path == "/client-interface/v1/discovery" { return try V1ProtocolTests.fixture("discovery") }
        guard case .object(let raw) = body else { throw ClientFailure.invalidResponse }
        let operation = try raw.field("operation").string()
        if mode == .revoked { throw ClientFailure.remote(try failure(code: "PERMISSION_DENIED", detail: "certificate_revoked", retryable: false)) }
        if mode == .restartOnce, operation == "session.heartbeat" {
            mode = .available
            throw ClientFailure.remote(try failure(code: "CONFLICT", detail: "stale_session", retryable: false))
        }
        if operation == "session.register" {
            registrations += 1
            if mode == .slowRegister { try? await Task.sleep(for: .milliseconds(300)) }
        }
        if operation == "session.heartbeat" {
            heartbeats += 1
            if mode == .stalledHeartbeat { try? await Task.sleep(for: .seconds(4)) }
        }
        let target = try raw.field("target").object(required: ["embodiment_id", "session_id"])
        let targetID = target["session_id"] == .null ? nil : try target.field("session_id").string()
        let generated = V1Request(operation: operation, sessionID: targetID, clientID: "client:apple-test", version: "0.1.0")
        var response = try V1ProtocolTests.softwareResponse(request: generated, state: mode == .replaced ? .replaced : .active, sessionID: "runtime-session:apple-test:\(registrations)")
        response["request_id"] = raw["request_id"]
        return .object(response)
    }
    private func failure(code: String, detail: String, retryable: Bool) throws -> V1Error {
        var o = try V1ProtocolTests.fixture("error").object(required: ["code", "detail_code", "message", "retryable", "retry_after_ms"])
        o["code"] = .string(code); o["detail_code"] = .string(detail); o["retryable"] = .bool(retryable)
        return try V1Error(.object(o))
    }
}
