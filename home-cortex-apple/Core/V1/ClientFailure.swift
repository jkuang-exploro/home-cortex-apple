import Foundation

enum ClientFailure: Error, Sendable, Equatable, LocalizedError {
    case configuration, invalidInvitation, invitationExpired, trustRequired, invalidResponse, unsupportedProtocol
    case secureStorage(Int32), keyGeneration, invalidCertificate, credentialExpired, authenticationRequired
    case transport, replaced, loginRejected
    case remote(V1Error)

    var errorDescription: String? {
        switch self {
        case .configuration: "Choose HTTPS server origins with a matching hostname or IP address and protocol 1.0."
        case .invalidInvitation: "This invitation is invalid, expired, belongs to another server, or enables an embodiment. Request a software-client invitation."
        case .invitationExpired: "Invitation expired. Request a fresh software-client invitation."
        case .trustRequired: "Import the public Home Cortex CA from a trusted operator channel first."
        case .invalidResponse: "Home Cortex returned an invalid V1 response."
        case .unsupportedProtocol: "This server does not support protocol 1.0 and envelope schema 1."
        case .secureStorage: "Secure storage is unavailable. Unlock this device and try again."
        case .keyGeneration: "A device-held signing key could not be created."
        case .invalidCertificate: "The certificate, private key, or trusted CA does not match."
        case .credentialExpired: "The client credential has expired. Sign out and sign in again."
        case .authenticationRequired: "TLS authentication failed. Check the server trust and client credential; re-provision if revoked."
        case .transport: "Home Cortex is unreachable. Check the network and local-network permission."
        case .replaced: "This session was replaced. Connect explicitly to establish a new session."
        case .loginRejected: "Sign-in failed. Use the same email and API key as Home Cortex web."
        case .remote(let e): e.displayMessage
        }
    }

    var requiresProvisioning: Bool {
        switch self {
        case .credentialExpired: true
        case .remote(let e): e.code == "PERMISSION_DENIED"
        default: false
        }
    }
    var retryable: Bool {
        switch self {
        case .transport: true
        case .remote(let e): e.retryable || ["stale_session", "session_expired"].contains(e.detailCode ?? "")
        default: false
        }
    }
}

struct V1Error: Sendable, Equatable {
    let code: String
    let detailCode: String?
    let retryable: Bool
    let retryAfterMS: Int64?

    init(_ value: JSONValue) throws {
        let o = try value.object(required: ["code", "detail_code", "message", "retryable", "retry_after_ms"])
        code = try o.field("code").string()
        guard ["UNSUPPORTED", "OFFLINE", "BUSY", "INVALID_ARGUMENT", "PERMISSION_DENIED", "TEMPORARILY_UNAVAILABLE", "SAFETY_REJECTED", "TIMEOUT", "CONFLICT", "NOT_FOUND", "INTERNAL_ERROR"].contains(code),
              case .string(let message) = try o.field("message"), message.count <= 500,
              case .bool(let retry) = try o.field("retryable") else { throw ClientFailure.invalidResponse }
        retryable = retry
        let detail = try o.field("detail_code")
        detailCode = detail == .null ? nil : try detail.string()
        guard (detailCode?.count ?? 0) <= 200 else { throw ClientFailure.invalidResponse }
        let after = try o.field("retry_after_ms")
        retryAfterMS = after == .null ? nil : try after.integer()
    }

    // Do not expose arbitrary remote prose: it could echo an invitation or other secrets.
    var displayMessage: String {
        if detailCode == "invitation_consumed" { return "This invitation was used with another key. Request a fresh invitation." }
        if detailCode == "invitation_rejected" { return "Enrollment denied: the invitation is expired, revoked, or not accepted." }
        if code == "PERMISSION_DENIED" { return "Home Cortex rejected authentication or authorization. Operator re-provisioning may be required." }
        if ["stale_session", "session_expired"].contains(detailCode ?? "") { return "The session is no longer active. Establishing a fresh session." }
        if code == "UNSUPPORTED" { return "Home Cortex does not support this V1 operation or version." }
        return "Home Cortex could not complete the V1 operation (\(code))."
    }
}
