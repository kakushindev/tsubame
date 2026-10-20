import CryptoKit
import Foundation
import Network
import Security
import Testing
import KubeKit
import KubeModels
@testable import KubeKeychain

@Suite("Client certificate identities")
struct ClientIdentityStoreTests {
    enum Format: CaseIterable { case rsaPKCS1, rsaPKCS8, ecSEC1, ecPKCS8, p384, p521 }

    @Test("The mobile key decoder preserves the public key", arguments: Format.allCases)
    func mobileKeyDecoder(format: Format) throws {
        let fixture = try IdentityFixture(format: format)
        let key = try ClientIdentityStore.mobilePrivateKey(fromPEM: fixture.privatePEM)
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        #expect(SecKeyCopyExternalRepresentation(publicKey, nil) as Data? == fixture.publicData)
    }

    @Test("An imported identity signs with its matching certificate", arguments: Format.allCases)
    func importAndRead(format: Format) async throws {
        let fixture = try IdentityFixture(format: format)
        let store = ClientIdentityStore(service: "dev.kakushin.tsubame.tests.\(UUID())")
        let reference = CredentialReference(account: "identity")
        try await store.importIdentity(certificatePEM: fixture.certificatePEM, privateKeyPEM: fixture.privatePEM, for: reference)
        do {
            let credential = try #require(await store.credential(for: reference))
            let identity = try #require(credential.identity)
            var privateKey: SecKey?
            #expect(SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess)
            let key = try #require(privateKey)
            let message = Data("TLS client authentication test".utf8)
            let signature = try #require(SecKeyCreateSignature(key, fixture.signatureAlgorithm, message as CFData, nil))
            #expect(SecKeyVerifySignature(fixture.publicKey, fixture.signatureAlgorithm, message as CFData, signature, nil))
            #expect(!credential.certificates.isEmpty)
            #if os(iOS)
            var result: CFTypeRef?
            let hash = Data(Insecure.SHA1.hash(data: fixture.publicData))
            #expect(SecItemCopyMatching([
                kSecClass: kSecClassKey, kSecAttrApplicationLabel: hash,
                kSecReturnAttributes: true,
            ] as CFDictionary, &result) == errSecSuccess)
            let attributes = try #require(result as? [String: Any])
            #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            #endif
        } catch {
            try? await store.removeIdentity(for: reference)
            throw error
        }
        try await store.removeIdentity(for: reference)
        #expect(try await store.credential(for: reference) == nil)
    }

    @Test("Reimport and shared contexts keep their own usable references")
    func sharedIdentity() async throws {
        let fixture = try IdentityFixture(format: .ecPKCS8)
        let store = ClientIdentityStore(service: "dev.kakushin.tsubame.tests.\(UUID())")
        let first = CredentialReference(account: "first"), second = CredentialReference(account: "second")
        for reference in [first, first, second] {
            try await store.importIdentity(certificatePEM: fixture.certificatePEM, privateKeyPEM: fixture.privatePEM, for: reference)
        }
        try await store.removeIdentity(for: CredentialReference(account: "never-imported"))
        #expect(try await store.credential(for: first) != nil)
        try await store.removeIdentity(for: first)
        #expect(try await store.credential(for: first) == nil)
        #expect(try await store.credential(for: second) != nil)
        try await store.removeIdentity(for: second)
        #expect(try await store.credential(for: second) == nil)
    }

    @Test("A mismatched replacement leaves the existing identity usable")
    func mismatchPreservesIdentity() async throws {
        let fixture = try IdentityFixture(format: .ecPKCS8)
        let different = try IdentityFixture(format: .ecPKCS8)
        let store = ClientIdentityStore(service: "dev.kakushin.tsubame.tests.\(UUID())")
        let reference = CredentialReference(account: "identity")
        try await store.importIdentity(certificatePEM: fixture.certificatePEM, privateKeyPEM: fixture.privatePEM, for: reference)
        await #expect(throws: KubernetesError.self) {
            try await store.importIdentity(certificatePEM: fixture.certificatePEM, privateKeyPEM: different.privatePEM, for: reference)
        }
        #expect(try await store.credential(for: reference) != nil)
        try await store.removeIdentity(for: reference)
    }

    @Test("Encrypted and malformed keys fail without echoing key material")
    func invalidKeys() {
        for text in ["not a private key", "-----BEGIN ENCRYPTED PRIVATE KEY-----\nPRIVATE_SENTINEL\n-----END ENCRYPTED PRIVATE KEY-----"] {
            do {
                _ = try ClientIdentityStore.mobilePrivateKey(fromPEM: Data(text.utf8))
                Issue.record("Expected refusal")
            } catch {
                #expect(!error.localizedDescription.contains("PRIVATE_SENTINEL"))
            }
        }
    }

    @Test("URLSession completes a real mutual TLS handshake with the imported identity")
    func mutualTLSHandshake() async throws {
        let fixture = try IdentityFixture(format: .ecPKCS8)
        let store = ClientIdentityStore(service: "dev.kakushin.tsubame.tests.\(UUID())")
        let reference = CredentialReference(account: "tls")
        try await store.importIdentity(certificatePEM: fixture.certificatePEM, privateKeyPEM: fixture.privatePEM, for: reference)
        do {
            let credential = try #require(await store.credential(for: reference))
            let identity = try #require(credential.identity)
            var certificate: SecCertificate?
            #expect(SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess)
            let anchor = try #require(certificate)
            var trust: SecTrust?
            #expect(SecTrustCreateWithCertificates(anchor, SecPolicyCreateSSL(true, "localhost" as CFString), &trust) == errSecSuccess)
            let testTrust = try #require(trust)
            SecTrustSetAnchorCertificates(testTrust, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(testTrust, true)
            var trustError: CFError?
            try #require(SecTrustEvaluateWithError(testTrust, &trustError), "Generated server trust: \(String(describing: trustError))")
            let server = try MutualTLSServer(identity: identity)
            defer { server.stop() }
            let port = try await server.start()
            let transport = URLSessionTransport(
                serverURL: URL(string: "https://localhost:\(port)")!,
                credentialProvider: ClientCertificateCredentialProvider(reference: reference, identities: store),
                tls: TLSConfiguration(certificateAuthorityData: fixture.certificatePEM)
            )
            let response = try await transport.send(APIRequest(method: .get, path: "/api", timeout: 5))
            #expect(response.statusCode == 200)
            #expect(server.authenticatedClient)
        } catch {
            try? await store.removeIdentity(for: reference)
            throw error
        }
        try await store.removeIdentity(for: reference)
    }
}

