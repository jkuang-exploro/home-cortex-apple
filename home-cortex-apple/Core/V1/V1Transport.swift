import Foundation
import Security
import OSLog

protocol V1Transport: Sendable {
    func send(path: String, body: JSONValue?) async throws -> JSONValue
}

final class URLSessionV1Transport: V1Transport, @unchecked Sendable {
    private let origin: URL
    private let identityAvailable: Bool
    private let session: URLSession
    private let delegate: TLSDelegate
    private let logger = Logger(subsystem: "HomeCortex", category: "V1Transport")

    init(origin: URL, hostname: String, trustedCAPEM: String, identity: IdentityMaterial? = nil) throws {
        self.origin = origin
        identityAvailable = identity != nil
        delegate = TLSDelegate(origin: origin, hostname: hostname, anchors: try CertificateTools.certificates(pem: trustedCAPEM), identity: identity)
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        config.tlsMaximumSupportedProtocolVersion = .TLSv13
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func send(path: String, body: JSONValue? = nil) async throws -> JSONValue {
        let components = URLComponents(string: path)
        let polling = components?.path == "/client-interface/v1/commands" && body == nil && identityAvailable
            && components?.queryItems?.count == 1 && components?.queryItems?.first?.name == "session_id"
        guard (["/client-interface/v1/discovery", "/client-interface/v1/enroll", "/client-interface/v1/messages"].contains(path) || polling),
              let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.host == origin.host, url.port == origin.port else { throw ClientFailure.configuration }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, raw) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = raw as? HTTPURLResponse else { throw ClientFailure.invalidResponse }
            guard !(300..<400).contains(response.statusCode) else { throw ClientFailure.authenticationRequired }
            if response.statusCode == 204 { guard data.isEmpty else { throw ClientFailure.invalidResponse }; return .null }
            guard data.count <= 131_072 else { throw ClientFailure.invalidResponse }
            let parsed = try? JSONValue.decode(data)
            if !(200..<300).contains(response.statusCode) {
                if case .object(let o) = parsed, o["schema_name"] == .string("hc.response") {
                    return parsed! // Correlated failures are validated by V1Response.
                }
                if case .object(let o) = parsed, let error = o["error"] { throw ClientFailure.remote(try V1Error(error)) }
                if [400, 401, 403, 495, 496].contains(response.statusCode) { throw ClientFailure.authenticationRequired }
                throw ClientFailure.transport
            }
            guard let parsed else { throw ClientFailure.invalidResponse }
            logger.debug("V1 HTTPS response received")
            return parsed
        } catch let error as URLError {
            if error.code == .cancelled {
                if Task.isCancelled { throw CancellationError() }
                throw ClientFailure.authenticationRequired
            }
            if [.serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
                .secureConnectionFailed, .userAuthenticationRequired].contains(error.code) {
                logger.notice("V1 TLS authentication rejected")
                throw ClientFailure.authenticationRequired
            }
            throw ClientFailure.transport
        }
    }
}

final class TLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL
    private let hostname: String
    private let anchors: [SecCertificate]
    private let identity: IdentityMaterial?
    init(origin: URL, hostname: String, anchors: [SecCertificate], identity: IdentityMaterial?) {
        self.origin = origin; self.hostname = hostname; self.anchors = anchors; self.identity = identity
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // Never send an invitation or client identity to a redirected origin.
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }
    private func handle(_ challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.host.lowercased() == hostname.lowercased(), space.port == (origin.port ?? 443),
              challenge.previousFailureCount == 0 else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust {
            do {
                try CertificateTools.evaluate(trust, anchors: anchors, policy: SecPolicyCreateSSL(true, hostname as CFString))
                completionHandler(.useCredential, URLCredential(trust: trust))
            } catch { completionHandler(.cancelAuthenticationChallenge, nil) }
        } else if space.authenticationMethod == NSURLAuthenticationMethodClientCertificate, let identity {
            completionHandler(.useCredential, URLCredential(identity: identity.identity, certificates: identity.certificates, persistence: .forSession))
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
