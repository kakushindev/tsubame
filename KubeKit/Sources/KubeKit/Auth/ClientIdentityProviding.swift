import Foundation
import KubeModels

/// Supplies the client certificate a cluster asks for during the TLS handshake.
///
/// Expressed as a `URLCredential` rather than a `SecIdentity` so this stays in
/// KubeKit: the package declares the contract, and only KubeKeychain touches the
/// platform's protected storage.
public protocol ClientIdentityProviding: Sendable {
    func credential(for reference: CredentialReference) async throws -> URLCredential?
}

/// Stores and removes client identities.
public protocol ClientIdentityImporting: Sendable {
    /// Converts kubeconfig PEM into a stored identity.
    func importIdentity(
        certificatePEM: Data,
        privateKeyPEM: Data,
        for reference: CredentialReference
    ) async throws

    func removeIdentity(for reference: CredentialReference) async throws
}

/// Presents a stored client certificate during the handshake.
///
/// A client certificate is not a header: it is offered when the server asks for it,
/// which happens inside the TLS exchange rather than when the request is built. So
/// `authenticationHeaders()` contributes nothing — but it is still where the
/// identity is loaded, because it is the one `async` point before the handshake,
/// and `clientCertificateCredential()` is neither async nor throwing.
///
/// `URLSessionTransport` awaits `authenticationHeaders()` before sending, so that
/// ordering is a contract this provider depends on, not an accident.
public final class ClientCertificateCredentialProvider: CredentialProvider, @unchecked Sendable {
    private let reference: CredentialReference
    private let identities: any ClientIdentityProviding
    private let lock = NSLock()
    private var loaded: URLCredential?

    public init(reference: CredentialReference, identities: any ClientIdentityProviding) {
        self.reference = reference
        self.identities = identities
    }

    public func authenticationHeaders() async throws -> [String: String] {
        if currentCredential() == nil {
            guard let credential = try await identities.credential(for: reference) else {
                throw KubernetesError.invalidConfiguration(
                    reason: "The client certificate for this cluster is no longer available. "
                        + "Import the kubeconfig again."
                )
            }
            lock.withLock { loaded = credential }
        }
        // A client certificate travels in the handshake, not in a header.
        return [:]
    }

    public func clientCertificateCredential() -> URLCredential? {
        currentCredential()
    }

    public func invalidate() async {
        lock.withLock { loaded = nil }
    }

    private func currentCredential() -> URLCredential? {
        lock.withLock { loaded }
    }
}
