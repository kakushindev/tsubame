import CryptoKit
import Foundation
import KubeKit
import KubeModels
import Security

/// Imports kubeconfig identities into platform-protected storage. iOS uses
/// SecKeyCreateWithData; macOS keeps its native PEM importer. Reference records
/// are also in the Keychain, so contexts may share an identity without deleting
/// one another's credentials when they disconnect.
public actor ClientIdentityStore: ClientIdentityProviding, ClientIdentityImporting {
    private let service: String

    private struct IdentityRecord: Codable {
        let publicKeyHash: Data
        let certificates: [Data]

        var certificateHash: String { Data(SHA256.hash(data: certificates[0])).base64EncodedString() }
        var keyHash: String { publicKeyHash.base64EncodedString() }
    }

    public init(service: String = "dev.kakushin.tsubame.client-identities") {
        self.service = service
    }

    public func importIdentity(
        certificatePEM: Data, privateKeyPEM: Data, for reference: CredentialReference
    ) async throws {
        let key = try Self.privateKey(fromPEM: privateKeyPEM)
        let certificates = try Self.certificates(fromPEM: certificatePEM)
        guard let publicKey = SecKeyCopyPublicKey(key),
              let keyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let certificateKey = SecCertificateCopyKey(certificates[0]),
              let certificateKeyData = SecKeyCopyExternalRepresentation(certificateKey, nil) as Data?,
              keyData == certificateKeyData else {
            throw KubernetesError.invalidConfiguration(
                reason: "The client certificate and private key do not match."
            )
        }
        let record = IdentityRecord(
            publicKeyHash: Data(Insecure.SHA1.hash(data: keyData)),
            certificates: certificates.map { SecCertificateCopyData($0) as Data }
        )
        let previous = try readRecord(for: reference)
        do {
            try add([
                kSecClass: kSecClassKey, kSecValueRef: key,
                kSecAttrApplicationLabel: record.publicKeyHash,
                kSecAttrLabel: keyLabel(record),
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ])
            try add([
                kSecClass: kSecClassCertificate, kSecValueRef: certificates[0],
                kSecAttrLabel: certificateLabel(record),
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ])
            guard try identity(for: record) != nil else {
                throw KubernetesError.invalidConfiguration(
                    reason: "The client certificate could not be linked to its private key in the Keychain."
                )
            }
            try saveRecord(record, for: reference)
        } catch {
            try? removeUnreferencedItems(record)
            throw error
        }
        if let previous { try? removeUnreferencedItems(previous) }
    }

    public func credential(for reference: CredentialReference) async throws -> URLCredential? {
        if let record = try readRecord(for: reference) {
            guard let identity = try identity(for: record) else { return nil }
            let certificates = record.certificates.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            return URLCredential(identity: identity, certificates: certificates, persistence: .forSession)
        }
        // Identities imported by earlier macOS builds used the context label.
        var result: CFTypeRef?
        let label = legacyLabel(reference)
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate, kSecAttrLabel: label,
            kSecReturnRef: true, kSecReturnAttributes: true,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: .read) }
        guard let attributes = result as? [String: Any],
              attributes[kSecAttrLabel as String] as? String == label,
              let certificate = attributes[kSecValueRef as String],
              CFGetTypeID(certificate as CFTypeRef) == SecCertificateGetTypeID() else { return nil }
        let cert = certificate as! SecCertificate
        guard let key = SecCertificateCopyKey(cert),
              let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        let legacy = IdentityRecord(publicKeyHash: Data(Insecure.SHA1.hash(data: keyData)), certificates: [SecCertificateCopyData(cert) as Data])
        guard let identity = try identity(for: legacy) else { return nil }
        return URLCredential(identity: identity, certificates: nil, persistence: .forSession)
    }

    public func removeIdentity(for reference: CredentialReference) async throws {
        if let record = try readRecord(for: reference) {
            try delete(referenceQuery(reference))
            try removeUnreferencedItems(record)
        } else {
            // An identity is formed from its certificate and key. Deleting those
            // exact labelled items also avoids legacy macOS identity queries,
            // whose label filtering is not reliable.
            for itemClass in [kSecClassCertificate, kSecClassKey] {
                try delete([kSecClass: itemClass, kSecAttrLabel: legacyLabel(reference)])
            }
        }
    }

    /// Security's native key representation, also exercised on macOS in tests so
    /// the mobile parser is covered independently of a simulator's Keychain.
    static func mobilePrivateKey(fromPEM pem: Data) throws -> SecKey {
        let text = String(decoding: pem, as: UTF8.self)
        guard let format = PrivateKeyPEM.format(of: text), format != .encrypted,
              !text.contains("Proc-Type: 4,ENCRYPTED") else {
            throw KubernetesError.invalidConfiguration(
                reason: "Use an unencrypted RSA or P-256, P-384, or P-521 client key in PEM format."
            )
        }
        guard let der = PrivateKeyPEM.body(of: text) else {
            throw KubernetesError.invalidConfiguration(reason: "The client key is not valid base64.")
        }
        let data: Data
        let keyType: CFString
        if format == .rsaPKCS1 {
            data = try PrivateKeyPEM.rsaPKCS1DER(text)
            keyType = kSecAttrKeyTypeRSA
        } else if let key = try? P256.Signing.PrivateKey(derRepresentation: der) {
            data = key.x963Representation; keyType = kSecAttrKeyTypeECSECPrimeRandom
        } else if let key = try? P384.Signing.PrivateKey(derRepresentation: der) {
            data = key.x963Representation; keyType = kSecAttrKeyTypeECSECPrimeRandom
        } else if let key = try? P521.Signing.PrivateKey(derRepresentation: der) {
            data = key.x963Representation; keyType = kSecAttrKeyTypeECSECPrimeRandom
        } else {
            data = try PrivateKeyPEM.rsaPKCS1DER(text)
            keyType = kSecAttrKeyTypeRSA
        }
        guard let key = SecKeyCreateWithData(data as CFData, [
            kSecAttrKeyType: keyType, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ] as CFDictionary, nil) else {
            throw KubernetesError.invalidConfiguration(reason: "The client private key could not be imported.")
        }
        return key
    }

    private static func privateKey(fromPEM pem: Data) throws -> SecKey {
        #if os(macOS)
        let importable = try PrivateKeyPEM.importable(String(decoding: pem, as: UTF8.self))
        var format = SecExternalFormat.formatUnknown
        var itemType = SecExternalItemType.itemTypeUnknown
        var items: CFArray?
        var parameters = SecItemImportExportKeyParameters()
        let status = SecItemImport(
            Data(importable.utf8) as CFData, nil, &format, &itemType,
            SecItemImportExportFlags(rawValue: 0), &parameters, nil, &items
        )
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: .write) }
        guard let found = (items as? [AnyObject])?.first(where: { CFGetTypeID($0) == SecKeyGetTypeID() }) else {
            throw KeychainError(status: errSecUnknownFormat, operation: .write)
        }
        return found as! SecKey
        #else
        return try mobilePrivateKey(fromPEM: pem)
        #endif
    }

    private static func certificates(fromPEM pem: Data) throws -> [SecCertificate] {
        let text = String(decoding: pem, as: UTF8.self)
        let blocks = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst()
        let certificates = blocks.compactMap { block -> SecCertificate? in
            guard let end = block.range(of: "-----END CERTIFICATE-----"),
                  let der = Data(base64Encoded: String(block[..<end.lowerBound]), options: .ignoreUnknownCharacters) else { return nil }
            return SecCertificateCreateWithData(nil, der as CFData)
        }
        guard !certificates.isEmpty, certificates.count == blocks.count else {
            throw KubernetesError.invalidConfiguration(reason: "The client certificate is not valid PEM.")
        }
        return certificates
    }

    private func identity(for record: IdentityRecord) throws -> SecIdentity? {
        #if os(macOS)
        guard let certificate = SecCertificateCreateWithData(nil, record.certificates[0] as CFData) else { return nil }
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: .read) }
        return identity
        #else
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassIdentity, kSecAttrLabel: certificateLabel(record),
            kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KubernetesError.invalidConfiguration(reason: "The Keychain could not read the client identity (OSStatus \(status)).")
        }
        guard let result, CFGetTypeID(result) == SecIdentityGetTypeID() else { return nil }
        let identity = result as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate, SecCertificateCopyData(certificate) as Data == record.certificates[0] else { return nil }
        return identity
        #endif
    }

    private func referenceQuery(_ reference: CredentialReference) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service + ".references", kSecAttrAccount: reference.account]
    }

    private func readRecord(for reference: CredentialReference) throws -> IdentityRecord? {
        var query = referenceQuery(reference)
        query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: .read) }
        guard let data = result as? Data, let record = try? JSONDecoder().decode(IdentityRecord.self, from: data),
              !record.certificates.isEmpty else {
            throw KubernetesError.invalidConfiguration(reason: "The stored client identity is invalid. Import the kubeconfig again.")
        }
        return record
    }

    private func saveRecord(_ record: IdentityRecord, for reference: CredentialReference) throws {
        let data = try JSONEncoder().encode(record)
        let query = referenceQuery(reference)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status, operation: .write) }
        var attributes = query
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        try add(attributes)
    }

    private func removeUnreferencedItems(_ record: IdentityRecord) throws {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: service + ".references",
            kSecMatchLimit: kSecMatchLimitAll, kSecReturnAttributes: true,
        ] as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: .read)
        }
        let accounts = ((result as? [[String: Any]]) ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
        let references = try accounts.compactMap {
            try readRecord(for: CredentialReference(account: $0))
        }
        if !references.contains(where: { $0.certificateHash == record.certificateHash }) {
            try delete([kSecClass: kSecClassCertificate, kSecAttrLabel: certificateLabel(record)])
        }
        if !references.contains(where: { $0.keyHash == record.keyHash }) {
            try delete([kSecClass: kSecClassKey, kSecAttrLabel: keyLabel(record)])
        }
    }

    private func add(_ attributes: [CFString: Any]) throws {
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw KeychainError(status: status, operation: .write)
        }
    }

    private func delete(_ query: [CFString: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: .delete)
        }
    }

    private func legacyLabel(_ reference: CredentialReference) -> String { "\(service).\(reference.account)" }
    private func keyLabel(_ record: IdentityRecord) -> String { "\(service).key.\(record.keyHash)" }
    private func certificateLabel(_ record: IdentityRecord) -> String { "\(service).certificate.\(record.certificateHash)" }
}
