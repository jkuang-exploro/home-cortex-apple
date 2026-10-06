import XCTest
@testable import HomeCortex

@MainActor
final class SoftwareLoginTests: XCTestCase {
    static func profile() throws -> LoginProfile {
        LoginProfile(configuration: try V1ProtocolTests.config(),
            caPEM: String(decoding: try V1ProtocolTests.fixtureData("test-ca", extension: "txt"), as: UTF8.self))
    }
    static func response() throws -> Data {
        let profile = try profile()
        return try JSONEncoder().encode(JSONValue.object([
            "configuration": JSONValue.decode(JSONEncoder().encode(profile.configuration)),
            "ca_pem": .string(profile.caPEM), "invitation": JSONValue.decode(ProvisioningTests.invitation())]))
    }
    func testLoginImportsTrustAndProvisionsWithoutManualFiles() async throws {
        let store = try ProvisioningMemoryStore()
        let gateway = LoginStub(bootstrap: try SoftwareLoginBootstrap(data: Self.response(), profile: Self.profile()))
        let transport = ProvisioningTransport()
        let model = ConnectionController(store: store, factory: { _, _, _ in transport })
        await model.signIn(email: " owner@example.com ", apiKey: "memory-only-key", gateway: gateway)
        XCTAssertEqual(model.provisioning, .provisioned)
        XCTAssertEqual(store.configurationWrites, 1)
        XCTAssertEqual(store.caWrites, 1)
        XCTAssertEqual(store.ca, try Self.profile().caPEM)
        XCTAssertEqual(store.prepareCount, 1)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(XCTUnwrap(store.metadata)), as: UTF8.self).contains("memory-only-key"))
        XCTAssertFalse(model.signingIn)
        await model.disconnect()
    }
    func testRejectedLoginAndBackgroundResponseCreateNoKeyOrCredential() async throws {
        for rejected in [true, false] {
            let store = try ProvisioningMemoryStore()
            let gateway = LoginStub(bootstrap: try SoftwareLoginBootstrap(data: Self.response(), profile: Self.profile()), rejected: rejected)
            let model = ConnectionController(store: store, factory: { _, _, _ in ProvisioningTransport() })
            let work = Task { await model.signIn(email: "owner@example.com", apiKey: "secret", gateway: gateway) }
            if !rejected {
                for _ in 0..<100 {
                    if model.signingIn { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                model.setForeground(false)
            }
            await work.value
            XCTAssertEqual(store.prepareCount, 0)
            XCTAssertEqual(store.caWrites, 0)
            XCTAssertNil(model.credential)
            if rejected { XCTAssertEqual(model.state, .failed(.loginRejected)) }
        }
    }
    func testBootstrapRejectsChangedCAOriginAndExpandedGrants() throws {
        let profile = try Self.profile()
        let text = String(decoding: try Self.response(), as: UTF8.self)
        XCTAssertThrowsError(try SoftwareLoginBootstrap(data: Data(text.replacingOccurrences(of: "home-cortex-0", with: "other-host").utf8), profile: profile))
        XCTAssertThrowsError(try SoftwareLoginBootstrap(data: Data(text.replacingOccurrences(of: "session", with: "execute").utf8), profile: profile))
        let other = String(decoding: try V1ProtocolTests.fixtureData("test-other-ca", extension: "txt"), as: UTF8.self)
        XCTAssertThrowsError(try SoftwareLoginBootstrap(data: Self.response(), profile: LoginProfile(configuration: profile.configuration, caPEM: other)))
    }
    func testBundledProfileUsesFixedLANAndMigrationPreservesDeviceIdentity() throws {
        let profile = try LoginProfile.bundled()
        XCTAssertEqual(profile.configuration.serverHostname, "192.168.68.59")
        XCTAssertEqual(profile.configuration.serverEndpoint.absoluteString, "https://192.168.68.59:8443")
        XCTAssertEqual(profile.configuration.bootstrapEndpoint.absoluteString, "https://192.168.68.59:8444")
        let old = CredentialMetadata(clientID: "client:existing-phone", keyTag: Data("same-device-key".utf8),
            configuration: try V1ProtocolTests.config(), certificatePEM: "same-cert", caChainPEM: profile.caPEM,
            trustedCAPEM: profile.caPEM, expiresAt: Date().addingTimeInterval(3600), authenticationRejected: true)
        let migrated = try XCTUnwrap(old.migratedForLAN(profile: profile))
        XCTAssertEqual(migrated.keyTag, old.keyTag)
        XCTAssertEqual(migrated.clientID, old.clientID)
        XCTAssertEqual(migrated.certificatePEM, old.certificatePEM)
        XCTAssertEqual(migrated.expiresAt, old.expiresAt)
        XCTAssertTrue(migrated.authenticationRejected)
        XCTAssertEqual(migrated.configuration, profile.configuration)
        XCTAssertNil(try old.migratedForLAN(profile: Self.profile()))
        let different = LoginProfile(configuration: profile.configuration, caPEM: try Self.profile().caPEM)
        XCTAssertNil(try old.migratedForLAN(profile: different))
        for bad in ["192.168.68.999", "192.168.068.59", "192.168.68"] {
            let encoded = String(decoding: try JSONEncoder().encode(profile.configuration), as: UTF8.self)
            XCTAssertThrowsError(try ClientConfiguration.parse(Data(encoded.replacingOccurrences(of: "192.168.68.59", with: bad).utf8)))
        }
    }
}

private struct LoginStub: SoftwareLoginGateway {
    let bootstrap: SoftwareLoginBootstrap
    var rejected = false
    func signIn(email: String, apiKey: String) async throws -> SoftwareLoginBootstrap {
        try await Task.sleep(for: .milliseconds(80))
        if rejected { throw ClientFailure.loginRejected }
        return bootstrap
    }
}
