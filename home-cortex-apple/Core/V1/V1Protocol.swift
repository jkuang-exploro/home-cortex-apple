import Foundation

enum DiscoveryState: String { case unknown, discovering, compatible, incompatible, failed }

struct V1Discovery: Sendable {
    let maxMediaBytes: Int
    init(_ value: JSONValue) throws {
        let o = try value.object(required: ["protocol_versions", "envelope_schema_versions", "promotion_max_age_ms", "max_media_bytes"])
        let versions = try o.field("protocol_versions").strings()
        guard case .array(let schemas) = try o.field("envelope_schema_versions") else { throw ClientFailure.invalidResponse }
        let schemaVersions = try schemas.map { try $0.integer(minimum: 1) }
        guard versions.contains("1.0"), schemaVersions.contains(1) else { throw ClientFailure.unsupportedProtocol }
        _ = try o.field("promotion_max_age_ms").integer(minimum: 1)
        let limit = try o.field("max_media_bytes").integer(minimum: 1)
        guard limit <= 33_554_432 else { throw ClientFailure.invalidResponse }
        maxMediaBytes = Int(limit)
    }
}

struct V1Request: Sendable {
    let id: String
    let operation: String
    let sessionID: String?
    let embodimentID: String?
    let deadline: Date
    let value: JSONValue

    init(operation: String, sessionID: String? = nil, clientID: String, version: String, embodimentID: String? = nil, now: Date = Date(), manifest: JSONValue? = nil) {
        id = UUID().uuidString.lowercased()
        self.operation = operation
        self.sessionID = sessionID
        self.embodimentID = embodimentID
        deadline = now.addingTimeInterval(10)
        let arguments: JSONValue = operation == "session.register" ? .object([
            "identity": .object([
                "client_id": .string(clientID), "embodiment_id": embodimentID.map(JSONValue.string) ?? .null,
                "application_id": .string("home-cortex-apple"),
                "implementation": .object(["name": .string("home-cortex-apple"), "platform": .string("iOS"), "software_version": .string(version)])
            ]),
            "manifest": manifest ?? .object(["revision": .integer(1), "capabilities": .array([])])
        ]) : operation == "session.capabilities" ? .object(["manifest": manifest ?? .object(["revision": .integer(1), "capabilities": .array([])])]) : .object([:])
        value = .object([
            "protocol_version": .string("1.0"), "schema_name": .string("hc.request"), "schema_version": .integer(1),
            "message_id": .string(id), "request_id": .string(id), "sent_at": .string(V1Time.format(now)),
            "deadline_at": .string(V1Time.format(deadline)), "operation": .string(operation), "arguments": arguments,
            "target": .object(["embodiment_id": embodimentID.map(JSONValue.string) ?? .null, "session_id": sessionID.map(JSONValue.string) ?? .null])
        ])
    }
}

struct V1Response {
    let result: JSONValue

    init(_ value: JSONValue, request: V1Request) throws {
        let o = try value.object(required: ["protocol_version", "schema_name", "schema_version", "message_id", "sent_at", "request_id", "target", "operation", "completed_at", "status"], optional: ["result", "error", "extensions"])
        guard try o.field("protocol_version").string() == "1.0",
              try o.field("schema_name").string() == "hc.response",
              try o.field("schema_version").integer(minimum: 1) == 1 else { throw ClientFailure.unsupportedProtocol }
        let id = try o.field("message_id").string()
        guard id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil,
              try o.field("request_id").string() == request.id,
              try o.field("operation").string() == request.operation else { throw ClientFailure.invalidResponse }
        _ = try V1Time.parse(o.field("sent_at").string())
        _ = try V1Time.parse(o.field("completed_at").string())
        let target = try o.field("target").object(required: ["embodiment_id", "session_id"])
        guard try target.field("embodiment_id") == (request.embodimentID.map(JSONValue.string) ?? .null),
              try target.field("session_id") == (request.sessionID.map(JSONValue.string) ?? .null) else { throw ClientFailure.invalidResponse }
        if let extensions = o["extensions"] {
            guard case .object(let fields) = extensions, fields.count <= 32,
                  fields.keys.allSatisfy({ $0.range(of: "^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$", options: .regularExpression) != nil }) else { throw ClientFailure.invalidResponse }
        }
        let status = try o.field("status").string()
        if status == "FAILED", o["result"] == nil, let error = o["error"] { throw ClientFailure.remote(try V1Error(error)) }
        guard status == "SUCCEEDED", o["error"] == nil, let result = o["result"] else { throw ClientFailure.invalidResponse }
        self.result = result
    }
}

enum SessionState: String, Sendable { case active = "ACTIVE", stale = "STALE", expired = "EXPIRED", replaced = "REPLACED", disconnected = "DISCONNECTED" }

struct SessionView: Sendable {
    let clientID: String
    let embodimentID: String?
    let sessionID: String
    let state: SessionState
    let serverTime: Date
    let leaseExpiresAt: Date
    let heartbeatIntervalMS: Int64
    let leaseDurationMS: Int64
    let manifestRevision: Int64
    let effectiveCapabilities: [String]

