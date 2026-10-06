import Foundation
import Security

enum CertificateTools {
    static func certificates(pem: String) throws -> [SecCertificate] {
        guard pem.utf8.count <= 65_536 else { throw ClientFailure.invalidCertificate }
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var remaining = pem[...]
        var result: [SecCertificate] = []
        while let first = remaining.range(of: begin) {
            guard remaining[..<first.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let last = remaining.range(of: end, range: first.upperBound..<remaining.endIndex) else { throw ClientFailure.invalidCertificate }
            let base64 = remaining[first.upperBound..<last.lowerBound].filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: String(base64)),
                  let cert = SecCertificateCreateWithData(nil, der as CFData) else { throw ClientFailure.invalidCertificate }
            result.append(cert)
            remaining = remaining[last.upperBound...]
        }
        guard !result.isEmpty, result.count <= 8,
              remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientFailure.invalidCertificate }
        return result
    }

    static func evaluate(_ trust: SecTrust, anchors: [SecCertificate], policy: SecPolicy) throws {
        for anchor in anchors {
            let validity = try validity(anchor)
            guard validity.notBefore <= Date(), Date() < validity.notAfter else { throw ClientFailure.invalidCertificate }
        }
        guard !anchors.isEmpty, SecTrustSetPolicies(trust, policy) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else { throw ClientFailure.invalidCertificate }
    }

    static func validateClient(certificates: [SecCertificate], key: SecKey, anchors: [SecCertificate]) throws -> SecIdentity {
        guard let leaf = certificates.first else { throw ClientFailure.invalidCertificate }
        var trust: SecTrust?
        // SSL client policy checks clientAuth EKU as well as certificate validity.
        let policy = SecPolicyCreateSSL(false, nil)
        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess,
              let trust else { throw ClientFailure.invalidCertificate }
        try evaluate(trust, anchors: anchors, policy: policy)
        guard let identity = SecIdentityCreate(nil, leaf, key) else { throw ClientFailure.invalidCertificate }
        return identity
    }

    static func validity(_ certificate: SecCertificate) throws -> (notBefore: Date, notAfter: Date) {
        let root = try DERNode.parse(SecCertificateCopyData(certificate) as Data)
        let tbs = try root.children().first.unwrap()
        let fields = try tbs.children()
        let index = fields.first?.tag == 0xa0 ? 4 : 3
        guard fields.count > index else { throw ClientFailure.invalidCertificate }
        let validity = try fields[index].children()
        guard validity.count == 2 else { throw ClientFailure.invalidCertificate }
        return (try certificateDate(validity[0]), try certificateDate(validity[1]))
    }

    private static func certificateDate(_ node: DERNode) throws -> Date {
        guard [0x17, 0x18].contains(node.tag), let text = String(data: node.content, encoding: .ascii), text.hasSuffix("Z") else { throw ClientFailure.invalidCertificate }
        let expanded: String
        if node.tag == 0x17 {
            guard text.count == 13, let year = Int(text.prefix(2)) else { throw ClientFailure.invalidCertificate }
            expanded = (year >= 50 ? "19" : "20") + text
        } else { expanded = text }
        guard expanded.count == 15 else { throw ClientFailure.invalidCertificate }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMddHHmmss'Z'"
        f.isLenient = false
        guard let date = f.date(from: expanded) else { throw ClientFailure.invalidCertificate }
        return date
    }
}

enum PKCS10 {
    static func request(key: SecKey) throws -> String {
        guard let publicKey = SecKeyCopyPublicKey(key) else { throw ClientFailure.keyGeneration }
        var error: Unmanaged<CFError>?
        // Only the public X9.63 representation is exported; the private key is never exported.
        guard let rawPublic = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?, rawPublic.count == 65,
              rawPublic.first == 4 else { throw ClientFailure.keyGeneration }
        let ecAlgorithm = DER.sequence(DER.oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]) + DER.oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]))
        let spki = DER.sequence(ecAlgorithm + DER.bitString(rawPublic))
        let subject = DER.sequence(DER.wrap(0x31, DER.sequence(DER.oid([0x55, 0x04, 0x03]) + DER.wrap(0x0c, Data("home-cortex-apple".utf8)))))
        let info = DER.sequence(DER.wrap(0x02, Data([0])) + subject + spki + DER.wrap(0xa0, Data()))
        guard SecKeyIsAlgorithmSupported(key, .sign, .ecdsaSignatureMessageX962SHA256),
              let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, info as CFData, &error) as Data? else { throw ClientFailure.keyGeneration }
        let algorithm = DER.sequence(DER.oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]))
        let base64 = DER.sequence(info + algorithm + DER.bitString(signature)).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE REQUEST-----\n\(base64)\n-----END CERTIFICATE REQUEST-----\n"
    }
}

// DER encoding only. Cryptographic signing and certificate trust use Apple's Security APIs.
enum DER {
    static func wrap(_ tag: UInt8, _ content: Data) -> Data {
        var length = content.count
        var bytes: [UInt8] = []
        if length < 128 { bytes = [UInt8(length)] }
        else {
            while length > 0 { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 }
            bytes.insert(0x80 | UInt8(bytes.count), at: 0)
        }
        return Data([tag] + bytes) + content
    }
    static func sequence(_ content: Data) -> Data { wrap(0x30, content) }
    static func oid(_ bytes: [UInt8]) -> Data { wrap(0x06, Data(bytes)) }
    static func bitString(_ content: Data) -> Data { wrap(0x03, Data([0]) + content) }
}

struct DERNode {
    let tag: UInt8
    let content: Data
    let encoded: Data

    static func parse(_ data: Data) throws -> Self {
        var offset = 0
        let node = try read(Array(data), offset: &offset)
        guard offset == data.count else { throw ClientFailure.invalidCertificate }
        return node
    }
    func children() throws -> [DERNode] {
        let bytes = Array(content)
        var offset = 0
        var nodes: [Self] = []
        while offset < bytes.count { nodes.append(try Self.read(bytes, offset: &offset)) }
        return nodes
    }
    private static func read(_ bytes: [UInt8], offset: inout Int) throws -> Self {
        let start = offset
        guard offset + 2 <= bytes.count else { throw ClientFailure.invalidCertificate }
        let tag = bytes[offset]
        let first = bytes[offset + 1]
        offset += 2
        var length = Int(first)
        if first & 0x80 != 0 {
            let count = Int(first & 0x7f)
            guard count > 0, count <= 4, offset + count <= bytes.count, bytes[offset] != 0 else { throw ClientFailure.invalidCertificate }
            length = 0
            for byte in bytes[offset..<offset + count] { length = length * 256 + Int(byte) }
            offset += count
            guard length >= 128 else { throw ClientFailure.invalidCertificate }
        }
        guard length <= bytes.count - offset else { throw ClientFailure.invalidCertificate }
        let content = Data(bytes[offset..<offset + length])
        offset += length
        return Self(tag: tag, content: content, encoded: Data(bytes[start..<offset]))
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let value = self else { throw ClientFailure.invalidCertificate }
        return value
    }
}
