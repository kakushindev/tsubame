import Foundation
import KubeModels

/// Owns the JSON coding settings the Kubernetes API requires, so no call site
/// configures its own coder and drifts from the rest.
public struct KubernetesCoder: Sendable {
    public let decoder: JSONDecoder
    public let encoder: JSONEncoder

    public init() {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = RFC3339.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an RFC 3339 timestamp, got \"\(text)\"."
                )
            }
            return date
        }
        encoder.dateEncodingStrategy = .iso8601
        self.decoder = decoder
        self.encoder = encoder
    }

}
