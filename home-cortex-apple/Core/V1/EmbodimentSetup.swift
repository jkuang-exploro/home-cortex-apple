import Foundation

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

enum EmbodimentSetupRecovery: Equatable, Sendable { case resume, expired }

struct EmbodimentSetupFailure: LocalizedError {
    let message: String
    var recovery: EmbodimentSetupRecovery = .resume
    var errorDescription: String? { message }
}


extension EmbodimentSetupFailure {
    static func response(status: Int, path: String, data: Data, mimeType: String?) -> Self {
        switch status {
        case 401: return Self(message: "Reconnect Home Cortex and try again.")
        case 403:
            // A code in display text or an unrelated endpoint cannot discard a saved attempt.
            if path == "/embodiments/enrollments", mimeType == "application/json",
               let value = try? JSONValue.decode(data), case .object(let root) = value,
               case .object(let error) = root["error"], error["code"] == .string("PERMISSION_DENIED"),
               case .object(let details) = error["details"], details["detail_code"] == .string("enrollment_expired") {
                return Self(message: "Setup expired. Start a new setup attempt.", recovery: .expired)
            }
            return Self(message: "You are not authorized to manage this embodiment or sensor selection.")
        case 409:
            return Self(message: path.contains("localization-references")
                ? "The reference or room frame changed. Refresh references before editing. Your existing reference is preserved."
                : "Another setup attempt is pending. Retry the saved setup.")
        default: return Self(message: "Home Cortex is unavailable. Your setup is saved; try again.")
        }
    }
}
