import XCTest
@testable import HomeCortex

@MainActor
final class ProvisioningTests: XCTestCase {
    func testMalformedExpiredAndPrivilegeExpandedInvitationCreateNoPersistentState() async throws {
        for input in [Data("{}".utf8), try Self.invitation(expired: true), try Self.invitation(physical: true)] {
            let store = try ProvisioningMemoryStore()
            let transport = ProvisioningTransport()
            let model = ConnectionController(store: store, factory: { _, _, _ in transport })
            await model.provision(invitationData: input)
            XCTAssertEqual(store.prepareCount, 0)
            XCTAssertNil(store.metadata)
            XCTAssertNil(model.credential)
            if case .failed = model.provisioning { } else { XCTFail("Invalid invitation must fail visibly") }
            XCTAssertNotEqual(model.displayedState, .connected)
        }
        XCTAssertThrowsError(try ProvisioningInvitation(data: Self.invitation(expired: true), configuration: V1ProtocolTests.config())) {
            XCTAssertEqual($0 as? ClientFailure, .invitationExpired)
        }
    }

    func testProvisioningPhasesStoreIssuedIdentityAndRecognizeRelaunch() async throws {
        let store = try ProvisioningMemoryStore()
        let transport = ProvisioningTransport()
        let model = ConnectionController(store: store, factory: { _, _, _ in transport })
        let work = Task { await model.provision(invitationData: try! Self.invitation()) }
        try await wait { model.provisioning == .enrolling }
        XCTAssertEqual(store.phases, [.generatingKey, .generatingCSR])
        XCTAssertNil(model.credential)
        XCTAssertNotEqual(model.displayedState, .connected)
        await work.value
        XCTAssertEqual(model.provisioning, .provisioned)
        XCTAssertEqual(store.metadata?.clientID, "client:apple-test")
        let relaunched = ConnectionController(store: store, factory: { _, _, _ in transport })
        XCTAssertEqual(relaunched.provisioning, .provisioned)
        XCTAssertEqual(relaunched.credential?.clientID, model.credential?.clientID)
        await model.disconnect()
    }

    func testEnrollmentPolicyFailureAndExpandedResponseStoreNoCredential() async throws {
        for mode in [ProvisioningTransport.Mode.denied, .expanded] {
            let store = try ProvisioningMemoryStore()
            let transport = ProvisioningTransport(mode: mode)
            let model = ConnectionController(store: store, factory: { _, _, _ in transport })
            await model.provision(invitationData: try Self.invitation())
            XCTAssertNil(model.credential)
            XCTAssertNil(store.metadata)
            if case .failed = model.provisioning { } else { XCTFail("Enrollment failure must remain visible") }
        }
    }

    func testInterruptedEnrollmentKeepsExactCSRAndFencesLateSuccess() async throws {
        let store = try ProvisioningMemoryStore()
        let transport = ProvisioningTransport()
        let model = ConnectionController(store: store, factory: { _, _, _ in transport })
        let invitation = try Self.invitation()
        let work = Task { await model.provision(invitationData: invitation) }
        try await wait { model.provisioning == .enrolling }
        let original = store.pending
        model.setForeground(false)
        await work.value
        XCTAssertNil(store.metadata)
        XCTAssertNil(model.credential)
        XCTAssertEqual(model.provisioning, .notProvisioned)
        model.setForeground(true)
        await model.provision(invitationData: invitation)
        XCTAssertEqual(store.prepareCount, 1, "Uncertain enrollment must reuse the pending key/CSR")
        XCTAssertEqual(original?.csrPEM, store.lastFinished?.csrPEM)
        XCTAssertEqual(model.provisioning, .provisioned)
        await model.disconnect()
    }

    func testMissingStoredKeyCannotClaimProvisionedFromRememberedID() throws {
        let store = try ProvisioningMemoryStore()
        store.metadata = try V1ProtocolTests.metadata()
        store.identityMissing = true
        let model = ConnectionController(store: store, factory: { _, _, _ in ProvisioningTransport() })
        XCTAssertEqual(model.provisioning, .failed(.invalidCertificate))
        XCTAssertNotEqual(model.displayedState, .connected)
    }

    func testStorageFailurePreservesPendingCSRAndNeverClaimsProvisioned() async throws {
        let store = try ProvisioningMemoryStore()
        store.storageFails = true
        let model = ConnectionController(store: store, factory: { _, _, _ in ProvisioningTransport() })
        let invitation = try Self.invitation()
        await model.provision(invitationData: invitation)
        XCTAssertEqual(model.provisioning, .failed(.secureStorage(-34018)))
        XCTAssertNil(model.credential)
        XCTAssertNil(store.metadata)
        let pending = try XCTUnwrap(store.pending)
        store.storageFails = false
        await model.provision(invitationData: invitation)
        XCTAssertEqual(model.provisioning, .provisioned)
        XCTAssertEqual(store.prepareCount, 1)
        XCTAssertEqual(store.lastFinished?.csrPEM, pending.csrPEM)
        await model.disconnect()
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected provisioning phase")
    }

