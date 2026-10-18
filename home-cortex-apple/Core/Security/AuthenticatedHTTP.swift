import Foundation

/// Creates an identity-scoped session; each domain transport still owns its policy.
enum AuthenticatedHTTP {
    static func channel(origin: URL, hostname: String, caPEM: String, identity: IdentityMaterial?,
                        requestTimeout: TimeInterval, resourceTimeout: TimeInterval,
                        waitsForConnectivity: Bool = false,
                        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) throws
        -> (session: URLSession, delegate: TLSDelegate) {
        let delegate = TLSDelegate(origin: origin, hostname: hostname,
            anchors: try CertificateTools.certificates(pem: caPEM), identity: identity)
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        config.tlsMaximumSupportedProtocolVersion = .TLSv13
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = waitsForConnectivity
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = cachePolicy
        return (URLSession(configuration: config, delegate: delegate, delegateQueue: nil), delegate)
    }

    static func read<Bytes: AsyncSequence>(_ bytes: Bytes, limit: Int, failure: any Error) async throws -> Data
        where Bytes.Element == UInt8 {
        var data = Data()
        data.reserveCapacity(min(limit, 16_384))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw failure }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
}
