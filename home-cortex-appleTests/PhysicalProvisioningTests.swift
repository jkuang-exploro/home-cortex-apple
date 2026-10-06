import XCTest
import Security
@testable import HomeCortex

final class PhysicalProvisioningTests: XCTestCase {
    @MainActor
    func testExistingPhoneCredentialConnectsDirectlyToFixedLAN() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the provisioned physical phone and household Wi-Fi.")
        #else
        let connection = AppRuntime.connection
        let credential = try XCTUnwrap(connection.credential)
        XCTAssertEqual(credential.configuration, try LoginProfile.bundled().configuration)
        let originalKey = credential.keyTag
        connection.setForeground(true)
        if connection.displayedState != .connected { connection.connect() }
        defer { connection.setForeground(false) }
        for _ in 0..<450 {
            if connection.displayedState == .connected { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(connection.displayedState, .connected)
        XCTAssertEqual(connection.session?.clientID, credential.clientID)
        XCTAssertNil(connection.session?.embodimentID)
        let stored = try XCTUnwrap(KeychainCredentialStore().load())
        XCTAssertEqual(stored.keyTag, originalKey)
        XCTAssertEqual(stored.clientID, credential.clientID)
        try KeychainCredentialStore().validateStoredIdentity(stored)
        #endif
    }

    @MainActor
    func testInstalledPhysicalCredentialAndSecureEnclaveKeySurviveStoreRecreation() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Acceptance check requires the enrolled physical iPhone.")
        #else
        let store = KeychainCredentialStore()
        guard let credential = try store.load() else { throw XCTSkip("Import the real software invitation on the phone first.") }
        try credential.validate()
        try store.validateStoredIdentity(credential)
        let material = try store.identity(for: credential)
        var key: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(material.identity, &key), errSecSuccess)
        let attributes = SecKeyCopyAttributes(try XCTUnwrap(key)) as? [String: Any]
        XCTAssertEqual(attributes?[kSecAttrTokenID as String] as? String, kSecAttrTokenIDSecureEnclave as String)
        let reopened = KeychainCredentialStore()
        let persisted = try XCTUnwrap(reopened.load())
        XCTAssertEqual(persisted.clientID, credential.clientID)
        XCTAssertEqual(persisted.keyTag, credential.keyTag)
        try reopened.validateStoredIdentity(persisted)
        let controller = ConnectionController(store: reopened)
        XCTAssertEqual(controller.provisioning, .provisioned)
        XCTAssertNil(controller.session)
        #endif
    }
}