/// Every test generates its own key and self-signed certificate in memory. No
/// private-key fixture is committed or written to an unprotected file.
private struct IdentityFixture {
    let privatePEM: Data
    let certificatePEM: Data
    let publicKey: SecKey
    let publicData: Data
    let signatureAlgorithm: SecKeyAlgorithm

    init(format: ClientIdentityStoreTests.Format) throws {
        let key: SecKey
        let privateData: Data
        let privateLabel: String
        let subjectAlgorithm: Data
        let certificateAlgorithm: Data
        if format == .rsaPKCS1 || format == .rsaPKCS8 {
            key = try #require(SecKeyCreateRandomKey([
                kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
            ] as CFDictionary, nil))
            let raw = try #require(SecKeyCopyExternalRepresentation(key, nil) as Data?)
            let rsaOID = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 1, 1, 1])
            subjectAlgorithm = Self.sequence(Self.der(6, rsaOID) + Self.der(5, Data()))
            certificateAlgorithm = Self.sequence(Self.der(6, Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 1, 1, 11])) + Self.der(5, Data()))
            signatureAlgorithm = .rsaSignatureMessagePKCS1v15SHA256
            privateData = format == .rsaPKCS8 ? Self.sequence(Self.der(2, Data([0])) + subjectAlgorithm + Self.der(4, raw)) : raw
            privateLabel = format == .rsaPKCS8 ? "PRIVATE KEY" : "RSA PRIVATE KEY"
        } else {
            let pem: String
            let curveOID: Data
            switch format {
            case .p384:
                pem = P384.Signing.PrivateKey().pemRepresentation
                curveOID = Data([0x2B, 0x81, 4, 0, 0x22])
            case .p521:
                pem = P521.Signing.PrivateKey().pemRepresentation
                curveOID = Data([0x2B, 0x81, 4, 0, 0x23])
            default:
                pem = P256.Signing.PrivateKey().pemRepresentation
                curveOID = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 3, 1, 7])
            }
            let text = format == .ecSEC1 ? try PrivateKeyPEM.importable(pem) : pem
            privateData = try #require(PrivateKeyPEM.body(of: text))
            privateLabel = format == .ecSEC1 ? "EC PRIVATE KEY" : "PRIVATE KEY"
            key = try ClientIdentityStore.mobilePrivateKey(fromPEM: Data(text.utf8))
            subjectAlgorithm = Self.sequence(Self.der(6, Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 2, 1])) + Self.der(6, curveOID))
            certificateAlgorithm = Self.sequence(Self.der(6, Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 4, 3, 2])))
            signatureAlgorithm = .ecdsaSignatureMessageX962SHA256
        }
        privatePEM = Self.pem(privateData, privateLabel)
        publicKey = try #require(SecKeyCopyPublicKey(key))
        publicData = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let name = Self.sequence(Self.der(0x31, Self.sequence(Self.der(6, Data([0x55, 4, 3])) + Self.der(12, Data("localhost".utf8)))))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        let validity = Self.sequence(
            Self.der(23, Data(formatter.string(from: Date().addingTimeInterval(-60)).utf8))
                + Self.der(23, Data(formatter.string(from: Date().addingTimeInterval(86400)).utf8))
        )
        let spki = Self.sequence(subjectAlgorithm + Self.der(3, Data([0]) + publicData))
        let serial = Data([1]) + withUnsafeBytes(of: UUID().uuid) { Data($0) }
        let san = Self.sequence(Self.der(6, Data([0x55, 0x1D, 0x11])) + Self.der(4, Self.sequence(Self.der(0x82, Data("localhost".utf8)))))
        let ca = Self.sequence(Self.der(6, Data([0x55, 0x1D, 0x13])) + Self.der(1, Data([0xFF])) + Self.der(4, Self.sequence(Self.der(1, Data([0xFF])))))
        let usages = Self.sequence(Self.der(6, Data([0x2B, 6, 1, 5, 5, 7, 3, 1])) + Self.der(6, Data([0x2B, 6, 1, 5, 5, 7, 3, 2])))
        let eku = Self.sequence(Self.der(6, Data([0x55, 0x1D, 0x25])) + Self.der(4, usages))
        let tbs = Self.sequence(Self.der(0xA0, Self.der(2, Data([2]))) + Self.der(2, serial) + certificateAlgorithm + name + validity + name + spki + Self.der(0xA3, Self.sequence(san + ca + eku)))
        let signature = try #require(SecKeyCreateSignature(key, signatureAlgorithm, tbs as CFData, nil) as Data?)
        certificatePEM = Self.pem(Self.sequence(tbs + certificateAlgorithm + Self.der(3, Data([0]) + signature)), "CERTIFICATE")
    }

    private static func sequence(_ data: Data) -> Data { der(0x30, data) }
    private static func der(_ tag: UInt8, _ data: Data) -> Data {
        var count = data.count, bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(count & 255), at: 0); count >>= 8 } while count > 0
        let length = data.count < 128 ? [UInt8(data.count)] : [0x80 | UInt8(bytes.count)] + bytes
        return Data([tag] + length) + data
    }
    private static func pem(_ data: Data, _ label: String) -> Data {
        Data("-----BEGIN \(label)-----\n\(data.base64EncodedString())\n-----END \(label)-----\n".utf8)
    }
}

