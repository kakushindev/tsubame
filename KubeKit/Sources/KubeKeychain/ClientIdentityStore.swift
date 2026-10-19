#if os(macOS)
import CryptoKit
import Foundation
import KubeKit
import KubeModels
import Security

/// Stores client certificates and hands back the identity for a TLS handshake.
///
/// macOS only. Client-certificate authentication is a desktop capability in this
/// release (PRD §9.1), and the importer this depends on is itself macOS-only.
///
/// Three things here are not obvious, and each one fails silently if skipped:
///
/// 1. The platform's PEM importer accepts RSA PKCS#1, RSA PKCS#8 and EC SEC1, but
///    refuses an EC key in PKCS#8. `PrivateKeyPEM` converts that case first.
/// 2. A certificate and a key are linked in the keychain by the key's public-key
///    hash, stored as `kSecAttrApplicationLabel`. Without it both items store
///    successfully and no identity can ever be formed from them.
/// 3. Re-importing the same certificate reports a duplicate. That is the expected
///    outcome of importing a kubeconfig twice, not a failure.
public actor ClientIdentityStore: ClientIdentityProviding, ClientIdentityImporting {
    private let service: String

    public init(service: String = "dev.kakushin.tsubame.client-identities") {
        self.service = service
    }

    // MARK: - Importing

    public func importIdentity(
        certificatePEM: Data,
        privateKeyPEM: Data,
        for reference: CredentialReference
    ) async throws {
        let keyText = String(decoding: privateKeyPEM, as: UTF8.self)
        let importable = try PrivateKeyPEM.importable(keyText)

        let key = try privateKey(fromPEM: Data(importable.utf8))
        let certificate = try certificate(fromPEM: certificatePEM)

        guard let publicKey = SecKeyCopyPublicKey(key),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else {
            throw KeychainError(status: errSecInvalidKeyRef, operation: .write)
        }
        let publicKeyHash = Data(Insecure.SHA1.hash(data: publicKeyData))

        // Replace rather than accumulate: importing the same context twice should
        // leave one identity, not two.
        try deleteItems(for: reference)

        let keyStatus = SecItemAdd([
            kSecClass: kSecClassKey,
            kSecValueRef: key,
            // The linkage. Without it `SecIdentityCreateWithCertificate` never
            // matches, however well the two items store.
            kSecAttrApplicationLabel: publicKeyHash,
            kSecAttrLabel: label(for: reference),
        ] as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            throw KeychainError(status: keyStatus, operation: .write)
        }

        let certificateStatus = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecAttrLabel: label(for: reference),
        ] as CFDictionary, nil)
        guard certificateStatus == errSecSuccess || certificateStatus == errSecDuplicateItem else {
            throw KeychainError(status: certificateStatus, operation: .write)
        }
    }

    // MARK: - Reading

    public func credential(for reference: CredentialReference) async throws -> URLCredential? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: label(for: reference),
            kSecReturnRef: true,
        ] as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let found = result else {
            throw KeychainError(status: status, operation: .read)
        }
        guard CFGetTypeID(found) == SecIdentityGetTypeID() else { return nil }
        // `.forSession` on purpose: the identity is already persisted in the
        // keychain, and URLSession should not keep a second copy of its own.
        return URLCredential(
            identity: found as! SecIdentity,
            certificates: nil,
            persistence: .forSession
        )
    }

    // MARK: - Removal

    public func removeIdentity(for reference: CredentialReference) async throws {
        try deleteItems(for: reference)
    }

    private func deleteItems(for reference: CredentialReference) throws {
        for itemClass in [kSecClassIdentity, kSecClassCertificate, kSecClassKey] {
            let status = SecItemDelete([
                kSecClass: itemClass,
                kSecAttrLabel: label(for: reference),
            ] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status, operation: .delete)
            }
        }
    }

    // MARK: - Decoding PEM

    private func privateKey(fromPEM pem: Data) throws -> SecKey {
        let item = try firstImportedItem(from: pem, expecting: SecKeyGetTypeID())
        return item as! SecKey
    }

    private func certificate(fromPEM pem: Data) throws -> SecCertificate {
        let item = try firstImportedItem(from: pem, expecting: SecCertificateGetTypeID())
        return item as! SecCertificate
    }

    /// Imports PEM into memory. Nothing is written to a keychain here, so a
    /// malformed file is rejected before anything is stored.
    private func firstImportedItem(from pem: Data, expecting type: CFTypeID) throws -> AnyObject {
        var format = SecExternalFormat.formatUnknown
        var itemType = SecExternalItemType.itemTypeUnknown
        var items: CFArray?
        var parameters = SecItemImportExportKeyParameters()

        let status = SecItemImport(
            pem as CFData, nil, &format, &itemType,
            SecItemImportExportFlags(rawValue: 0), &parameters, nil, &items
        )
        guard status == errSecSuccess else {
            throw KeychainError(status: status, operation: .write)
        }
        guard let found = (items as? [AnyObject])?.first(where: { CFGetTypeID($0) == type }) else {
            throw KeychainError(status: errSecUnknownFormat, operation: .write)
        }
        return found
    }

    private func label(for reference: CredentialReference) -> String {
        "\(service).\(reference.account)"
    }
}
#endif
