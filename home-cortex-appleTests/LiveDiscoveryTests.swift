import XCTest
import Security
@testable import HomeCortex

final class LiveDiscoveryTests: XCTestCase {
    @MainActor
    func testOperatorTrustedDiscoveryRemainsUnprovisioned() async throws {
        guard let url = Bundle(for: Self.self).url(forResource: "live-ca", withExtension: "txt", subdirectory: "Fixtures") else {
            throw XCTSkip("Optional live test: supply the operator's public CA as ignored Fixtures/live-ca.txt.")
        }
        let service = "HomeCortex.LiveDiscoveryTests." + UUID().uuidString
        let store = KeychainCredentialStore(service: service)
        defer {
            _ = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
        }
        try store.storeConfiguration(XCTUnwrap(ClientConfiguration.bundled()))
        try store.storeTrustedCA(String(contentsOf: url, encoding: .utf8))
        let model = ConnectionController(store: store)
        await model.discover()
        XCTAssertEqual(model.discovery, .compatible)
        XCTAssertEqual(model.state, .unconfigured, "Trusted discovery must not claim authenticated connection")
        XCTAssertNil(model.session)
        XCTAssertNil(model.credential)
        // Exercise the actual bundled CA/IP SAN login transport without a real key.
        let login = try URLSessionSoftwareLogin(profile: LoginProfile.bundled())
        do {
            _ = try await login.signIn(email: "invalid@example.com", apiKey: "invalid-live-test-key")
            XCTFail("Invalid web credentials must be rejected")
        } catch {
            XCTAssertEqual(error as? ClientFailure, .loginRejected)
        }
    }
}
