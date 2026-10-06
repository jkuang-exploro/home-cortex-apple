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
              serverHostname.range(of: "^[0-9.]+$", options: .regularExpression) == nil else { throw ClientFailure.configuration }
        for url in [serverEndpoint, bootstrapEndpoint] {
            guard url.scheme == "https", url.host?.lowercased() == serverHostname.lowercased(),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  ["", "/"].contains(url.path), (url.port ?? 443) > 0, (url.port ?? 443) <= 65535 else { throw ClientFailure.configuration }
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

    init(data: Data, configuration: ClientConfiguration) throws {
        do {
            let value = try JSONValue.decode(data)
            guard case .object(let raw) = value else { throw ClientFailure.invalidInvitation }
            let compact = raw["bootstrap_endpoint"] != nil
            let o = try value.object(required: compact
                ? ["invitation_id", "token", "bootstrap_endpoint", "embodiment_id"]
                : ["invitation_id", "token", "expires_at", "server_endpoint", "embodiment_id", "purpose", "grants"])
            invitationID = try o.field("invitation_id").string()
            token = try o.field("token").string()
            guard invitationID.range(of: "^invitation:[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                  token.range(of: "^[A-Za-z0-9_-]{43,64}$", options: .regularExpression) != nil,
                  try o.field("embodiment_id") == .null else { throw ClientFailure.invalidInvitation }
            if compact {
                guard URL(string: try o.field("bootstrap_endpoint").string())?.matchesV1Origin(configuration.bootstrapEndpoint) == true else { throw ClientFailure.invalidInvitation }
            } else {
                guard URL(string: try o.field("server_endpoint").string())?.matchesV1Origin(configuration.serverEndpoint) == true,
                      try o.field("purpose").string() == "CALLER",
                      case .array(let grants) = try o.field("grants"), grants.count == 1 else { throw ClientFailure.invalidInvitation }
                let grant = try grants[0].object(required: ["embodiment_id", "verb", "capability"])
                guard try grant.field("embodiment_id") == .null, try grant.field("verb").string() == "session",
                      try grant.field("capability") == .null else { throw ClientFailure.invalidInvitation }
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
