import XCTest
import Security
@testable import HomeCortex

final class SecurityTests: XCTestCase {
    private func fixtureCertificates(_ name: String) throws -> [SecCertificate] {
        let pem = String(decoding: try V1ProtocolTests.fixtureData(name, extension: "txt"), as: UTF8.self)
        return try CertificateTools.certificates(pem: pem)
    }
    private func makeTrust(_ certificates: [SecCertificate], hostname: String) throws -> SecTrust {
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, hostname as CFString), &trust), errSecSuccess)
        return try XCTUnwrap(trust)
    }

    func testPinnedCAHostnameAndExpiryAreEnforced() throws {
        let ca = try fixtureCertificates("test-ca")
        let server = try fixtureCertificates("test-server")
        let trust = try makeTrust(server, hostname: "cortex.test")
        XCTAssertNoThrow(try CertificateTools.evaluate(trust, anchors: ca, policy: SecPolicyCreateSSL(true, "cortex.test" as CFString)))
        let wrongHost = try makeTrust(server, hostname: "other.test")
        XCTAssertThrowsError(try CertificateTools.evaluate(wrongHost, anchors: ca, policy: SecPolicyCreateSSL(true, "other.test" as CFString)))
        let unknownCA = try makeTrust(server, hostname: "cortex.test")
        let otherCA = try fixtureCertificates("test-other-ca")
        XCTAssertThrowsError(try CertificateTools.evaluate(unknownCA, anchors: otherCA, policy: SecPolicyCreateSSL(true, "cortex.test" as CFString)))
        let validity = try CertificateTools.validity(XCTUnwrap(server.first))
        XCTAssertGreaterThan(validity.notAfter, validity.notBefore)
        XCTAssertEqual(SecTrustSetVerifyDate(trust, validity.notAfter.addingTimeInterval(1) as CFDate), errSecSuccess)
        XCTAssertThrowsError(try CertificateTools.evaluate(trust, anchors: ca, policy: SecPolicyCreateSSL(true, "cortex.test" as CFString)))
    }

    func testMalformedCertificatesAndDERAreRejected() {
        for input in ["", "arbitrary text", "-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----"] {
            XCTAssertThrowsError(try CertificateTools.certificates(pem: input))
        }
        for data in [Data(), Data([0x30, 0x80]), Data([0x30, 0x82, 0x7f, 0xff]), Data([0x30, 0x01])] {
            XCTAssertThrowsError(try DERNode.parse(data))
        }
    }

    func testPKCS10ContainsMatchingPublicKeyAndVerifiableProofOfPossession() throws {
        let key = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256] as CFDictionary, nil))
        let pem = try PKCS10.request(key: key)
        let base64 = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let der = try XCTUnwrap(Data(base64Encoded: base64))
        let parts = try DERNode.parse(der).children()
        XCTAssertEqual(parts.count, 3)
        let info = try parts[0].children()
        XCTAssertEqual(info.count, 4)
        XCTAssertEqual(info[3].tag, 0xa0)
        XCTAssertTrue(info[3].content.isEmpty)
        let spki = try info[2].children()
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        XCTAssertEqual(Data(spki[1].content.dropFirst()), SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, parts[0].encoded as CFData,
            Data(parts[2].content.dropFirst()) as CFData, nil))
        XCTAssertFalse(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, Data("tampered".utf8) as CFData,
            Data(parts[2].content.dropFirst()) as CFData, nil))
    }

    @MainActor
    func testKeychainMetadataWithoutPrivateKeyCannotClaimProvisioned() throws {
        let service = "HomeCortex.SecurityTests." + UUID().uuidString
        let store = KeychainCredentialStore(service: service)
        defer { try? store.forget() }
        let certificate = String(decoding: try V1ProtocolTests.fixtureData("test-server", extension: "txt"), as: UTF8.self)
        let ca = String(decoding: try V1ProtocolTests.fixtureData("test-ca", extension: "txt"), as: UTF8.self)
        let metadata = CredentialMetadata(clientID: "client:missing-key", keyTag: Data((service + "." + UUID().uuidString).utf8),
            configuration: try V1ProtocolTests.config(), certificatePEM: certificate, caChainPEM: ca, trustedCAPEM: ca,
            expiresAt: Date().addingTimeInterval(3600))
        try store.save(metadata)
        XCTAssertNotNil(try store.load())
        let model = ConnectionController(store: store)
        XCTAssertEqual(model.provisioning, .failed(.invalidCertificate))
        XCTAssertNotEqual(model.displayedState, .connected)
    }

    @MainActor
    func testPendingCSRAndKeyReferenceSurviveStoreRecreationWithoutPersistingToken() throws {
        let service = "HomeCortex.SecurityTests." + UUID().uuidString
        let store = KeychainCredentialStore(service: service)
        defer { try? store.forget() }
        let config = try V1ProtocolTests.config()
        let invitation = try ProvisioningInvitation(data: V1ProtocolTests.invitationData(), configuration: config)
        let ca = String(decoding: try V1ProtocolTests.fixtureData("test-ca", extension: "txt"), as: UTF8.self)
        let pending = try store.prepare(invitation: invitation, configuration: config, caPEM: ca)
        let reopened = KeychainCredentialStore(service: service)
        let retried = try reopened.prepare(invitation: invitation, configuration: config, caPEM: ca)
        XCTAssertEqual(retried.keyTag, pending.keyTag)
        XCTAssertEqual(retried.csrPEM, pending.csrPEM)
        let serialized = String(decoding: try JSONEncoder().encode(pending), as: UTF8.self)
        XCTAssertFalse(serialized.contains(invitation.token))
        var keyRef: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching([kSecClass: kSecClassKey, kSecAttrApplicationTag: pending.keyTag,
            kSecReturnRef: true] as CFDictionary, &keyRef), errSecSuccess)
        let attributes = SecKeyCopyAttributes(try XCTUnwrap(keyRef) as! SecKey) as? [String: Any]
        #if !targetEnvironment(simulator)
        XCTAssertEqual(attributes?[kSecAttrTokenID as String] as? String, kSecAttrTokenIDSecureEnclave as String)
        #else
        XCTAssertNotNil(attributes)
        #endif
    }
}