    init(_ value: JSONValue) throws {
        let o = try value.object(required: ["client_id", "embodiment_id", "session_id", "state", "connected_at", "last_seen_at", "server_time", "lease_expires_at", "heartbeat_interval_ms", "lease_duration_ms", "manifest_revision", "effective_capabilities"])
        clientID = try o.field("client_id").string()
        guard clientID.range(of: "^client:[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)*$", options: .regularExpression) != nil else { throw ClientFailure.invalidResponse }
        let body = try o.field("embodiment_id")
        embodimentID = body == .null ? nil : try body.string()
        sessionID = try o.field("session_id").string()
        guard sessionID.hasPrefix("runtime-session:"), sessionID.count <= 200,
              let state = SessionState(rawValue: try o.field("state").string()) else { throw ClientFailure.invalidResponse }
        self.state = state
        _ = try V1Time.parse(o.field("connected_at").string())
        _ = try V1Time.parse(o.field("last_seen_at").string())
        serverTime = try V1Time.parse(o.field("server_time").string())
        leaseExpiresAt = try V1Time.parse(o.field("lease_expires_at").string())
        heartbeatIntervalMS = try o.field("heartbeat_interval_ms").integer(minimum: 1000)
        leaseDurationMS = try o.field("lease_duration_ms").integer(minimum: 3000)
        manifestRevision = try o.field("manifest_revision").integer(minimum: 1)
        effectiveCapabilities = try o.field("effective_capabilities").strings()
        guard heartbeatIntervalMS <= leaseDurationMS / 3,
              leaseExpiresAt.timeIntervalSince(serverTime) <= Double(leaseDurationMS) / 1000 + 0.001 else { throw ClientFailure.invalidResponse }
    }

    func validatePrincipal(_ clientID: String, embodimentID expectedBody: String?, request: V1Request, allowedCapabilities: Set<String> = [], expectedRevision: Int64 = 1) throws {
        guard self.clientID == clientID, embodimentID == expectedBody, request.embodimentID == expectedBody, Set(effectiveCapabilities).isSubset(of: allowedCapabilities), Set(effectiveCapabilities).count == effectiveCapabilities.count,
              manifestRevision == expectedRevision, request.sessionID == nil || request.sessionID == sessionID else { throw ClientFailure.invalidResponse }
    }
    func validateSoftwareClient(_ clientID: String, request: V1Request) throws {
        try validatePrincipal(clientID, embodimentID: nil, request: request)
    }
}

struct SessionLease: Sendable {
    let deadline: ContinuousClock.Instant
    let expiresAt: Date
    let heartbeatDelay: TimeInterval

    static func budget(view: SessionView, receivedAt: Date, roundTrip: TimeInterval) -> TimeInterval {
        max(0, min(view.leaseExpiresAt.timeIntervalSince(view.serverTime) - max(0, roundTrip),
                   view.leaseExpiresAt.timeIntervalSince(receivedAt), Double(view.leaseDurationMS) / 1000) - 1)
    }

    init(view: SessionView, receivedAt: Date = Date(), roundTrip: TimeInterval, now: ContinuousClock.Instant = .now) {
        let budget = Self.budget(view: view, receivedAt: receivedAt, roundTrip: roundTrip)
        deadline = now.advanced(by: .seconds(budget))
        expiresAt = view.leaseExpiresAt
        heartbeatDelay = min(Double(view.heartbeatIntervalMS) / 1000, budget / 2)
    }

    func valid(at now: ContinuousClock.Instant = .now, date: Date = Date()) -> Bool {
        now < deadline && date < expiresAt
    }
}

struct EnrollmentBundle: Sendable {
    let clientID: String
    let embodimentID: String?
    let visionObserveGranted: Bool
    let certificatePEM: String
    let caChainPEM: String
    let expiresAt: Date

    init(_ value: JSONValue, configuration: ClientConfiguration, embodimentID: String? = nil, visionObserveGranted: Bool = false) throws {
        self.embodimentID = embodimentID
        self.visionObserveGranted = visionObserveGranted
        let o = try value.object(required: ["client_id", "embodiment_id", "certificate_pem", "ca_chain_pem", "server_endpoint", "protocol_versions", "grants", "credential_expires_at"])
        clientID = try o.field("client_id").string()
        guard clientID.range(of: "^client:[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)*$", options: .regularExpression) != nil,
              try o.field("embodiment_id") == (embodimentID.map(JSONValue.string) ?? .null),
              URL(string: try o.field("server_endpoint").string())?.matchesV1Origin(configuration.serverEndpoint) == true,
              try o.field("protocol_versions").strings().contains("1.0"),
              try V1Grants.visionObserve(o.field("grants"), body: embodimentID, purpose: embodimentID == nil ? .caller : .device) == visionObserveGranted else { throw ClientFailure.invalidResponse }
        certificatePEM = try o.field("certificate_pem").string()
        caChainPEM = try o.field("ca_chain_pem").string()
        expiresAt = try V1Time.parse(o.field("credential_expires_at").string())
        guard expiresAt > Date() else { throw ClientFailure.credentialExpired }
    }
}
