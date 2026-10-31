import Foundation

protocol ObservationTransport: Sendable {
    func send(path: String, method: String, payload: JSONValue?, crop: Data?) async throws -> JSONValue
}
final class URLSessionObservationTransport: ObservationTransport, @unchecked Sendable {
    private let origin: URL
    private let prefix: String
    private let runtimeSession: String
    private let channel: URLSession
    private let delegate: TLSDelegate
    init(configuration: ClientConfiguration, ca: String, identity: IdentityMaterial, body: String, session: String) throws {
        guard body.range(of: "^embodiment:[A-Za-z0-9_-]+$",options: .regularExpression) != nil else { throw ClientFailure.configuration }
        origin = configuration.serverEndpoint
        prefix = "/vision/observations/v1/embodiments/"+body
        runtimeSession = session
        let authenticated = try AuthenticatedHTTP.channel(origin: origin,hostname: configuration.serverHostname,caPEM: ca,identity: identity,requestTimeout: 4,resourceTimeout: 8,cachePolicy: .reloadIgnoringLocalCacheData)
        channel = authenticated.session; delegate = authenticated.delegate
    }
    deinit { channel.invalidateAndCancel() }
    func send(path: String, method: String = "POST", payload: JSONValue?, crop: Data? = nil) async throws -> JSONValue {
        guard path.hasPrefix("/sessions"), !path.contains(".."),
              let url = URL(string: prefix+path,relativeTo: origin)?.absoluteURL,
              url.host == origin.host,url.port == origin.port,url.scheme == "https" else { throw ClientFailure.configuration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(runtimeSession,forHTTPHeaderField: "X-Cortex-Session")
        request.setValue("application/json",forHTTPHeaderField: "Accept")
        request.setValue("no-store",forHTTPHeaderField: "Cache-Control")
        if let payload {
            let metadata = try JSONEncoder().encode(payload)
            guard metadata.count <= 65_536 else { throw ObservationFailure.capacity }
            if let crop {
                guard crop.count <= 2_097_152 else { throw ObservationFailure.capacity }
                let boundary = "HC"+observationID()
                var data = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\n\r\n".utf8)
                data.append(metadata)
                data.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"crop\"; filename=\"crop.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
                data.append(crop); data.append(Data("\r\n--\(boundary)--\r\n".utf8))
                request.httpBody = data
                request.setValue("multipart/form-data; boundary=\(boundary)",forHTTPHeaderField: "Content-Type")
            } else {
                request.httpBody = metadata; request.setValue("application/json",forHTTPHeaderField: "Content-Type")
            }
        }
        let (bytes,raw) = try await channel.bytes(for: request)
        let data = try await AuthenticatedHTTP.read(bytes,limit: 65_536,failure: ObservationFailure.invalidResponse)
        guard let response = raw as? HTTPURLResponse,response.mimeType == "application/json" else { throw ObservationFailure.invalidResponse }
        let value = try JSONValue.decode(data)
        if !(200..<300).contains(response.statusCode) {
            guard case .object(let fields) = value,case .object(let error) = fields["error"],case .string(let detail) = error["detail_code"] else { throw ObservationFailure.invalidResponse }
            let retry = error["retryable"] == .bool(true) || response.statusCode == 429 || response.statusCode == 503
            let delay: Int
            if case .integer(let ms) = error["retry_after_ms"] { delay = min(60_000,max(1000,Int(ms))) } else { delay = 2000 }
            throw ObservationFailure.server(response.statusCode,detail,retry,delay)
        }
        return value
    }
}

struct ObservationAccess: Sendable {
    let body: String
    let client: String
    let origin: String
    let transport: any ObservationTransport
}
