import Foundation

/// The body of `/api`: the versions the core group serves.
public struct APIVersions: Hashable, Sendable, Codable {
    public let versions: [String]

    public init(versions: [String]) {
        self.versions = versions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        versions = try container.decodeIfPresent([String].self, forKey: .versions) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case versions
    }
}

/// The body of `/apis`: every non-core group and the versions it serves.
public struct APIGroupList: Hashable, Sendable, Codable {
    public let groups: [APIGroupDescription]

    public init(groups: [APIGroupDescription]) {
        self.groups = groups
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groups = try container.decodeIfPresent([APIGroupDescription].self, forKey: .groups) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case groups
    }
}

/// One entry of `/apis`. `preferredVersion` is the server's own recommendation and
/// is what a kind lookup picks when a kind is served by several versions.
public struct APIGroupDescription: Hashable, Sendable, Codable {
    public let name: String
    public let versions: [APIGroupVersionDescription]
    public let preferredVersion: APIGroupVersionDescription?

    public init(
        name: String,
        versions: [APIGroupVersionDescription],
        preferredVersion: APIGroupVersionDescription? = nil
    ) {
        self.name = name
        self.versions = versions
        self.preferredVersion = preferredVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        versions = try container.decodeIfPresent([APIGroupVersionDescription].self, forKey: .versions) ?? []
        preferredVersion = try container.decodeIfPresent(
            APIGroupVersionDescription.self,
            forKey: .preferredVersion
        )
    }

    private enum CodingKeys: String, CodingKey {
        case name, versions, preferredVersion
    }
}

/// A `{groupVersion:, version:}` pair as `/apis` reports it.
public struct APIGroupVersionDescription: Hashable, Sendable, Codable {
    public let groupVersion: String
    public let version: String

    public init(groupVersion: String, version: String) {
        self.groupVersion = groupVersion
        self.version = version
    }

    /// The parsed form. `GroupVersion(apiVersion:)` already handles the core group's
    /// bare `v1`, so a group list and `/api` parse the same way.
    public var parsed: GroupVersion {
        GroupVersion(apiVersion: groupVersion)
    }
}

/// The body of `/api/<version>` or `/apis/<group>/<version>`: every resource that
/// group-version serves, including its subresources.
public struct APIResourceList: Hashable, Sendable, Codable {
    public let groupVersion: String
    public let resources: [APIResourceDescription]

    public init(groupVersion: String, resources: [APIResourceDescription]) {
        self.groupVersion = groupVersion
        self.resources = resources
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groupVersion = try container.decodeIfPresent(String.self, forKey: .groupVersion) ?? ""
        resources = try container.decodeIfPresent([APIResourceDescription].self, forKey: .resources) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case groupVersion, resources
    }
}

/// One resource entry in an `APIResourceList`.
///
/// `name` is the plural REST name. Subresources appear as their own entries named
/// `pods/log` or `deployments/scale`; `parentResourceName` names the resource they
/// hang off, and is `nil` for a resource that has its own collection endpoint.
public struct APIResourceDescription: Hashable, Sendable, Codable {
    public let name: String
    public let singularName: String?
    public let namespaced: Bool
    public let kind: String
    public let verbs: [String]
    public let shortNames: [String]
    public let categories: [String]

    public init(
        name: String,
        singularName: String? = nil,
        namespaced: Bool,
        kind: String,
        verbs: [String] = [],
        shortNames: [String] = [],
        categories: [String] = []
    ) {
        self.name = name
        self.singularName = singularName
        self.namespaced = namespaced
        self.kind = kind
        self.verbs = verbs
        self.shortNames = shortNames
        self.categories = categories
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        singularName = try container.decodeIfPresent(String.self, forKey: .singularName)
        namespaced = try container.decodeIfPresent(Bool.self, forKey: .namespaced) ?? false
        kind = try container.decode(String.self, forKey: .kind)
        verbs = try container.decodeIfPresent([String].self, forKey: .verbs) ?? []
        shortNames = try container.decodeIfPresent([String].self, forKey: .shortNames) ?? []
        categories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
    }

    /// The resource this entry is a subresource of, or `nil` when it is a resource
    /// in its own right.
    public var parentResourceName: String? {
        guard let separator = name.firstIndex(of: "/") else { return nil }
        return String(name[name.startIndex..<separator])
    }

    /// The part after the slash for a subresource entry, e.g. `log` or `scale`.
    public var subresourceName: String? {
        guard let separator = name.firstIndex(of: "/") else { return nil }
        return String(name[name.index(after: separator)...])
    }

    private enum CodingKeys: String, CodingKey {
        case name, singularName, namespaced, kind, verbs, shortNames, categories
    }
}