/// A loopback server requiring and validating a client certificate. Test traffic
/// and generated credentials stay within the test process.
private final class MutualTLSServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.kakushin.tsubame.tests.tls")
    private let lock = NSLock()
    private let verification: TLSVerification
    private var connections: [NWConnection] = []
    var authenticatedClient: Bool { verification.value }

    init(identity: SecIdentity) throws {
        let tls = NWProtocolTLS.Options()
        let localIdentity = try #require(sec_identity_create(identity))
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        var certificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess)
        let anchor = try #require(certificate)
        let verification = TLSVerification()
        self.verification = verification
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetAnchorCertificates(trustRef, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trustRef, true)
            let valid = SecTrustEvaluateWithError(trustRef, nil)
            verification.set(valid)
            complete(valid)
        }, queue)
        let parameters = NWParameters(tls: tls)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, _, error in
                guard error == nil else { connection.cancel(); return }
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func start() async throws -> UInt16 {
        let states = AsyncStream<NWListener.State>.makeStream(bufferingPolicy: .bufferingNewest(1))
        listener.stateUpdateHandler = { states.continuation.yield($0) }
        listener.start(queue: queue)
        for await state in states.stream {
            switch state {
            case .ready: return try #require(listener.port?.rawValue)
            case .failed(let error): throw error
            default: continue
            }
        }
        throw CancellationError()
    }

    func stop() {
        listener.cancel()
        lock.withLock { for connection in connections { connection.cancel() }; connections.removeAll() }
    }
}

private final class TLSVerification: @unchecked Sendable {
    private let lock = NSLock()
    private var verified = false
    var value: Bool { lock.withLock { verified } }
    func set(_ value: Bool) { lock.withLock { verified = value } }
}
