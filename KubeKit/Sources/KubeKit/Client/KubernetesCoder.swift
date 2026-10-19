import Foundation

/// Owns the JSON coding settings the Kubernetes API requires, so no call site
/// configures its own coder and drifts from the rest.
public struct KubernetesCoder: Sendable {
    public let decoder: JSONDecoder
    public let encoder: JSONEncoder

    public init() {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        // The API serializes times as RFC 3339, which ISO 8601 covers.
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        self.decoder = decoder
        self.encoder = encoder
    }
}
