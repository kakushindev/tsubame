import Foundation
import KubeModels

/// One published state of a watched collection: what the objects are, and how much
/// the viewer may trust them.
///
/// Freshness travels with the objects rather than beside them, so a view cannot
/// render a list without also having been told whether it is live (PRD §9.3).
public struct ResourceSnapshot<Object: ResourceObject>: Sendable {
    public let objects: [Object]
    /// The version the next watch would resume from; `nil` once the cache is
    /// discarded and before the relist completes.
    public let resourceVersion: String?
    public let freshness: DataFreshness
    /// The failure that stopped the watch, if one did. Objects are still carried,
    /// because a denial or a drop must be shown over the last known data rather
    /// than as an empty list.
    public let failure: KubernetesError?

    public init(
        objects: [Object],
        resourceVersion: String?,
        freshness: DataFreshness,
        failure: KubernetesError? = nil
    ) {
        self.objects = objects
        self.resourceVersion = resourceVersion
        self.freshness = freshness
        self.failure = failure
    }

    public var isLive: Bool { freshness.isLive }
}
