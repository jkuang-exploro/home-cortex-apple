import XCTest
@testable import HomeCortex

final class V1ProtocolTests: XCTestCase {
    static func fixture(_ name: String) throws -> JSONValue { try JSONValue.decode(fixtureData(name, extension: "json")) }
    static func fixtureData(_ name: String, extension ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: V1ProtocolTests.self).url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    static func config() throws -> ClientConfiguration {
        try ClientConfiguration.parse(Data("""
        {"server_endpoint":"https://home-cortex-0:8443","bootstrap_endpoint":"https://home-cortex-0:8444","server_hostname":"home-cortex-0","protocol_version":"1.0"}
        """.utf8))
    }

    func testFrozenDiscoveryAndNoDowngrade() throws {
        let original = try Self.fixture("discovery")
        XCTAssertNoThrow(try V1Discovery(original))
        var o = try original.object(required: ["protocol_versions", "envelope_schema_versions", "promotion_max_age_ms", "max_media_bytes"])
        o["protocol_versions"] = .array([.string("0.9")])
        XCTAssertThrowsError(try V1Discovery(.object(o))) { XCTAssertEqual($0 as? ClientFailure, .unsupportedProtocol) }
        o["protocol_versions"] = .array([.string("1.0")])
        o["envelope_schema_versions"] = .array([.bool(true)])
        XCTAssertThrowsError(try V1Discovery(.object(o)))
        let fractional = String(decoding: try Self.fixtureData("discovery", extension: "json"), as: UTF8.self)
            .replacingOccurrences(of: "[1]", with: "[1.0]")
        XCTAssertThrowsError(try V1Discovery(JSONValue.decode(Data(fractional.utf8))))
    }

    func testConfigurationRejectsInsecureOrMismatchedOrigins() throws {
        let config = try Self.config()
        XCTAssertEqual(config.serverEndpoint.port, 8443)
        let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        for malformed in [encoded.replacingOccurrences(of: "https", with: "http"),
                          encoded.replacingOccurrences(of: "home-cortex-0:8443", with: "other-host:8443"),
                          encoded.replacingOccurrences(of: ":8443", with: ":8443?secret=value"),
                          encoded.replacingOccurrences(of: ":8443", with: ":8443/path"),
                          encoded.replacingOccurrences(of: "1.0", with: "0.9")] {
            XCTAssertThrowsError(try ClientConfiguration.parse(Data(malformed.utf8)))
        }
    }

