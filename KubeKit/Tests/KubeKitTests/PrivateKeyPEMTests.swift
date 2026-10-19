import Security
import CryptoKit
import Foundation
import Testing
import KubeModels
@testable import KubeKit

/// Keys are generated here rather than checked in: a tool whose purpose is careful
/// credential handling should not carry private keys in its own repository, even
/// throwaway ones.
@Suite("PrivateKeyPEM")
struct PrivateKeyPEMTests {
    private func pem(_ der: Data, _ label: String) -> String {
        PrivateKeyPEM.encode(der, label: label)
    }

    // MARK: - Format detection

    @Test("Recognises each PEM header a kubeconfig can carry")
    func detectsFormats() {
        #expect(PrivateKeyPEM.format(of: "-----BEGIN RSA PRIVATE KEY-----\nAA==\n-----END RSA PRIVATE KEY-----") == .rsaPKCS1)
        #expect(PrivateKeyPEM.format(of: "-----BEGIN EC PRIVATE KEY-----\nAA==\n-----END EC PRIVATE KEY-----") == .ecSEC1)
        #expect(PrivateKeyPEM.format(of: "-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----") == .pkcs8)
        #expect(PrivateKeyPEM.format(of: "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAA==\n-----END ENCRYPTED PRIVATE KEY-----") == .encrypted)
        #expect(PrivateKeyPEM.format(of: "not a pem at all") == nil)
    }

    @Test("An encrypted key is refused by name, not left to fail in the handshake")
    func refusesEncryptedKeys() {
        // There is no passphrase to use, so this can never work. Saying which format
        // it is beats a TLS error the user cannot act on.
        #expect(throws: KubernetesError.self) {
            _ = try PrivateKeyPEM.importable(
                "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAA==\n-----END ENCRYPTED PRIVATE KEY-----"
            )
        }
    }

    @Test("An unrecognised blob is refused")
    func refusesGarbage() {
        #expect(throws: KubernetesError.self) { _ = try PrivateKeyPEM.importable("hello") }
    }

    // MARK: - Formats that pass through unchanged

    @Test("RSA PKCS#1 and EC SEC1 are already importable and are left alone")
    func passesThroughNativeFormats() throws {
        let rsa = "-----BEGIN RSA PRIVATE KEY-----\nAQID\n-----END RSA PRIVATE KEY-----\n"
        #expect(try PrivateKeyPEM.importable(rsa) == rsa)

        let ec = "-----BEGIN EC PRIVATE KEY-----\nAQID\n-----END EC PRIVATE KEY-----\n"
        #expect(try PrivateKeyPEM.importable(ec) == ec)
    }

    // MARK: - The conversion that matters

    @Test("An EC key in PKCS#8 is rebuilt as SEC1 with its curve restored")
    func rebuildsECKeys() throws {
        // CryptoKit's derRepresentation is PKCS#8 — the exact shape the platform
        // importer refuses, and what several current tools write.
        let key = P256.Signing.PrivateKey()
        let converted = try PrivateKeyPEM.importable(pem(key.derRepresentation, "PRIVATE KEY"))

        #expect(converted.contains("BEGIN EC PRIVATE KEY"))
        let der = try #require(PrivateKeyPEM.body(of: converted))

        // The rebuilt key must carry the curve the PKCS#8 wrapper held, or it is
        // not self-describing enough to import.
        let primeV1OID = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        #expect(der.range(of: primeV1OID) != nil, "curve OID restored")

        // And the private scalar itself must survive the round trip.
        #expect(der.range(of: key.rawRepresentation) != nil, "private scalar preserved")
    }

    @Test("Conversion is stable across many generated keys")
    func rebuildIsStable() throws {
        // Key encodings vary in length; a parser that mishandles multi-byte DER
        // lengths passes once and fails intermittently.
        for _ in 0..<50 {
            let key = P256.Signing.PrivateKey()
            let converted = try PrivateKeyPEM.importable(pem(key.derRepresentation, "PRIVATE KEY"))
            let der = try #require(PrivateKeyPEM.body(of: converted))
            #expect(der.range(of: key.rawRepresentation) != nil)
        }
    }

    @Test("A P-384 key keeps its own curve, not a hard-coded one")
    func rebuildsOtherCurves() throws {
        let key = P384.Signing.PrivateKey()
        let converted = try PrivateKeyPEM.importable(pem(key.derRepresentation, "PRIVATE KEY"))
        let der = try #require(PrivateKeyPEM.body(of: converted))

        let secp384r1OID = Data([0x2B, 0x81, 0x04, 0x00, 0x22])
        #expect(der.range(of: secp384r1OID) != nil)
        #expect(der.range(of: key.rawRepresentation) != nil)
    }

    @Test("A non-EC PKCS#8 key is passed through rather than mangled")
    func leavesRSAPKCS8Alone() throws {
        // The platform importer reads RSA in PKCS#8 directly, so converting it
        // would be work that could only introduce a bug.
        var rsaPKCS8 = Data([0x30, 0x0A, 0x02, 0x01, 0x00])
        rsaPKCS8 += Data([0x30, 0x05, 0x06, 0x03, 0x2A, 0x86, 0x48])  // not id-ecPublicKey
        let text = pem(rsaPKCS8, "PRIVATE KEY")
        #expect(try PrivateKeyPEM.importable(text) == text)
    }

    @Test("Malformed DER is refused without crashing")
    func survivesMalformedDER() throws {
        // Truncated, over-long lengths, and random bytes all reach the parser from
        // a file the user chose; none may trap.
        let cases: [Data] = [
            Data(),
            Data([0x30]),
            Data([0x30, 0x82, 0xFF]),
            Data([0x30, 0x84, 0x7F, 0xFF, 0xFF, 0xFF, 0x02, 0x01, 0x00]),
            Data((0..<64).map { _ in UInt8.random(in: 0...255) }),
        ]
        for der in cases {
            // Either it converts or it passes through; it must not trap.
            _ = try? PrivateKeyPEM.importable(pem(der, "PRIVATE KEY"))
        }
    }

    // MARK: - Against the platform importer

    #if os(macOS)
    @Test("The converted key is one the platform importer actually accepts")
    func convertedKeyImports() throws {
        // The whole point of the conversion. Testing the DER shape alone would
        // prove the parser self-consistent and still ship a key that cannot load.
        func imports(_ pem: String) -> Bool {
            var format = SecExternalFormat.formatUnknown
            var itemType = SecExternalItemType.itemTypeUnknown
            var items: CFArray?
            var parameters = SecItemImportExportKeyParameters()
            let status = SecItemImport(
                Data(pem.utf8) as CFData, nil, &format, &itemType,
                SecItemImportExportFlags(rawValue: 0), &parameters, nil, &items
            )
            return status == errSecSuccess && ((items as? [AnyObject])?.isEmpty == false)
        }

        let key = P256.Signing.PrivateKey()
        let original = pem(key.derRepresentation, "PRIVATE KEY")

        // Establishes that the conversion is necessary, not decorative: this is the
        // format the importer refuses.
        #expect(!imports(original), "an EC key in PKCS#8 is refused as-is")
        #expect(imports(try PrivateKeyPEM.importable(original)), "and accepted once rebuilt")
    }
    #endif
}