    static func invitation(expired: Bool = false, physical: Bool = false) throws -> Data {
        try JSONEncoder().encode(JSONValue.object([
            "invitation_id": .string("invitation:apple-test"), "token": .string(String(repeating: "a", count: 43)),
            "expires_at": .string(V1Time.format(Date().addingTimeInterval(expired ? -10 : 600))),
            "server_endpoint": .string("https://home-cortex-0:8443"), "purpose": .string("CALLER"),
            "embodiment_id": physical ? .string("embodiment:unexpected") : .null,
            "grants": .array([.object(["embodiment_id": .null, "verb": .string("session"), "capability": .null])])
        ]))
    }
}

@MainActor
private final class ProvisioningMemoryStore: CredentialStoring {
    var metadata: CredentialMetadata?
    var pending: PendingEnrollment?
    var lastFinished: PendingEnrollment?
    var prepareCount = 0
    var identityMissing = false
    var storageFails = false
    var phases: [ProvisioningState] = []
    let config: ClientConfiguration
    init() throws { config = try V1ProtocolTests.config() }
    func load() throws -> CredentialMetadata? { metadata }
    func save(_ metadata: CredentialMetadata) throws { self.metadata = metadata }
    func validateStoredIdentity(_ metadata: CredentialMetadata) throws {
        if identityMissing { throw ClientFailure.invalidCertificate }
        try metadata.validate()
    }
    func identity(for metadata: CredentialMetadata) throws -> IdentityMaterial { throw ClientFailure.invalidCertificate }
    func prepare(invitation: ProvisioningInvitation, configuration: ClientConfiguration, caPEM: String) throws -> PendingEnrollment {
        if let pending { return pending }
        prepareCount += 1
        let pending = PendingEnrollment(invitationID: invitation.invitationID, keyTag: Data("mock-key-reference".utf8),
            csrPEM: "MOCK-CSR-EXACT-RETRY", configuration: configuration, trustedCAPEM: caPEM)
        self.pending = pending
        return pending
    }
    func prepare(invitation: ProvisioningInvitation, configuration: ClientConfiguration, caPEM: String, progress: (ProvisioningState) -> Void) throws -> PendingEnrollment {
        for phase in [ProvisioningState.generatingKey, .generatingCSR] { phases.append(phase); progress(phase) }
        return try prepare(invitation: invitation, configuration: configuration, caPEM: caPEM)
    }
    func finish(bundle: EnrollmentBundle, pending: PendingEnrollment) throws -> CredentialMetadata {
        if storageFails { throw ClientFailure.secureStorage(-34018) }
        lastFinished = pending
        let metadata = CredentialMetadata(clientID: bundle.clientID, keyTag: pending.keyTag, configuration: pending.configuration,
            certificatePEM: bundle.certificatePEM, caChainPEM: bundle.caChainPEM, trustedCAPEM: pending.trustedCAPEM, expiresAt: bundle.expiresAt)
        self.metadata = metadata
        self.pending = nil
        return metadata
    }
    func trustedCA() throws -> String? { "test-only" }
    func storeTrustedCA(_ pem: String) throws { }
    func configuration() throws -> ClientConfiguration? { config }
    func storeConfiguration(_ configuration: ClientConfiguration) throws { }
    func forget() throws { metadata = nil; pending = nil }
}

private actor ProvisioningTransport: V1Transport {
    enum Mode { case success, denied, expanded }
    let mode: Mode
    init(mode: Mode = .success) { self.mode = mode }
    func send(path: String, body: JSONValue?) async throws -> JSONValue {
        if path == "/client-interface/v1/discovery" { return try V1ProtocolTests.fixture("discovery") }
        guard path == "/client-interface/v1/enroll" else { throw ClientFailure.transport }
        try? await Task.sleep(for: .milliseconds(120))
        if mode == .denied {
            throw ClientFailure.remote(try V1Error(.object(["code": .string("PERMISSION_DENIED"), "detail_code": .string("invitation_rejected"),
                "message": .string("Do not show remote prose"), "retryable": .bool(false), "retry_after_ms": .null])))
        }
        return .object(["client_id": .string("client:apple-test"), "embodiment_id": .null,
            "certificate_pem": .string("MOCK-certificate"), "ca_chain_pem": .string("MOCK-chain"),
            "server_endpoint": .string("https://home-cortex-0:8443"), "protocol_versions": .array([.string("1.0")]),
            "credential_expires_at": .string(V1Time.format(Date().addingTimeInterval(3600))),
            "grants": .array([.object(["embodiment_id": .null, "verb": .string(mode == .expanded ? "execute" : "session"),
                "capability": mode == .expanded ? .string("vision.observe") : .null])])])
    }
}
