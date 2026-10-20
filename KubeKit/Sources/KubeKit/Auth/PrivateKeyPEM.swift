import Foundation

/// Normalises the private-key formats a kubeconfig can carry into one the
/// platform's importer accepts.
///
/// This is pure parsing and lives here, above the keychain, so it can be tested
/// without Security, a keychain, or a device.
///
/// It exists because the formats differ in ways that are invisible until the TLS
/// handshake fails. macOS's PEM importer reads RSA PKCS#1, RSA PKCS#8 and EC SEC1
/// directly, but refuses an EC key in PKCS#8 — which is what several current tools
/// emit. The unwrapping below turns that one case into a form it does accept.
public enum PrivateKeyPEM {
    public enum Format: Hashable, Sendable {
        case rsaPKCS1          // -----BEGIN RSA PRIVATE KEY-----
        case pkcs8             // -----BEGIN PRIVATE KEY-----
        case ecSEC1            // -----BEGIN EC PRIVATE KEY-----
        case encrypted         // -----BEGIN ENCRYPTED PRIVATE KEY-----

        public var displayName: String {
            switch self {
            case .rsaPKCS1: return "RSA PKCS#1"
            case .pkcs8: return "PKCS#8"
            case .ecSEC1: return "EC SEC1"
            case .encrypted: return "encrypted PKCS#8"
            }
        }
    }

    public static func format(of pem: String) -> Format? {
        if pem.contains("BEGIN ENCRYPTED PRIVATE KEY") { return .encrypted }
        if pem.contains("BEGIN RSA PRIVATE KEY") { return .rsaPKCS1 }
        if pem.contains("BEGIN EC PRIVATE KEY") { return .ecSEC1 }
        if pem.contains("BEGIN PRIVATE KEY") { return .pkcs8 }
        return nil
    }

    /// Returns a PEM the platform importer accepts, converting if it has to.
    ///
    /// An encrypted key is refused by name: there is no passphrase to use, and a
    /// precise refusal is more actionable than a handshake failure later.
    public static func importable(_ pem: String) throws -> String {
        guard let format = format(of: pem) else {
            throw KubernetesError.invalidConfiguration(
                reason: "The client key is not in a recognised PEM format."
            )
        }
        switch format {
        case .encrypted:
            throw KubernetesError.unsupportedAuthentication(
                method: "Encrypted client key",
                platform: .macOS
            )
        case .rsaPKCS1, .ecSEC1:
            return pem
        case .pkcs8:
            guard let der = body(of: pem) else {
                throw KubernetesError.invalidConfiguration(
                    reason: "The client key is not valid base64."
                )
            }
            // An RSA key in PKCS#8 is read as-is; only EC needs rebuilding.
            guard let rebuilt = ecSEC1(fromPKCS8: der) else { return pem }
            return encode(rebuilt, label: "EC PRIVATE KEY")
        }
    }

    // MARK: - PEM

