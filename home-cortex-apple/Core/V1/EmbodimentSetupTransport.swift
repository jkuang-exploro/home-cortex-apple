import Foundation

/// CALLER-authenticated application API, never bootstrap/provisioner authority.
final class EmbodimentSetupTransport: @unchecked Sendable {
    let origin: URL
    private let session: URLSession
    private let delegate: TLSDelegate
    init(configuration: ClientConfiguration, ca: String, identity: IdentityMaterial) throws {
        origin = configuration.serverEndpoint
        let channel = try AuthenticatedHTTP.channel(origin: origin, hostname: configuration.serverHostname,
            caPEM: ca, identity: identity, requestTimeout: 15, resourceTimeout: 30)
        session = channel.session
        delegate = channel.delegate
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
        let data = try await AuthenticatedHTTP.read(bytes, limit: 131_072, failure: ClientFailure.invalidResponse)
        guard (200..<300).contains(response.statusCode) else {
            throw EmbodimentSetupFailure.response(status: response.statusCode, path: path,
                data: data, mimeType: response.mimeType)
        }
        guard response.mimeType == "application/json" else { throw ClientFailure.invalidResponse }
        return data
    }
}
