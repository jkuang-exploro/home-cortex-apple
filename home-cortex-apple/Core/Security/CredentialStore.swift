import Foundation
import Security

struct CredentialMetadata: Codable, Sendable {
    let clientID: String
    let keyTag: Data
    let configuration: ClientConfiguration
    let certificatePEM: String
    let caChainPEM: String
    let trustedCAPEM: String
    let expiresAt: Date
    var authenticationRejected = false

    func validate(now: Date = Date()) throws {
        try configuration.validate()
        guard clientID.range(of: "^client:[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)*$", options: .regularExpression) != nil,
              !keyTag.isEmpty else { throw ClientFailure.invalidCertificate }
        if authenticationRejected { throw ClientFailure.authenticationRequired }
        guard now < expiresAt else { throw ClientFailure.credentialExpired }
    }
}

struct PendingEnrollment: Codable {
    let invitationID: String
    let keyTag: Data
    let csrPEM: String
    let configuration: ClientConfiguration
    let trustedCAPEM: String
}

struct IdentityMaterial: @unchecked Sendable {
    let identity: SecIdentity
    let certificates: [SecCertificate]
}

@MainActor
protocol CredentialStoring {
    func load() throws -> CredentialMetadata?
    func save(_ metadata: CredentialMetadata) throws
    func identity(for metadata: CredentialMetadata) throws -> IdentityMaterial
    func validateStoredIdentity(_ metadata: CredentialMetadata) throws
    func prepare(invitation: ProvisioningInvitation, configuration: ClientConfiguration, caPEM: String) throws -> PendingEnrollment
    func prepare(invitation: ProvisioningInvitation, configuration: ClientConfiguration, caPEM: String,
                 progress: (ProvisioningState) -> Void) throws -> PendingEnrollment
    func finish(bundle: EnrollmentBundle, pending: PendingEnrollment) throws -> CredentialMetadata
    func trustedCA() throws -> String?
    func storeTrustedCA(_ pem: String) throws
    func configuration() throws -> ClientConfiguration?
    func storeConfiguration(_ configuration: ClientConfiguration) throws
    func forget() throws
}

extension CredentialStoring {
    func validateStoredIdentity(_ metadata: CredentialMetadata) throws { try metadata.validate() }
    func prepare(invitation: ProvisioningInvitation, configuration: ClientConfiguration, caPEM: String,
                 progress: (ProvisioningState) -> Void) throws -> PendingEnrollment {
        progress(.generatingKey)
        let pending = try prepare(invitation: invitation, configuration: configuration, caPEM: caPEM)
        progress(.generatingCSR)
        return pending
    }
}

