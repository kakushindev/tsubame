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

    /// A binding that renders a custom resource through the columns its own
    /// definition asks for.
    ///
    /// This is what makes a CRD readable without the app knowing anything about
    /// it. Columns the definition marks as lower priority are detail for a wide
    /// listing, so only the default ones appear.
    public func binding(
        for definition: CustomResourceDefinition, version: String
    ) -> ResourceKindBinding {
        let columns = (definition.versions.first { $0.name == version }?.additionalPrinterColumns ?? [])
            .filter { $0.priority == 0 }
        guard !columns.isEmpty else {
            return Self.generic(for: definition.groupVersionKind(version: version))
        }
        return ResourceKindBinding(
            groupVersionKind: definition.groupVersionKind(version: version),
            defaultResourceName: definition.names.plural,
            columns: columns.map(\.name),
            makeWatcher: { client, resource, namespace, options in
                Self.watcher(
                    of: GenericResource.self,
                    summarize: { object in Self.summary(of: object, columns: columns) },
                    client: client,
                    resource: resource,
                    namespace: namespace,
                    options: options
                )
            }
        )
    }

    /// Builds a row from the definition's printer columns.
    ///
    /// A column named Ready, Status or Phase carries the row's state, because
    /// that is the convention CRD authors already follow; anything else becomes a
    /// field. A column whose path does not resolve is left out rather than shown
    /// as a blank the user has to interpret.
    static func summary(
        of object: GenericResource, columns: [PrinterColumn]
    ) -> ResourceRowSummary {
        var fields: [ResourceRowSummary.Field] = []
        var headline: String?

        for column in columns {
            guard let value = column.value(in: object.raw), !value.isEmpty else { continue }
            let name = column.name.lowercased()
            if headline == nil, ["ready", "status", "phase", "state"].contains(name) {
                headline = value
            } else {
                fields.append(.init(label: column.name, value: value))
            }
        }

        if object.metadata.deletionTimestamp != nil {
            return ResourceRowSummary(headline: "Terminating", fields: fields, tone: .terminating)
        }
        guard let headline else {
            return ResourceRowSummary(headline: "—", fields: fields, tone: .normal)
        }
        return ResourceRowSummary(headline: headline, fields: fields, tone: tone(forColumnValue: headline))
    }

    static func tone(forColumnValue value: String) -> ResourceRowSummary.Tone {
        switch value.lowercased() {
        case "true", "ready", "running", "active", "succeeded", "healthy", "bound", "available":
            return .normal
        case "false", "failed", "error", "unhealthy", "degraded":
            return .failure
        case "pending", "progressing", "creating", "reconciling", "unknown":
            return .pending
        default:
            return .attention
        }
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
