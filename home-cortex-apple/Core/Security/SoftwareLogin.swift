import Foundation
import Security

struct LoginProfile: Sendable {
    let configuration: ClientConfiguration
    let caPEM: String
    static func bundled() throws -> LoginProfile {
        guard let config = Bundle.main.url(forResource: "Household", withExtension: "json"),
              let ca = Bundle.main.url(forResource: "HomeCortexCA", withExtension: "txt") else { throw ClientFailure.configuration }
        return try LoginProfile(configuration: ClientConfiguration.parse(Data(contentsOf: config)),
            caPEM: String(contentsOf: ca, encoding: .utf8))
    }
}

extension CredentialMetadata {
    func migratedForLAN(profile: LoginProfile) throws -> CredentialMetadata? {
        guard configuration.serverHostname == "home-cortex-0",
              configuration.serverEndpoint.port == 8443, configuration.bootstrapEndpoint.port == 8444,
              profile.configuration.serverHostname == "192.168.68.59" else { return nil }
        let old = try CertificateTools.certificates(pem: trustedCAPEM).map { SecCertificateCopyData($0) as Data }
        let known = try CertificateTools.certificates(pem: profile.caPEM).map { SecCertificateCopyData($0) as Data }
        guard old == known else { return nil }
        return CredentialMetadata(clientID: clientID, keyTag: keyTag, configuration: profile.configuration,
            certificatePEM: certificatePEM, caChainPEM: caChainPEM, trustedCAPEM: trustedCAPEM,
            expiresAt: expiresAt, authenticationRejected: authenticationRejected)
    }
}

struct SoftwareLoginBootstrap: Sendable {
    let configuration: ClientConfiguration
    let caPEM: String
    let invitationData: Data
    init(data: Data, profile: LoginProfile) throws {
        let object = try JSONValue.decode(data).object(required: ["configuration", "ca_pem", "invitation"])
        configuration = try ClientConfiguration.parse(JSONEncoder().encode(object.field("configuration")))
        guard configuration == profile.configuration else { throw ClientFailure.configuration }
        caPEM = try object.field("ca_pem").string()
        let anchors = try CertificateTools.certificates(pem: profile.caPEM).map { SecCertificateCopyData($0) as Data }
        let returned = try CertificateTools.certificates(pem: caPEM).map { SecCertificateCopyData($0) as Data }
        guard returned == anchors else { throw ClientFailure.invalidCertificate }
        invitationData = try JSONEncoder().encode(object.field("invitation"))
        _ = try ProvisioningInvitation(data: invitationData, configuration: configuration)
    }
}

protocol SoftwareLoginGateway: Sendable {
    func signIn(email: String, apiKey: String) async throws -> SoftwareLoginBootstrap
}

final class URLSessionSoftwareLogin: SoftwareLoginGateway, @unchecked Sendable {
    private let profile: LoginProfile
    private let session: URLSession
    private let delegate: TLSDelegate
    init(profile: LoginProfile) throws {
        try profile.configuration.validate()
        self.profile = profile
        delegate = TLSDelegate(origin: profile.configuration.bootstrapEndpoint,
            hostname: profile.configuration.serverHostname,
            anchors: try CertificateTools.certificates(pem: profile.caPEM), identity: nil)
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        config.tlsMaximumSupportedProtocolVersion = .TLSv13
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func signIn(email: String, apiKey: String) async throws -> SoftwareLoginBootstrap {
        guard !email.isEmpty, email.count <= 320, !apiKey.isEmpty, apiKey.count <= 4096,
              !apiKey.contains("\r"), !apiKey.contains("\n") else { throw ClientFailure.loginRejected }
        var request = URLRequest(url: profile.configuration.bootstrapEndpoint.appendingPathComponent("session/device-invitation"))
        request.httpMethod = "POST"
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(["email": email])
        do {
            let (bytes, raw) = try await session.bytes(for: request)
            guard let response = raw as? HTTPURLResponse else { throw ClientFailure.invalidResponse }
            if [401, 403].contains(response.statusCode) { throw ClientFailure.loginRejected }
            guard !(300..<400).contains(response.statusCode) else { throw ClientFailure.authenticationRequired }
            guard (200..<300).contains(response.statusCode) else { throw ClientFailure.transport }
            guard response.mimeType == "application/json" else { throw ClientFailure.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 131_072 else { throw ClientFailure.invalidResponse }
                data.append(byte)
            }
            return try SoftwareLoginBootstrap(data: data, profile: profile)
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            if [.cancelled, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                .serverCertificateNotYetValid, .secureConnectionFailed, .userCancelledAuthentication].contains(error.code) {
                throw ClientFailure.authenticationRequired
            }
            throw ClientFailure.transport
        }
    }
}