    public static func body(of pem: String) -> Data? {
        let base64 = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: base64)
    }

    /// The RSA representation Security accepts on iOS: a PKCS#1 key, with a
    /// PKCS#8 wrapper removed only after checking its algorithm identifier.
    public static func rsaPKCS1DER(_ pem: String) throws -> Data {
        guard let der = body(of: pem) else {
            throw KubernetesError.invalidConfiguration(reason: "The client key is not valid base64.")
        }
        if format(of: pem) == .rsaPKCS1 { return der }
        guard format(of: pem) == .pkcs8 else {
            throw KubernetesError.invalidConfiguration(reason: "The client key is not an unencrypted RSA key.")
        }
        var outer = DERReader(der)
        guard let sequence = outer.readElement(), sequence.tag == .sequence else {
            throw KubernetesError.invalidConfiguration(reason: "The client key has an invalid PKCS#8 structure.")
        }
        var contents = DERReader(sequence.body)
        guard let version = contents.readElement(), version.tag == .integer,
              let algorithm = contents.readElement(), algorithm.tag == .sequence,
              let key = contents.readElement(), key.tag == .octetString else {
            throw KubernetesError.invalidConfiguration(reason: "The client key has an invalid PKCS#8 structure.")
        }
        var identifier = DERReader(algorithm.body)
        guard let oid = identifier.readElement(), oid.tag == .objectIdentifier,
              oid.body == Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]) else {
            throw KubernetesError.invalidConfiguration(reason: "The client key does not use the RSA algorithm.")
        }
        return key.body
    }

    static func encode(_ der: Data, label: String) -> String {
        let base64 = der.base64EncodedString(
            options: [.lineLength64Characters, .endLineWithLineFeed]
        )
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----\n"
    }

    // MARK: - PKCS#8 to SEC1

    /// Rebuilds an EC key as SEC1, putting back the curve the PKCS#8 wrapper holds.
    ///
    /// `PrivateKeyInfo` keeps the curve in its algorithm identifier and the key in
    /// an octet string, and the key inside usually omits the curve. Moving it back
    /// in is what makes the result self-describing enough to import. Returns nil for
    /// anything that is not an EC key in this shape, including RSA.
    static func ecSEC1(fromPKCS8 der: Data) -> Data? {
        var outer = DERReader(der)
        guard outer.readSequenceHeader() else { return nil }
        guard outer.readElement() != nil else { return nil }                 // version
        guard let algorithm = outer.readElement(), algorithm.tag == .sequence else { return nil }
        guard let wrapped = outer.readElement(), wrapped.tag == .octetString else { return nil }

        var identifier = DERReader(algorithm.body)
        guard let oid = identifier.readElement(), oid.tag == .objectIdentifier else { return nil }
        guard oid.body == Self.ecPublicKeyOID else { return nil }
        guard let curve = identifier.readElement(), curve.tag == .objectIdentifier else { return nil }

        var key = DERReader(wrapped.body)
        guard key.readSequenceHeader() else { return nil }
        guard let version = key.readElement(), version.tag == .integer else { return nil }
        guard let scalar = key.readElement(), scalar.tag == .octetString else { return nil }

        var rebuilt = DERWriter.element(.integer, version.body)
        rebuilt += DERWriter.element(.octetString, scalar.body)
        rebuilt += DERWriter.element(
            .contextSpecificConstructed0,
            DERWriter.element(.objectIdentifier, curve.body)
        )
        // Carry the public key through when the key had one; it is optional, and a
        // key without it still imports.
        while let next = key.readElement() {
            if next.tag == .contextSpecificConstructed1 {
                rebuilt += DERWriter.element(.contextSpecificConstructed1, next.body)
                break
            }
        }
        return DERWriter.element(.sequence, rebuilt)
    }

    /// `1.2.840.10045.2.1` — id-ecPublicKey.
    static let ecPublicKeyOID = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
}

// MARK: - Just enough DER

enum DERTag: UInt8 {
    case integer = 0x02
    case octetString = 0x04
    case objectIdentifier = 0x06
    case sequence = 0x30
    case contextSpecificConstructed0 = 0xA0
    case contextSpecificConstructed1 = 0xA1
}

/// A reader for the handful of DER shapes this file needs. Not a general parser,
/// and deliberately so: it refuses anything it does not recognise.
struct DERReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func readSequenceHeader() -> Bool {
        guard index < bytes.count, bytes[index] == DERTag.sequence.rawValue else { return false }
        index += 1
        return readLength() != nil
    }

    mutating func readElement() -> (tag: DERTag, body: Data)? {
        guard index < bytes.count, let tag = DERTag(rawValue: bytes[index]) else { return nil }
        index += 1
        guard let length = readLength(), index + length <= bytes.count else { return nil }
        defer { index += length }
        return (tag, Data(bytes[index..<(index + length)]))
    }

    private mutating func readLength() -> Int? {
        guard index < bytes.count else { return nil }
        let first = bytes[index]
        index += 1
        if first & 0x80 == 0 { return Int(first) }
        let count = Int(first & 0x7F)
        // A length needing more than four bytes is larger than any key, and more
        // likely a malformed file than a real one.
        guard count > 0, count <= 4, index + count <= bytes.count else { return nil }
        var value = 0
        for _ in 0..<count {
            value = (value << 8) | Int(bytes[index])
            index += 1
        }
        return value
    }
}

enum DERWriter {
    static func element(_ tag: DERTag, _ body: Data) -> Data {
        Data([tag.rawValue] + length(body.count)) + body
    }

    private static func length(_ count: Int) -> [UInt8] {
        guard count >= 0x80 else { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
}
