import Foundation

protocol InspectionTransport: Sendable {
    func send(bodyID: String, sessionID: String, frame: JSONValue?) async throws -> JSONValue
    func sendOrientation(bodyID: String, sessionID: String, diagnostic: JSONValue?) async throws -> JSONValue
    func sendLocalization(bodyID: String, sessionID: String, diagnostic: JSONValue?) async throws -> JSONValue
}

extension InspectionTransport {
    func sendLocalization(bodyID: String, sessionID: String, diagnostic: JSONValue?) async throws -> JSONValue { throw ClientFailure.configuration }
    func sendOrientation(bodyID: String, sessionID: String, diagnostic: JSONValue?) async throws -> JSONValue { throw ClientFailure.configuration }
}

final class URLSessionInspectionTransport: InspectionTransport, @unchecked Sendable {
    private let origin: URL
    private let session: URLSession
    private let delegate: TLSDelegate
    init(configuration: ClientConfiguration, ca: String, identity: IdentityMaterial) throws {
        origin = configuration.serverEndpoint
        let channel = try AuthenticatedHTTP.channel(origin: origin, hostname: configuration.serverHostname,
            caPEM: ca, identity: identity, requestTimeout: 2, resourceTimeout: 3)
        session = channel.session
        delegate = channel.delegate
    }
    deinit { session.invalidateAndCancel() }
    func send(bodyID: String, sessionID: String, frame: JSONValue?) async throws -> JSONValue {
        try await sendChannel(bodyID: bodyID, sessionID: sessionID, frame: frame, channel: "camera")
    }
    func sendOrientation(bodyID: String, sessionID: String, diagnostic: JSONValue?) async throws -> JSONValue {
        try await sendChannel(bodyID: bodyID, sessionID: sessionID, frame: diagnostic, channel: "orientation")
    }
    func sendLocalization(bodyID: String, sessionID: String, diagnostic: JSONValue?) async throws -> JSONValue {
        try await sendChannel(bodyID: bodyID, sessionID: sessionID, frame: diagnostic, channel: "localization")
    }
    private func sendChannel(bodyID: String, sessionID: String, frame: JSONValue?, channel: String) async throws -> JSONValue {
        let interval = PerformanceInterval("InspectionRequest")
        defer { interval.end() }
        guard bodyID.range(of: "^embodiment:[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw ClientFailure.configuration }
        let path = "/inspection/v1/device/" + bodyID + (frame == nil ? (channel == "camera" ? "/lease" : "/lease?channel=" + channel) : (channel == "camera" ? "/frames" : "/" + channel))
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL, url.host == origin.host, url.port == origin.port else { throw ClientFailure.configuration }
        var request = URLRequest(url: url)
        request.httpMethod = frame == nil ? "GET" : "POST"
        request.setValue(sessionID, forHTTPHeaderField: "X-Cortex-Session")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let frame {
            let body = try JSONEncoder().encode(frame)
            guard body.count <= 140_000 else { throw ClientFailure.invalidResponse }
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, raw) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = raw as? HTTPURLResponse, (200..<300).contains(response.statusCode), bytes.count <= 8192 else { throw ClientFailure.transport }
        if response.statusCode == 204 { guard bytes.isEmpty else { throw ClientFailure.invalidResponse }; return .null }
        guard response.mimeType == "application/json" else { throw ClientFailure.invalidResponse }
        return try JSONValue.decode(bytes)
    }
}

