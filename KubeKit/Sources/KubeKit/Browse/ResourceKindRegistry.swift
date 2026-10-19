import Foundation
import KubeModels

/// How one kind is listed and watched.
///
/// This is the contract the browse UI builds against: given a kind, it gets columns
/// to render and a watcher to drive them, without knowing whether a typed model
/// exists for it.
public struct ResourceKindBinding: Sendable {
    public let groupVersionKind: GroupVersionKind
    /// The plural REST name to use when discovery has not answered yet. Discovery
    /// wins whenever it has.
    public let defaultResourceName: String
    /// Column headers, matching `ResourceRowSummary.fields` by position.
    public let columns: [String]
    /// Builds the watcher. Typed kinds get a `ResourceWatcher<Pod>` and friends;
    /// everything else gets `GenericResource`; a kind discovery says cannot be
    /// watched gets the rate-limited polling fallback instead.
    public let makeWatcher: @Sendable (
        _ client: KubernetesClient,
        _ resource: DiscoveredResource,
        _ namespace: String?,
        _ options: ListOptions
    ) -> any ResourceWatching

    public init(
        groupVersionKind: GroupVersionKind,
        defaultResourceName: String,
        columns: [String],
        makeWatcher: @escaping @Sendable (
            KubernetesClient, DiscoveredResource, String?, ListOptions
        ) -> any ResourceWatching
    ) {
        self.groupVersionKind = groupVersionKind
        self.defaultResourceName = defaultResourceName
        self.columns = columns
        self.makeWatcher = makeWatcher
    }
}

/// Maps kinds to how they are browsed.
///
/// The one place that decides typed-versus-generic. An unknown kind is not an
/// error here: it is a generic kind, which is what makes custom resources work
/// without any per-CRD code.
public struct ResourceKindRegistry: Sendable {
    private let bindings: [GroupVersionKind: ResourceKindBinding]

    public init(bindings: [ResourceKindBinding]) {
        self.bindings = Dictionary(
            bindings.map { ($0.groupVersionKind, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The binding for a kind. Never fails.
    public func binding(for groupVersionKind: GroupVersionKind) -> ResourceKindBinding {
        bindings[groupVersionKind] ?? Self.generic(for: groupVersionKind)
    }

    public func hasTypedModel(for groupVersionKind: GroupVersionKind) -> Bool {
        bindings[groupVersionKind] != nil
    }

    public var typedKinds: [GroupVersionKind] { Array(bindings.keys) }

    // MARK: - Building watchers

    /// Builds a watcher for a typed kind, falling back to polling where the server
    /// says the resource cannot be watched (PRD §9.3).
    static func watcher<Object: ResourceObject & Codable>(
        of type: Object.Type,
        summarize: @escaping @Sendable (Object) -> ResourceRowSummary,
        client: KubernetesClient,
        resource: DiscoveredResource,
        namespace: String?,
        options: ListOptions
    ) -> any ResourceWatching {
        let target = resource.groupVersionResource
        guard resource.isWatchable else {
            return ErasedPollingWatcher(
                watcher: PollingResourceWatcher<Object>(
                    client: client, resource: target, namespace: namespace, options: options
                ),
                summarize: summarize
            )
        }
        return ErasedResourceWatcher(
            watcher: ResourceWatcher<Object>(
                client: client, resource: target, namespace: namespace, options: options
            ),
            summarize: summarize
        )
    }

    static func generic(for groupVersionKind: GroupVersionKind) -> ResourceKindBinding {
        ResourceKindBinding(
            groupVersionKind: groupVersionKind,
            defaultResourceName: "",
            columns: ["Status"],
            makeWatcher: { client, resource, namespace, options in
                watcher(
                    of: GenericResource.self,
                    summarize: { $0.genericRowSummary },
                    client: client,
                    resource: resource,
                    namespace: namespace,
                    options: options
                )
            }
        )
    }

    private static func typed<Object: TypedResource>(
        _ type: Object.Type,
        columns: [String],
        summarize: @escaping @Sendable (Object) -> ResourceRowSummary
    ) -> ResourceKindBinding {
        ResourceKindBinding(
            groupVersionKind: Object.typeIdentity,
            defaultResourceName: Object.resourceName,
            columns: columns,
            makeWatcher: { client, resource, namespace, options in
                watcher(
                    of: Object.self,
                    summarize: summarize,
                    client: client,
                    resource: resource,
                    namespace: namespace,
                    options: options
                )
            }
        )
    }

    /// The kinds the MVP models explicitly (PRD §9.2).
    public static let mvp = ResourceKindRegistry(bindings: [
        typed(Pod.self, columns: ["Ready", "Restarts", "Node"]) { $0.rowSummary },
        typed(Deployment.self, columns: ["Ready", "Up-to-date"]) { $0.rowSummary },
        typed(StatefulSet.self, columns: ["Ready", "Up-to-date"]) { $0.rowSummary },
        typed(DaemonSet.self, columns: ["Ready", "Up-to-date"]) { $0.rowSummary },
        typed(Job.self, columns: ["Completions", "Failed"]) { $0.rowSummary },
        typed(CronJob.self, columns: ["Schedule", "Active"]) { $0.rowSummary },
        typed(Service.self, columns: ["Type", "Cluster IP", "Ports"]) { $0.rowSummary },
        typed(Namespace.self, columns: []) { $0.rowSummary },
        typed(Event.self, columns: ["Reason", "Object", "Count", "Message"]) { $0.rowSummary },
        typed(ConfigMap.self, columns: ["Keys"]) { $0.rowSummary },
        typed(Secret.self, columns: ["Keys", "Type"]) { $0.rowSummary },
    ])
}
