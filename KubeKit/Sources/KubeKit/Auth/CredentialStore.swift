import Foundation
import KubeModels

/// Protected storage for credential material.
///
/// KubeKit only declares the contract. The Keychain implementation lives in
/// KubeKeychain so this package stays testable without a platform keychain, and so
/// no other layer can reach storage directly.
public protocol CredentialStore: Sendable {
    func credential(for reference: CredentialReference) async throws -> Data?
    func store(_ credential: Data, for reference: CredentialReference) async throws
    func removeCredential(for reference: CredentialReference) async throws
}

/// An in-memory store, for tests and for a credential the user chose not to save.
/// It is never written to disk.
public actor EphemeralCredentialStore: CredentialStore {
    private var credentials: [String: Data] = [:]

    public init(credentials: [CredentialReference: Data] = [:]) {
        self.credentials = credentials.reduce(into: [:]) { $0[$1.key.account] = $1.value }
    }

    public func credential(for reference: CredentialReference) async throws -> Data? {
        credentials[reference.account]
    }

    public func store(_ credential: Data, for reference: CredentialReference) async throws {
        credentials[reference.account] = credential
    }

    public func removeCredential(for reference: CredentialReference) async throws {
        credentials.removeValue(forKey: reference.account)
    }
}
