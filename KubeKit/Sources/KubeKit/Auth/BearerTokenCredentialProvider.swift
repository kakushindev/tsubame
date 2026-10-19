import Foundation
import KubeModels

/// Presents a bearer token read from protected storage.
///
/// The token is read through `CredentialStore` on first use and dropped on
/// `invalidate()`, so an expired token is re-read rather than retried forever.
public actor BearerTokenCredentialProvider: CredentialProvider {
    private let reference: CredentialReference
    private let store: any CredentialStore
    private var cachedToken: String?

    public init(reference: CredentialReference, store: any CredentialStore) {
        self.reference = reference
        self.store = store
    }

    public func authenticationHeaders() async throws -> [String: String] {
        let token = try await token()
        return ["Authorization": "Bearer \(token)"]
    }

    public nonisolated func clientCertificateCredential() -> URLCredential? { nil }

    public func invalidate() async {
        cachedToken = nil
    }

    private func token() async throws -> String {
        if let cachedToken { return cachedToken }
        guard let data = try await store.credential(for: reference),
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else {
            throw KubernetesError.unauthenticated(status: nil)
        }
        cachedToken = token
        return token
    }
}