    func testClosedJSONRejectsDuplicateEscapedKeysAndNonfiniteValues() throws {
        for raw in [#"{"x":1,"x":2}"#, #"{"x":1,"\u0078":2}"#, #"{"x":NaN}"#, #"{"x":Infinity}"#,
                    #"{"x":{"nested":1,"nested":2}}"#] {
            XCTAssertThrowsError(try JSONValue.decode(Data(raw.utf8)))
        }
        XCTAssertNoThrow(try JSONValue.decode(Data(#"{"x":"comma, quote \" brace }","array":[1,null,true]}"#.utf8)))
        let original = try Self.fixture("discovery")
        guard case .object(var o) = original else { return XCTFail("Fixture is not an object") }
        o["unexpected"] = .null
        XCTAssertThrowsError(try V1Discovery(.object(o)))
    }

    func testGoldenSessionDecodingAndSoftwareClientFence() throws {
        let response = try Self.fixture("register-response")
        guard case .object(let envelope) = response else { return XCTFail("Fixture is not an object") }
        let view = try SessionView(envelope.field("result"))
        XCTAssertEqual(view.state, .active)
        XCTAssertEqual(view.heartbeatIntervalMS, 10_000)
        XCTAssertEqual(view.leaseDurationMS, 30_000)
        let request = V1Request(operation: "session.register", clientID: view.clientID, version: "0.1.0")
        XCTAssertThrowsError(try view.validateSoftwareClient(view.clientID, request: request)) // Physical golden vector must not authorize Apple.
        var malformed = try envelope.field("result").object(required: ["client_id", "embodiment_id", "session_id", "state", "connected_at", "last_seen_at", "server_time", "lease_expires_at", "heartbeat_interval_ms", "lease_duration_ms", "manifest_revision", "effective_capabilities"])
        malformed["heartbeat_interval_ms"] = .integer(Int64.max)
        XCTAssertThrowsError(try SessionView(.object(malformed)), "Untrusted timing must not overflow integer arithmetic")
    }

    func testSoftwareRegistrationHasNullBodyAndEmptyManifest() throws {
        let request = V1Request(operation: "session.register", clientID: "client:apple-test", version: "0.1.0")
        guard case .object(let envelope) = request.value,
              case .object(let arguments) = envelope["arguments"],
              case .object(let identity) = arguments["identity"],
              case .object(let manifest) = arguments["manifest"],
              case .object(let target) = envelope["target"] else { return XCTFail("Missing request fields") }
        XCTAssertEqual(identity["embodiment_id"], .null)
        XCTAssertEqual(target["embodiment_id"], .null)
        XCTAssertEqual(target["session_id"], .null)
        XCTAssertEqual(manifest["capabilities"], .array([]))
        XCTAssertEqual(envelope["protocol_version"], .string("1.0"))
    }

    func testResponseRequiresExactCorrelationAndSchema() throws {
        let request = V1Request(operation: "session.register", clientID: "client:apple-test", version: "0.1.0")
        var response = try Self.softwareResponse(request: request)
        XCTAssertNoThrow(try V1Response(.object(response), request: request))
        response["request_id"] = .string(UUID().uuidString.lowercased())
        XCTAssertThrowsError(try V1Response(.object(response), request: request))
        response = try Self.softwareResponse(request: request)
        response["schema_version"] = .bool(true)
        XCTAssertThrowsError(try V1Response(.object(response), request: request))
        response = try Self.softwareResponse(request: request)
        response["target"] = .object(["embodiment_id": .string("embodiment:unexpected"), "session_id": .null])
        XCTAssertThrowsError(try V1Response(.object(response), request: request))
    }

    func testLeaseBudgetAccountsForRoundTripClockAndAlreadyExpiredReplies() throws {
        guard case .object(let response) = try Self.fixture("register-response") else { return XCTFail() }
        let view = try SessionView(response.field("result"))
        XCTAssertEqual(SessionLease.budget(view: view, receivedAt: view.serverTime, roundTrip: 1), 28, accuracy: 0.001)
        XCTAssertEqual(SessionLease.budget(view: view, receivedAt: view.leaseExpiresAt, roundTrip: 0), 0)
        XCTAssertEqual(SessionLease.budget(view: view, receivedAt: view.serverTime, roundTrip: 100), 0)
        let now = ContinuousClock.now
        let lease = SessionLease(view: view, receivedAt: view.serverTime, roundTrip: 1, now: now)
        XCTAssertTrue(lease.valid(at: now, date: view.serverTime))
        XCTAssertFalse(lease.valid(at: now.advanced(by: .seconds(29)), date: view.serverTime))
    }

    func testCredentialMetadataExpiresAndLatchesRejection() throws {
        var metadata = try Self.metadata()
        XCTAssertNoThrow(try metadata.validate())
        XCTAssertThrowsError(try metadata.validate(now: metadata.expiresAt)) { XCTAssertEqual($0 as? ClientFailure, .credentialExpired) }
        metadata.authenticationRejected = true
        let persisted = try JSONDecoder().decode(CredentialMetadata.self, from: JSONEncoder().encode(metadata))
        XCTAssertThrowsError(try persisted.validate()) { XCTAssertEqual($0 as? ClientFailure, .authenticationRequired) }
    }

    func testCanonicalErrorUsesFrozenVectorAndDoesNotExposeRemoteProse() throws {
        let error = try V1Error(Self.fixture("error"))
        XCTAssertEqual(error.code, "TEMPORARILY_UNAVAILABLE")
        XCTAssertTrue(ClientFailure.remote(error).retryable)
        XCTAssertFalse(error.displayMessage.contains("Recent clip buffer"))
        var o = try Self.fixture("error").object(required: ["code", "detail_code", "message", "retryable", "retry_after_ms"])
        o["code"] = .string("PERMISSION_DENIED")
        o["message"] = .string("sensitive-token-must-not-appear")
        let denied = ClientFailure.remote(try V1Error(.object(o)))
        XCTAssertTrue(denied.requiresProvisioning)
        XCTAssertFalse(denied.localizedDescription.contains("sensitive-token"))
        o["code"] = .string("UNKNOWN")
        XCTAssertThrowsError(try V1Error(.object(o)))
    }

    func testInvitationRejectsEmbodimentAndDifferentBootstrapOrigin() throws {
        let data = try Self.invitationData()
        XCTAssertNoThrow(try ProvisioningInvitation(data: data, configuration: Self.config()))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertThrowsError(try ProvisioningInvitation(data: Data(text.replacingOccurrences(of: "null", with: "\"embodiment:phone\"").utf8), configuration: Self.config()))
        XCTAssertThrowsError(try ProvisioningInvitation(data: Data(text.replacingOccurrences(of: "8444", with: "8445").utf8), configuration: Self.config()))
        XCTAssertNoThrow(try ProvisioningInvitation(data: Data(text.replacingOccurrences(of: "8444", with: "8444/").utf8), configuration: Self.config()))
        XCTAssertThrowsError(try ProvisioningInvitation(data: Data(text.replacingOccurrences(of: "8444", with: "8444/path").utf8), configuration: Self.config()))
    }

    static func invitationData() throws -> Data {
        try JSONEncoder().encode(JSONValue.object(["invitation_id": .string("invitation:apple-test"), "token": .string(String(repeating: "a", count: 43)), "embodiment_id": .null, "bootstrap_endpoint": .string("https://home-cortex-0:8444")]))
    }
    static func metadata() throws -> CredentialMetadata {
        CredentialMetadata(clientID: "client:apple-test", keyTag: Data("unit-test-only".utf8), configuration: try config(), certificatePEM: "test-only", caChainPEM: "test-only", trustedCAPEM: "test-only", expiresAt: Date().addingTimeInterval(3600))
    }
    // Explicit software-only derivative of the frozen physical registration vector.
    static func softwareResponse(request: V1Request, state: SessionState = .active, sessionID: String = "runtime-session:apple-test:1") throws -> [String: JSONValue] {
        guard case .object(var response) = try fixture("register-response"), case .object(var view) = response["result"] else { throw ClientFailure.invalidResponse }
        let now = Date()
        response["request_id"] = .string(request.id)
        response["operation"] = .string(request.operation)
        response["target"] = .object(["embodiment_id": .null, "session_id": request.sessionID.map(JSONValue.string) ?? .null])
        response["sent_at"] = .string(V1Time.format(now)); response["completed_at"] = response["sent_at"]
        view["client_id"] = .string("client:apple-test"); view["embodiment_id"] = .null
        view["session_id"] = .string(sessionID); view["state"] = .string(state.rawValue)
        for key in ["connected_at", "last_seen_at", "server_time"] { view[key] = .string(V1Time.format(now)) }
        view["lease_expires_at"] = .string(V1Time.format(now.addingTimeInterval(3)))
        view["heartbeat_interval_ms"] = .integer(1000); view["lease_duration_ms"] = .integer(3000)
        view["effective_capabilities"] = .array([])
        response["result"] = .object(view)
        return response
    }
}