@MainActor
final class KeychainCredentialStore: CredentialStoring {
    private let service: String
    init(service: String = (Bundle.main.bundleIdentifier ?? "com.jiankuang.homecortex") + ".v1") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    private func read<T: Decodable>(_ account: String, as: T.Type) throws -> T? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw ClientFailure.secureStorage(status) }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw ClientFailure.invalidCertificate }
        return value
    }
    private func write<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let changes = [kSecValueData as String: data]
        var status = SecItemUpdate(query(account) as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ClientFailure.secureStorage(status) }
    }
    private func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard [errSecSuccess, errSecItemNotFound].contains(status) else { throw ClientFailure.secureStorage(status) }
    }
    private func key(_ tag: Data) throws -> SecKey {
        let q: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag,
                               kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecReturnRef as String: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { throw ClientFailure.invalidCertificate }
        guard status == errSecSuccess, let item else { throw ClientFailure.secureStorage(status) }
        return item as! SecKey
    }
    private func deleteKey(_ tag: Data) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)
        guard [errSecSuccess, errSecItemNotFound].contains(status) else { throw ClientFailure.secureStorage(status) }
    }

    func load() throws -> CredentialMetadata? { try read("credential", as: CredentialMetadata.self) }
    func save(_ metadata: CredentialMetadata) throws { try write(metadata, account: "credential") }
    func trustedCA() throws -> String? { try read("trusted-ca", as: String.self) }
    func storeTrustedCA(_ pem: String) throws {
        _ = try CertificateTools.certificates(pem: pem)
        guard try load() == nil else { throw ClientFailure.configuration }
        try write(pem, account: "trusted-ca")
    }
    func configuration() throws -> ClientConfiguration? { try read("configuration", as: ClientConfiguration.self) }
    func storeConfiguration(_ configuration: ClientConfiguration) throws {
        try configuration.validate()
        guard try load() == nil else { throw ClientFailure.configuration }
        try write(configuration, account: "configuration")
    }
    func identity(for metadata: CredentialMetadata) throws -> IdentityMaterial {
        try metadata.validate()
        let certificates = try CertificateTools.certificates(pem: metadata.certificatePEM)
        let anchors = try CertificateTools.certificates(pem: metadata.trustedCAPEM)
        let chain = try CertificateTools.certificates(pem: metadata.caChainPEM)
        let identity = try CertificateTools.validateClient(certificates: certificates + chain, key: key(metadata.keyTag), anchors: anchors)
        return IdentityMaterial(identity: identity, certificates: Array((certificates + chain).dropFirst()))
    }

    func validateStoredIdentity(_ metadata: CredentialMetadata) throws {
        try metadata.validate()
        let leaf = try CertificateTools.certificates(pem: metadata.certificatePEM).first
        guard let leaf, SecIdentityCreate(nil, leaf, try key(metadata.keyTag)) != nil else { throw ClientFailure.invalidCertificate }
    }

    func prepare(invitation: ProvisioningInvitation, configuration: ClientConfiguration, caPEM: String) throws -> PendingEnrollment {
        try prepare(invitation: invitation, configuration: configuration, caPEM: caPEM, progress: { _ in })
    }

    func prepare(invitation: ProvisioningInvitation, configuration: ClientConfiguration, caPEM: String,
                 progress: (ProvisioningState) -> Void) throws -> PendingEnrollment {
        guard try load() == nil else { throw ClientFailure.configuration }
        if let pending = try read("pending", as: PendingEnrollment.self) {
            if pending.invitationID == invitation.invitationID {
                guard pending.configuration == configuration, pending.trustedCAPEM == caPEM else { throw ClientFailure.configuration }
                _ = try key(pending.keyTag)
                return pending // Exact CSR is retained for invitation-consumption retries.
            }
            try deleteKey(pending.keyTag)
            try delete("pending")
        }
        let tag = Data((service + "." + UUID().uuidString).utf8)
        progress(.generatingKey)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &error) else { throw ClientFailure.keyGeneration }
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: tag, kSecAttrAccessControl as String: access]
        ]
        #if !targetEnvironment(simulator)
        attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        #endif
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw ClientFailure.keyGeneration }
        do {
            progress(.generatingCSR)
            let pending = PendingEnrollment(invitationID: invitation.invitationID, keyTag: tag, csrPEM: try PKCS10.request(key: privateKey), configuration: configuration, trustedCAPEM: caPEM)
            try write(pending, account: "pending")
            return pending
        } catch {
            try? deleteKey(tag)
            throw error
        }
    }

    func finish(bundle: EnrollmentBundle, pending: PendingEnrollment) throws -> CredentialMetadata {
        let certificates = try CertificateTools.certificates(pem: bundle.certificatePEM)
        let anchors = try CertificateTools.certificates(pem: pending.trustedCAPEM)
        let chain = try CertificateTools.certificates(pem: bundle.caChainPEM)
        _ = try CertificateTools.validateClient(certificates: certificates + chain, key: key(pending.keyTag), anchors: anchors)
        guard let leaf = certificates.first else { throw ClientFailure.invalidCertificate }
        let validity = try CertificateTools.validity(leaf)
        guard validity.notBefore <= Date() else { throw ClientFailure.invalidCertificate }
        let metadata = CredentialMetadata(clientID: bundle.clientID, keyTag: pending.keyTag, configuration: pending.configuration,
            certificatePEM: bundle.certificatePEM, caChainPEM: bundle.caChainPEM, trustedCAPEM: pending.trustedCAPEM,
            expiresAt: min(validity.notAfter, bundle.expiresAt))
        try metadata.validate()
        try save(metadata) // Atomic credential record commits before the retry record is removed.
        try? delete("pending")
        return metadata
    }

    func forget() throws {
        if let metadata = try load() { try deleteKey(metadata.keyTag) }
        if let pending = try read("pending", as: PendingEnrollment.self) { try deleteKey(pending.keyTag) }
        try delete("credential")
        try delete("pending")
        // Retain operator-selected public trust/configuration; no remembered ID grants authority.
    }
}
