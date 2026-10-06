import Foundation

protocol ConversationTransport: Sendable {
    func history(id: String, sessionID: String) async throws -> ConversationDocument
    func selectOrCreate(sessionID: String) async throws -> ConversationDocument
    func stream(id: String, content: String, sessionID: String,
                receive: @escaping @Sendable (ConversationEvent) async throws -> Void) async throws
}
struct ConversationAccess: Sendable {
    let clientID: String
    let sessionID: String
    let origin: URL
    let transport: any ConversationTransport
    var selectionKey: String { "HomeCortex.conversation.\(origin.absoluteString).\(clientID)" }
}

final class URLSessionConversationTransport: ConversationTransport, @unchecked Sendable {
    private let origin: URL
    private let session: URLSession
    private let delegate: TLSDelegate
    init(configuration: ClientConfiguration, caPEM: String, identity: IdentityMaterial) throws {
        origin = configuration.serverEndpoint
        delegate = TLSDelegate(origin: origin, hostname: configuration.serverHostname,
            anchors: try CertificateTools.certificates(pem: caPEM), identity: identity)
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        config.tlsMaximumSupportedProtocolVersion = .TLSv13
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    private func request(_ path: String, sessionID: String, body: Data? = nil) throws -> URLRequest {
        guard path == "/conversations" || path.range(of: "^/conversations/[A-Za-z0-9_-]+(/messages)?$", options: .regularExpression) != nil,
              let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.host == origin.host, url.port == origin.port, !sessionID.isEmpty else { throw ChatFailure.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue(sessionID, forHTTPHeaderField: "X-Cortex-Session")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    private func validate(_ raw: URLResponse) throws -> HTTPURLResponse {
        guard let response = raw as? HTTPURLResponse else { throw ChatFailure.invalidResponse }
        switch response.statusCode {
        case 200...299: return response
        case 401, 403, 495, 496, 300...399: throw ChatFailure.authentication
        case 404: throw ChatFailure.notFound
        case 408, 504: throw ChatFailure.timeout
        case 429, 500...599: throw ChatFailure.unavailable
        default: throw ChatFailure.conversation
        }
    }
    private func json(_ request: URLRequest) async throws -> Data {
        let (bytes, raw) = try await session.bytes(for: request)
        let response = try validate(raw)
        guard response.mimeType == "application/json" else { throw ChatFailure.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 2_097_152 else { throw ChatFailure.invalidResponse }
            data.append(byte)
        }
        return data
    }
    func history(id: String, sessionID: String) async throws -> ConversationDocument {
        guard ConversationDocument.validID(id) else { throw ChatFailure.invalidResponse }
        let value = try ConversationDocument.decode(await json(request("/conversations/" + id, sessionID: sessionID)))
        guard value.id == id else { throw ChatFailure.invalidResponse }
        return value
    }
    func selectOrCreate(sessionID: String) async throws -> ConversationDocument {
        struct Summary: Decodable { let id: String; let agent_id: String?; let active_embodiment_id: String? }
        struct Listing: Decodable { let object: String; let data: [Summary] }
        let list = try JSONDecoder().decode(Listing.self, from: await json(request("/conversations", sessionID: sessionID)))
        guard list.object == "list" else { throw ChatFailure.invalidResponse }
        if let latest = list.data.first(where: { $0.agent_id == "steward" && $0.active_embodiment_id == nil }) {
            return try await history(id: latest.id, sessionID: sessionID)
        }
        let body = try JSONEncoder().encode(["model": "steward", "language": "zh"])
        return try ConversationDocument.decode(await json(request("/conversations", sessionID: sessionID, body: body)))
    }
    func stream(id: String, content: String, sessionID: String,
                receive: @escaping @Sendable (ConversationEvent) async throws -> Void) async throws {
        guard ConversationDocument.validID(id) else { throw ChatFailure.invalidResponse }
        var request = try request("/conversations/\(id)/messages", sessionID: sessionID,
            body: JSONEncoder().encode(ConversationSend(content: content)))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, raw) = try await session.bytes(for: request)
        guard try validate(raw).mimeType == "text/event-stream" else { throw ChatFailure.invalidResponse }
        var decoder = ConversationSSEDecoder()
        for try await byte in bytes {
            try Task.checkCancellation()
            for event in try decoder.byte(byte) { try await receive(event) }
            if decoder.done { break }
        }
        try decoder.validateEnd()
    }
}
