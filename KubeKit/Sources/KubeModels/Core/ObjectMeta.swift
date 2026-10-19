import Foundation

/// The subset of `metadata` the app reads directly. The untouched payload stays
/// in the owning object's `raw` representation.
public struct ObjectMeta: Hashable, Sendable, Codable {
    public var name: String
    public var namespace: String?
    public var uid: String?
    public var resourceVersion: String?
    public var creationTimestamp: Date?
    public var deletionTimestamp: Date?
    public var labels: [String: String]
    public var annotations: [String: String]
    public var ownerReferences: [OwnerReference]

    public init(
        name: String,
        namespace: String? = nil,
        uid: String? = nil,
        resourceVersion: String? = nil,
        creationTimestamp: Date? = nil,
        deletionTimestamp: Date? = nil,
        labels: [String: String] = [:],
        annotations: [String: String] = [:],
        ownerReferences: [OwnerReference] = []
    ) {
        self.name = name
        self.namespace = namespace
        self.uid = uid
        self.resourceVersion = resourceVersion
        self.creationTimestamp = creationTimestamp
        self.deletionTimestamp = deletionTimestamp
        self.labels = labels
        self.annotations = annotations
        self.ownerReferences = ownerReferences
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        namespace = try container.decodeIfPresent(String.self, forKey: .namespace)
        uid = try container.decodeIfPresent(String.self, forKey: .uid)
        resourceVersion = try container.decodeIfPresent(String.self, forKey: .resourceVersion)
        creationTimestamp = try container.decodeIfPresent(Date.self, forKey: .creationTimestamp)
        deletionTimestamp = try container.decodeIfPresent(Date.self, forKey: .deletionTimestamp)
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        annotations = try container.decodeIfPresent([String: String].self, forKey: .annotations) ?? [:]
        ownerReferences = try container.decodeIfPresent([OwnerReference].self, forKey: .ownerReferences) ?? []
    }
}

public struct OwnerReference: Hashable, Sendable, Codable {
    public let apiVersion: String
    public let kind: String
    public let name: String
    public let uid: String
    public let controller: Bool?

    public init(apiVersion: String, kind: String, name: String, uid: String, controller: Bool? = nil) {
        self.apiVersion = apiVersion
        self.kind = kind
        self.name = name
        self.uid = uid
        self.controller = controller
    }

    public var groupVersionKind: GroupVersionKind {
        GroupVersionKind(apiVersion: apiVersion, kind: kind)
    }
}
