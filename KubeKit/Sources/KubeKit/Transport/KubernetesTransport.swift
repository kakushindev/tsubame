import Foundation

/// Sends requests to one cluster.
///
/// Everything above this protocol — discovery, resource operations, watches — is
/// written against it, so those layers are tested with a stub rather than a server.
public protocol KubernetesTransport: Sendable {
    /// Sends a request and waits for the complete response.
    func send(_ request: APIRequest) async throws -> APIResponse

    /// Opens a long-lived response and yields each line as the server writes it.
    /// Used for watches and log streams, which are newline-delimited.
    ///
    /// Cancelling the consuming task must cancel the underlying connection.
    func lines(for request: APIRequest) async throws -> AsyncThrowingStream<Data, any Error>
}
