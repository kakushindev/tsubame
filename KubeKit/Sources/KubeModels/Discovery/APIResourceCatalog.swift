import Foundation

/// One resource the server serves, resolved from discovery into the form the rest
/// of the app uses: a REST endpoint, the kind it carries, and what may be done to it.
public struct DiscoveredResource: Hashable, Sendable, Codable {
    public let groupVersionResource: GroupVersionResource
    public let kind: String
    public let singularName: String
    public let shortNames: [String]
    public let categories: [String]
    public let verbs: Set<String>
    /// Whether this version is the one the server names as preferred for its group.
    /// A kind lookup picks a preferred version over any other.
    public let isPreferredVersion: Bool
    /// Subresources this resource serves, by their short name (`log`, `scale`).
    public let subresources: Set<String>

    public init(
        groupVersionResource: GroupVersionResource,
        kind: String,
        singularName: String,
        shortNames: [String] = [],
        categories: [String] = [],
        verbs: Set<String> = [],
        isPreferredVersion: Bool = false,
        subresources: Set<String> = []
    ) {
        self.groupVersionResource = groupVersionResource
        self.kind = kind
        self.singularName = singularName
        self.shortNames = shortNames
        self.categories = categories
        self.verbs = verbs
        self.isPreferredVersion = isPreferredVersion
        self.subresources = subresources
    }

    public var groupVersion: GroupVersion { groupVersionResource.groupVersion }
    public var resourceName: String { groupVersionResource.resource }
    public var isNamespaced: Bool { groupVersionResource.isNamespaced }

    public var groupVersionKind: GroupVersionKind {
        GroupVersionKind(groupVersion: groupVersion, kind: kind)
    }

    public func supports(_ verb: String) -> Bool { verbs.contains(verb) }

    public var isListable: Bool { supports("list") }
    /// A resource without `watch` needs the documented polling fallback (PRD §9.3),
    /// so this is a decision the browse layer has to be able to read.
    public var isWatchable: Bool { supports("watch") }
    public var isDeletable: Bool { supports("delete") }
}

/// Why a group-version produced no resources.
///
/// A denial is kept apart from an outage because the UI must say "you may not see
/// this" rather than "this kind does not exist" (PRD §9.2).
public enum DiscoveryFailure: Error, Hashable, Sendable {
    /// RBAC refused the discovery request for this group-version.
    case permissionDenied(message: String?)
    /// The group-version is advertised but not answering — a down aggregated API
    /// server, a 404, or a 503.
    case unavailable(reason: String)
}

/// Everything one cluster said it serves, as of one discovery pass.
///
/// This is a value: a refresh produces a new catalog rather than mutating this one,
/// so a view holding a catalog never sees it change underneath.
public struct APIResourceCatalog: Hashable, Sendable {
    /// Every group-version the server advertises, including ones whose resource
    /// list could not be read.
    public let groupVersions: [GroupVersion]
    public let resources: [DiscoveredResource]
    /// Group-versions that were advertised but produced no usable resource list.
    public let failures: [GroupVersion: DiscoveryFailure]
    public let discoveredAt: Date

    public init(
        groupVersions: [GroupVersion],
        resources: [DiscoveredResource],
        failures: [GroupVersion: DiscoveryFailure] = [:],
        discoveredAt: Date = Date()
    ) {
        self.groupVersions = groupVersions
        self.resources = resources
        self.failures = failures
        self.discoveredAt = discoveredAt
    }

    public static let empty = APIResourceCatalog(
        groupVersions: [],
        resources: [],
        discoveredAt: Date(timeIntervalSince1970: 0)
    )

    /// The group names the server serves, core first and the rest sorted.
    public var groupNames: [String] {
        var names = Set(groupVersions.map(\.group))
        let hasCore = names.remove("") != nil
        return (hasCore ? [""] : []) + names.sorted()
    }

    public func versions(ofGroup group: String) -> [String] {
        groupVersions.filter { $0.group == group }.map(\.version)
    }

    public func isServed(_ groupVersion: GroupVersion) -> Bool {
        groupVersions.contains(groupVersion)
    }

    /// Every kind that has a collection endpoint, sorted for stable presentation.
    public var kinds: [GroupVersionKind] {
        resources
            .map(\.groupVersionKind)
            .sorted { ($0.kind, $0.groupVersion.apiVersion) < ($1.kind, $1.groupVersion.apiVersion) }
    }

    /// Looks a kind up, preferring the server's preferred version when more than one
    /// version serves it. Pass `group` to disambiguate a kind two groups both define.
    public func resource(forKind kind: String, inGroup group: String? = nil) -> DiscoveredResource? {
        let matches = resources.filter { candidate in
            candidate.kind == kind && (group == nil || candidate.groupVersion.group == group)
        }
        return preferred(among: matches)
    }

    /// Looks a resource up by the plural name or a short name, the way a user types
    /// it (`po`, `pods`, `deployments.apps`).
    public func resource(forName name: String, inGroup group: String? = nil) -> DiscoveredResource? {
        let lowercased = name.lowercased()
        let matches = resources.filter { candidate in
            guard group == nil || candidate.groupVersion.group == group else { return false }
            return candidate.resourceName == lowercased
                || candidate.singularName == lowercased
                || candidate.shortNames.contains(lowercased)
        }
        return preferred(among: matches)
    }

    public func resource(for groupVersionKind: GroupVersionKind) -> DiscoveredResource? {
        resources.first {
            $0.kind == groupVersionKind.kind && $0.groupVersion == groupVersionKind.groupVersion
        }
    }

    /// The denial that explains why a kind is absent, if one applies: either the
    /// named group was refused, or — when no group was named — some group-version
    /// was, which is enough to make "missing" an unsafe answer.
    public func denial(forKind kind: String, inGroup group: String?) -> DiscoveryFailure? {
        let denied = failures.filter { if case .permissionDenied = $0.value { return true } else { return false } }
        guard !denied.isEmpty else { return nil }
        if let group {
            return denied.first { $0.key.group == group }?.value
        }
        return denied.sorted { $0.key.apiVersion < $1.key.apiVersion }.first?.value
    }

    private func preferred(among matches: [DiscoveredResource]) -> DiscoveredResource? {
        matches.first(where: \.isPreferredVersion)
            ?? matches.min { $0.groupVersion.apiVersion < $1.groupVersion.apiVersion }
    }
}
