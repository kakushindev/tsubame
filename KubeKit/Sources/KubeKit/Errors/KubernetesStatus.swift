import Foundation
import KubeModels

/// The `metav1.Status` body the API server returns with most failures.
public struct KubernetesStatus: Hashable, Sendable, Codable {
    public let status: String?
    public let message: String?
    public let reason: String?
    public let code: Int?
    public let details: Details?

    public struct Details: Hashable, Sendable, Codable {
        public let name: String?
        public let group: String?
        public let kind: String?
        public let causes: [Cause]?
        public let retryAfterSeconds: Int?
    }

    public struct Cause: Hashable, Sendable, Codable {
        public let reason: String?
        public let message: String?
        public let field: String?
    }
}
