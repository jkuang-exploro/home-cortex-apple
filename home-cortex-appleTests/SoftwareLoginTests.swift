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
    private func legacyCredential(host: String = "192.168.68.59", body: String? = nil,
                                  rejected: Bool = false, expired: Bool = false) throws -> CredentialMetadata {
        let profile = try LoginProfile.bundled()
        let config = try ClientConfiguration.parse(Data("""
            {"server_endpoint":"https://\(host):8443","bootstrap_endpoint":"https://\(host):8444",
             "server_hostname":"\(host)","protocol_version":"1.0"}
            """.utf8))
        return CredentialMetadata(clientID: "client:existing-phone", keyTag: Data("same-device-key".utf8),
            configuration: config, certificatePEM: "same-cert", caChainPEM: profile.caPEM,
            trustedCAPEM: profile.caPEM, expiresAt: Date().addingTimeInterval(expired ? -3600 : 3600),
            authenticationRejected: rejected, visionObserveGranted: body == nil ? nil : true, embodimentID: body)
    }
    func testBundledProfileUsesTailscaleAndMigrationPreservesBothPrincipals() throws {
        let profile = try LoginProfile.bundled()
        XCTAssertEqual(profile.configuration.serverHostname, "home-cortex-0")
        XCTAssertEqual(profile.configuration.serverEndpoint.absoluteString, "https://home-cortex-0:8443")
        XCTAssertEqual(profile.configuration.bootstrapEndpoint.absoluteString, "https://home-cortex-0:8444")
        for body in [nil, "embodiment:existing-phone"] as [String?] {
            let old = try legacyCredential(body: body, rejected: true, expired: true)
            let migrated = try XCTUnwrap(old.migratedForTailscale(profile: profile))
            XCTAssertEqual(migrated.keyTag, old.keyTag)
            XCTAssertEqual(migrated.clientID, old.clientID)
            XCTAssertEqual(migrated.certificatePEM, old.certificatePEM)
            XCTAssertEqual(migrated.caChainPEM, old.caChainPEM)
            XCTAssertEqual(migrated.trustedCAPEM, old.trustedCAPEM)
            XCTAssertEqual(migrated.expiresAt, old.expiresAt)
            XCTAssertEqual(migrated.visionObserveGranted, old.visionObserveGranted)
            XCTAssertEqual(migrated.embodimentID, old.embodimentID)
            XCTAssertEqual(migrated.purpose, old.purpose)
            XCTAssertTrue(migrated.authenticationRejected)
            XCTAssertEqual(migrated.configuration, profile.configuration)
            XCTAssertNil(try migrated.migratedForTailscale(profile: profile))
            XCTAssertThrowsError(try migrated.validate())
        }
    }
    func testTailscaleMigrationRequiresKnownOriginPortsAndMatchingCA() throws {
        let profile = try LoginProfile.bundled()
        let old = try legacyCredential()
        let different = LoginProfile(configuration: profile.configuration, caPEM: try Self.profile().caPEM)
        XCTAssertNil(try old.migratedForTailscale(profile: different))
        XCTAssertNil(try legacyCredential(host: "other-host").migratedForTailscale(profile: profile))
        let encoded = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        for (from, to) in [(":8443", ":9443"), (":8444", ":9444")] {
            let custom = try JSONDecoder().decode(CredentialMetadata.self, from: Data(encoded.replacingOccurrences(of: from, with: to).utf8))
            XCTAssertNil(try custom.migratedForTailscale(profile: profile))
        }
        let customProfile = LoginProfile(configuration: try ClientConfiguration.parse(Data(
            String(decoding: try JSONEncoder().encode(profile.configuration), as: UTF8.self)
                .replacingOccurrences(of: "home-cortex-0", with: "other-host").utf8)), caPEM: profile.caPEM)
        XCTAssertNil(try old.migratedForTailscale(profile: customProfile))
        for bad in ["192.168.68.999", "192.168.068.59", "192.168.68"] {
            let configuration = String(decoding: try JSONEncoder().encode(old.configuration), as: UTF8.self)
            XCTAssertThrowsError(try ClientConfiguration.parse(Data(configuration.replacingOccurrences(of: "192.168.68.59", with: bad).utf8)))
        }
    }
    func testControllerPersistsTailscaleMigrationWithoutReenrollment() throws {
        for body in [nil, "embodiment:existing-phone"] as [String?] {
            let old = try legacyCredential(body: body)
            let store = try ProvisioningMemoryStore()
            store.metadata = old
            let model = ConnectionController(store: store, purpose: old.purpose, automaticallyConnect: false)
            XCTAssertEqual(model.state, .disconnected)
            XCTAssertEqual(model.configuration, try LoginProfile.bundled().configuration)
            XCTAssertEqual(store.metadata?.configuration, model.configuration)
            XCTAssertEqual(store.metadata?.clientID, old.clientID)
            XCTAssertEqual(store.metadata?.keyTag, old.keyTag)
            XCTAssertEqual(store.metadata?.embodimentID, old.embodimentID)
            XCTAssertEqual(store.prepareCount, 0)
            let reopened = ConnectionController(store: store, purpose: old.purpose, automaticallyConnect: false)
            XCTAssertEqual(reopened.configuration, model.configuration)
            XCTAssertEqual(reopened.credential?.clientID, old.clientID)
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
