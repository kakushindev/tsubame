import Foundation
import KubeModels

/// Reads what one cluster serves: its groups and versions, the REST endpoint behind
/// a kind, and what the user is allowed to see.
///
/// Discovery is a protocol because the browse layer asks it questions on every
/// navigation, and those call sites must be testable without a server. One instance
/// serves one cluster, and it caches: a context switch builds a new one rather than
/// invalidating this one.
public protocol APIDiscovering: Sendable {
    /// The cached catalog, fetching it once on first use.
    func catalog() async throws -> APIResourceCatalog

    /// Discards the cache and reads the server again. Refreshing is always an
    /// explicit act — a newly installed CRD appears because the user asked, not
    /// because a timer fired.
    @discardableResult
    func refresh() async throws -> APIResourceCatalog

    /// The endpoint for a kind, preferring the server's preferred version.
    ///
    /// Throws `KubernetesError.permissionDenied` when the kind is absent only
    /// because discovery was refused, and `.notFound` when the server genuinely does
    /// not serve it. A denial must never reach the user as a missing kind.
    func resource(forKind kind: String, inGroup group: String?) async throws -> DiscoveredResource
}

extension APIDiscovering {
    public func resource(forKind kind: String) async throws -> DiscoveredResource {
        try await resource(forKind: kind, inGroup: nil)
    }
}
