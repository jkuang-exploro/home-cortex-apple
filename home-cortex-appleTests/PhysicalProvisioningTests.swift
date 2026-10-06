import XCTest
import Security
@testable import HomeCortex

final class PhysicalProvisioningTests: XCTestCase {
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
