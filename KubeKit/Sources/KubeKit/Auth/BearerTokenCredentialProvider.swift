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

/// A bearer token re-read from disk on each use.
///
/// `BearerTokenCredentialProvider` serves a token captured once. That is wrong for a
/// projected service-account token, which the kubelet rotates: the captured copy
/// expires and every later request is a 401 the user cannot explain. This reads the
/// file instead, so rotation is invisible.
///
/// macOS only — there is no such file on iOS or iPadOS, and the importer records a
/// snapshot with a warning there instead.
public actor TokenFileCredentialProvider: CredentialProvider {
    private let path: String
    private let read: @Sendable (String) throws -> Data

    public init(
        path: String,
        read: @escaping @Sendable (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    ) {
        self.path = path
        self.read = read
    }

    public func authenticationHeaders() async throws -> [String: String] {
        let data: Data
        do {
            data = try read(path)
        } catch {
            throw KubernetesError.invalidConfiguration(
                reason: "The token file \(path) could not be read. The cluster cannot be "
                    + "reached without it."
            )
        }
        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw KubernetesError.unauthenticated(status: nil)
        }
        return ["Authorization": "Bearer \(token)"]
    }

    /// Nothing to discard: the next request re-reads the file regardless, which is
    /// the point of this provider.
    public func invalidate() async {}
}
