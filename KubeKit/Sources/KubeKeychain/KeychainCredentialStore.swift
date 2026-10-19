import Foundation
import Security
import KubeKit
import KubeModels

/// The Keychain implementation of `CredentialStore`.
///
/// Items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: a watch or log
/// stream has to survive the screen locking, and the credential must not travel to
/// another device in a backup or iCloud Keychain.
public actor KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "dev.kakushin.tsubame.cluster-credentials") {
        self.service = service
    }

    public func credential(for reference: CredentialReference) async throws -> Data? {
        var query = baseQuery(for: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status, operation: .read)
        }
    }

    public func store(_ credential: Data, for reference: CredentialReference) async throws {
        let query = baseQuery(for: reference)
        let attributes: [String: Any] = [kSecValueData as String: credential]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus, operation: .write)
        }

        var insert = query
        insert[kSecValueData as String] = credential
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus, operation: .write)
        }
    }

    public func removeCredential(for reference: CredentialReference) async throws {
        let status = SecItemDelete(baseQuery(for: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: .delete)
        }
    }

    private func baseQuery(for reference: CredentialReference) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.account,
        ]
    }
}

/// A Keychain failure, carrying the OSStatus for diagnostics.
///
/// The status code is safe to show; the credential value never appears here.
public struct KeychainError: Error, Hashable, Sendable, LocalizedError {
    public enum Operation: Hashable, Sendable {
        case read, write, delete
    }

    public let status: OSStatus
    public let operation: Operation

    public init(status: OSStatus, operation: Operation) {
        self.status = status
        self.operation = operation
    }

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        switch operation {
        case .read: return "The stored credential could not be read: \(detail)"
        case .write: return "The credential could not be saved: \(detail)"
        case .delete: return "The stored credential could not be removed: \(detail)"
        }
    }
}
