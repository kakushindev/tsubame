import Foundation
import KubeModels

/// Supplies the credential for one cluster at the moment a request is built.
///
/// Implementations hold the credential, refresh it when it expires, and hand back
/// only what the request needs. Nothing above this protocol sees the raw value, so
/// bearer tokens, client certificates, OIDC, and exec plugins differ in one place.
public protocol CredentialProvider: Sendable {
    /// Headers to add to every request. Empty when the credential is a client
    /// certificate, which is presented during the TLS handshake instead.
    func authenticationHeaders() async throws -> [String: String]

    /// The identity to present for a client-certificate challenge, or `nil`.
    func clientCertificateCredential() -> URLCredential?

    /// Discards any cached credential after the server rejected it, so the next
    /// request re-reads or refreshes rather than repeating a known-bad value.
    func invalidate() async
}

extension CredentialProvider {
    public func clientCertificateCredential() -> URLCredential? { nil }
    public func invalidate() async {}
}

/// A provider for a credential that cannot be used on this platform.
///
/// Failing at request time with a precise error beats a connection that silently
/// behaves as unauthenticated. PRD §9.1 requires naming the unsupported method.
public struct UnsupportedCredentialProvider: CredentialProvider {
    private let method: String
    private let platform: HostPlatform

    public init(method: String, platform: HostPlatform = .current) {
        self.method = method
        self.platform = platform
    }

    public func authenticationHeaders() async throws -> [String: String] {
        throw KubernetesError.unsupportedAuthentication(method: method, platform: platform)
    }
}
