import Foundation

/// An API group and version, e.g. `apps/v1` or the core group `v1`.
public struct GroupVersion: Hashable, Sendable, Codable {
    public static let core = GroupVersion(group: "", version: "v1")

    public let group: String
    public let version: String

    public init(group: String, version: String) {
        self.group = group
        self.version = version
    }

    /// Parses the `apiVersion` field of a Kubernetes object.
    public init(apiVersion: String) {
        let parts = apiVersion.split(separator: "/", maxSplits: 1)
        if parts.count == 2 {
            self.init(group: String(parts[0]), version: String(parts[1]))
        } else {
            self.init(group: "", version: apiVersion)
        }
    }

    public var apiVersion: String {
        group.isEmpty ? version : "\(group)/\(version)"
    }

    /// The REST path prefix the API server serves this group under.
    public var pathPrefix: String {
        group.isEmpty ? "/api/\(version)" : "/apis/\(group)/\(version)"
    }
}

/// A group, version, and kind — the identity of an object's type.
public struct GroupVersionKind: Hashable, Sendable, Codable {
    public let groupVersion: GroupVersion
    public let kind: String

    public init(groupVersion: GroupVersion, kind: String) {
        self.groupVersion = groupVersion
        self.kind = kind
    }

    public init(apiVersion: String, kind: String) {
        self.init(groupVersion: GroupVersion(apiVersion: apiVersion), kind: kind)
    }
}

/// A group, version, and plural resource name — the identity of a REST endpoint.
public struct GroupVersionResource: Hashable, Sendable, Codable {
    public let groupVersion: GroupVersion
    public let resource: String
    public let isNamespaced: Bool

    public init(groupVersion: GroupVersion, resource: String, isNamespaced: Bool) {
        self.groupVersion = groupVersion
        self.resource = resource
        self.isNamespaced = isNamespaced
    }

    /// Collection path for a namespace, or the cluster-wide collection when
    /// `namespace` is `nil` or the resource is not namespaced.
    public func collectionPath(namespace: String?) -> String {
        guard isNamespaced, let namespace, !namespace.isEmpty else {
            return "\(groupVersion.pathPrefix)/\(resource)"
        }
        return "\(groupVersion.pathPrefix)/namespaces/\(namespace)/\(resource)"
    }

    public func objectPath(namespace: String?, name: String) -> String {
        "\(collectionPath(namespace: namespace))/\(name)"
    }

    public func subresourcePath(namespace: String?, name: String, subresource: String) -> String {
        "\(objectPath(namespace: namespace, name: name))/\(subresource)"
    }
}
