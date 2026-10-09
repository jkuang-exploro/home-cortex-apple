import Foundation

struct LocalizationReferenceCatalog: Decodable, Sendable {
    let spaces: [LocalizationSpaceOption]
    let person_id: String
}
struct LocalizationSpaceOption: Decodable, Identifiable, Sendable {
    let space_id: String
    let name: JSONValue?
    let coordinate_ready: Bool
    let references: [LocalizationReferenceOption]
    let can_manage: Bool
    let frame_definition: JSONValue?
    var id: String { space_id }
    var displayName: String {
        if case .string(let text) = name { return text }
        if case .object(let names) = name {
            if case .string(let text) = names["en"] { return text }
            for key in names.keys.sorted() {
                if case .string(let text) = names[key] { return text }
            }
        }
        return space_id
    }
}
struct ReferenceVector: Codable, Equatable, Sendable {
    var x: Double; var y: Double; var z: Double
}
struct ReferenceAngles: Codable, Equatable, Sendable {
    var yaw: Double; var pitch: Double; var roll: Double
}
struct ReferencePose: Codable, Equatable, Sendable {
    var position: ReferenceVector
    var orientation: ReferenceAngles
    var transform: RigidTransform {
        get throws {
            try RigidTransform(rotation: IPhoneBodyFrame.quaternion(yaw: orientation.yaw, pitch: orientation.pitch, roll: orientation.roll),
                translation: SIMD3(position.x, position.y, position.z))
        }
    }
    static let identity = ReferencePose(position: .init(x:0,y:0,z:0), orientation: .init(yaw:0,pitch:0,roll:0))
}
struct ReferenceProvenance: Codable, Equatable, Sendable {
    let person_id: String; let surveyed_at: String; let method: String
}
struct PendingReferenceSave: Codable, Sendable {
    let spaceID: String
    let reference: LocalizationReferenceOption
    let expectedRevision: Int
    let frameDefinition: JSONValue?
}
struct LocalizationReferenceOption: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let type: String
    let position: ReferenceVector
    let orientation: ReferenceAngles
    let reference: Metadata
    var displayName: String { reference.display_name ?? id }
    var bodyInSpace: RigidTransform {
        get throws {
            try ReferencePose(position: position, orientation: orientation).transform.composed(with: reference.body_in_reference.transform)
        }
    }
    struct Metadata: Codable, Equatable, Sendable {
        let revision: Int
        let reference_frame: String
        let coordinate_convention: String
        let body_frame: String
        let body_in_reference: ReferencePose
        let placement_instructions: String
        let measurement_notes: String
        let provenance: ReferenceProvenance
        let status: String
        let display_name: String?
    }
}

struct EmbodimentAgentOption: Codable, Identifiable, Equatable, Sendable {
    let agent_id: String
    let display_name: String
    var id: String { agent_id }
}
struct EmbodimentSetupOptions: Codable, Sendable {
    let eligible_agents: [EmbodimentAgentOption]
    let allowed_capabilities: [String]
    var allowed_diagnostics: [String]? = nil
    var localizationAllowed: Bool { allowed_diagnostics?.contains("localization.local") == true }
    var motionAllowed: Bool { allowed_diagnostics?.contains("orientation.local") == true }
    var cameraAllowed: Bool { allowed_capabilities.contains("vision.observe") }
}
struct EmbodimentConfiguration: Codable, Sendable {
    let embodiment_id: String
    let agent_id: String
    let agent_display_name: String
    let capabilities: [String]
    var diagnostics: [String]? = nil
    var localizationEnabled: Bool { diagnostics?.contains("localization.local") == true }
    var motionEnabled: Bool { diagnostics?.contains("orientation.local") == true }
    var cameraEnabled: Bool { capabilities.contains("vision.observe") }
}
struct EmbodimentSetupAttempt: Codable, Equatable, Sendable {
    let enrollment_id: String
    let agent_id: String
    let capabilities: [String]
    var diagnostics: [String]? = nil
    let clientID: String
    let origin: String
    init(agentID: String, camera: Bool, motion: Bool = false, clientID: String, origin: URL) {
        enrollment_id = UUID().uuidString.lowercased()
        agent_id = agentID
        capabilities = Self.capabilities(camera: camera)
        diagnostics = motion ? ["orientation.local"] : []
        self.clientID = clientID
        self.origin = origin.absoluteString
    }
    static func capabilities(camera: Bool) -> [String] { camera ? ["vision.observe"] : [] }
}
enum EmbodimentOnboardingState: Equatable {
    case notConfigured, loadingOptions, selectingAgent, selectingSensors, confirming
    case requestingPermissions, creatingDeviceKey, enrolling, registering, enabled
    case failed(String)
    var busy: Bool {
        switch self {
        case .loadingOptions, .requestingPermissions, .creatingDeviceKey, .enrolling: true
        default: false
        }
    }
}

struct EmbodimentSetupFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// CALLER-authenticated application API, never bootstrap/provisioner authority.
final class EmbodimentSetupTransport: @unchecked Sendable {
    let origin: URL
    private let session: URLSession
    private let delegate: TLSDelegate
    init(configuration: ClientConfiguration, ca: String, identity: IdentityMaterial) throws {
        origin = configuration.serverEndpoint
        delegate = TLSDelegate(origin: origin, hostname: configuration.serverHostname,
            anchors: try CertificateTools.certificates(pem: ca), identity: identity)
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        config.tlsMaximumSupportedProtocolVersion = .TLSv13
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func send(_ path: String, sessionID: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let inspection = path.range(of: "^/inspection/v1/embodiments/embodiment:[A-Za-z0-9_-]+/(leases(/[a-f0-9-]{36})?|orientation\\?lease_id=[a-f0-9-]{36}|localization\\?lease_id=[a-f0-9-]{36}|frames\\?lease_id=[a-f0-9-]{36}|evidence)$", options: .regularExpression) != nil
        guard inspection || path.range(of: "^/embodiments/(setup-options|enrollments|embodiment:[A-Za-z0-9_-]+(/runtime|/remove|/localization-references(/space:[A-Za-z0-9_-]+)?)?)$", options: .regularExpression) != nil,
              let url = URL(string: path, relativeTo: origin)?.absoluteURL, url.host == origin.host,
              url.port == origin.port, !sessionID.isEmpty else { throw ClientFailure.configuration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(sessionID, forHTTPHeaderField: "X-Cortex-Session")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (bytes, raw) = try await session.bytes(for: request)
        guard let response = raw as? HTTPURLResponse else { throw ClientFailure.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 131_072 else { throw ClientFailure.invalidResponse }
            try Task.checkCancellation()
            data.append(byte)
        }
        guard (200..<300).contains(response.statusCode) else {
            let message: String
            switch response.statusCode {
            case 401: message = "Reconnect Home Cortex and try again."
            case 403:
                let expired = String(data: data, encoding: .utf8)?.contains("enrollment_expired") == true
                message = expired ? "Setup expired. Start a new setup attempt." : "You are not authorized to manage this embodiment or sensor selection."
            case 409: message = path.contains("localization-references") ? "The reference or room frame changed. Refresh references before editing. Your existing reference is preserved." : "Another setup attempt is pending. Retry the saved setup."
            default: message = "Home Cortex is unavailable. Your setup is saved; try again."
            }
            throw EmbodimentSetupFailure(message: message)
        }
        guard response.mimeType == "application/json" else { throw ClientFailure.invalidResponse }
        return data
    }
}
