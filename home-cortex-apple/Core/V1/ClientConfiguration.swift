import Foundation

struct ClientConfiguration: Codable, Sendable, Equatable {
    let serverEndpoint: URL
    let bootstrapEndpoint: URL
    let serverHostname: String
    let protocolVersion: String

    enum CodingKeys: String, CodingKey {
        case serverEndpoint = "server_endpoint", bootstrapEndpoint = "bootstrap_endpoint"
        case serverHostname = "server_hostname", protocolVersion = "protocol_version"
    }

    static func parse(_ data: Data) throws -> Self {
        _ = try JSONValue.decode(data).object(required: ["server_endpoint", "bootstrap_endpoint", "server_hostname", "protocol_version"])
        guard let config = try? JSONDecoder().decode(Self.self, from: data) else { throw ClientFailure.configuration }
        try config.validate()
        return config
    }

    func validate() throws {
        guard protocolVersion == "1.0", !serverHostname.isEmpty,
              serverHostname.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil,
              serverHostname.range(of: "^[0-9.]+$", options: .regularExpression) == nil
                || Self.isIPv4(serverHostname) else { throw ClientFailure.configuration }
        for url in [serverEndpoint, bootstrapEndpoint] {
            guard url.scheme == "https", url.host?.lowercased() == serverHostname.lowercased(),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  ["", "/"].contains(url.path), (url.port ?? 443) > 0, (url.port ?? 443) <= 65535 else { throw ClientFailure.configuration }
        }
    }

    static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && UInt8(part) != nil
                && (part == "0" || !part.hasPrefix("0"))
        }
    }

    static func bundled() throws -> Self? {
        #if DEBUG
        guard let url = Bundle.main.url(forResource: "Development", withExtension: "json") else { throw ClientFailure.configuration }
        return try parse(Data(contentsOf: url))
        #else
        return nil // Production requires explicit configuration; no development origin fallback.
        #endif
    }
}

struct ProvisioningInvitation: Sendable {
    let invitationID: String
    let token: String
    let embodimentID: String?
    let purpose: CredentialPurpose
    let visionObserveGranted: Bool

    init(data: Data, configuration: ClientConfiguration, purpose: CredentialPurpose = .caller) throws {
        self.purpose = purpose
        do {
            let value = try JSONValue.decode(data)
            guard case .object(let raw) = value else { throw ClientFailure.invalidInvitation }
            let compact = raw["bootstrap_endpoint"] != nil
            let body = try raw.field("embodiment_id")
            embodimentID = body == .null ? nil : try body.string()
            guard (purpose == .caller && embodimentID == nil) || (purpose == .device && embodimentID?.range(of: "^embodiment:[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)*$", options: .regularExpression) != nil) else { throw ClientFailure.invalidInvitation }
            let o = try value.object(required: compact
                ? ["invitation_id", "token", "bootstrap_endpoint", "embodiment_id"]
                : ["invitation_id", "token", "expires_at", "server_endpoint", "embodiment_id", "purpose", "grants"])
            invitationID = try o.field("invitation_id").string()
            token = try o.field("token").string()
            guard invitationID.range(of: "^invitation:[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                  token.range(of: "^[A-Za-z0-9_-]{43,64}$", options: .regularExpression) != nil,
                  try o.field("embodiment_id") == body else { throw ClientFailure.invalidInvitation }
            if compact {
                guard purpose == .caller else { throw ClientFailure.invalidInvitation }
                visionObserveGranted = false
                guard URL(string: try o.field("bootstrap_endpoint").string())?.matchesV1Origin(configuration.bootstrapEndpoint) == true else { throw ClientFailure.invalidInvitation }
            } else {
                guard URL(string: try o.field("server_endpoint").string())?.matchesV1Origin(configuration.serverEndpoint) == true,
                      try o.field("purpose").string() == purpose.rawValue else { throw ClientFailure.invalidInvitation }
                visionObserveGranted = try V1Grants.visionObserve(o.field("grants"), body: embodimentID, purpose: purpose)
                guard try V1Time.parse(o.field("expires_at").string()) > Date() else { throw ClientFailure.invitationExpired }
            }
        } catch ClientFailure.invitationExpired { throw ClientFailure.invitationExpired }
        catch { throw ClientFailure.invalidInvitation }
    }
}

extension URL {
    func matchesV1Origin(_ other: URL) -> Bool {
        scheme == "https" && user == nil && password == nil && query == nil && fragment == nil
            && ["", "/"].contains(path) && host?.lowercased() == other.host?.lowercased()
            && (port ?? 443) == (other.port ?? 443)
    }
}

/// Closed authority: session, optionally receive vision.observe on this DEVICE body.
enum V1Grants {
    static func visionObserve(_ value: JSONValue, body: String?, purpose: CredentialPurpose) throws -> Bool {
        guard case .array(let grants) = value else { throw ClientFailure.invalidInvitation }
        let target = body.map(JSONValue.string) ?? .null
        let session = JSONValue.object(["embodiment_id": target, "verb": .string("session"), "capability": .null])
        let vision = JSONValue.object(["embodiment_id": target, "verb": .string("receive"), "capability": .string("vision.observe")])
        if grants == [session] { return false }
        guard purpose == .device, body != nil, grants.count == 2, grants.contains(session), grants.contains(vision) else { throw ClientFailure.invalidInvitation }
        return true
    }
}
