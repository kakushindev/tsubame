import Foundation
import KubeModels

/// A live view of one collection, whatever concrete type backs it.
///
/// The browse layer holds this rather than a `ResourceWatcher<Pod>`, so a typed
/// kind, an unknown kind and a kind that cannot be watched at all are the same
/// thing to a list screen.
public protocol ResourceWatching: Sendable {
    func snapshots() async -> AsyncStream<ErasedResourceSnapshot>
    func stop() async
}

/// One published state of a watched collection, ready for a list.
public struct ErasedResourceSnapshot: Sendable {
    public struct Row: Hashable, Sendable, Identifiable {
        public let id: String
        public let object: AnyResourceObject
        public let summary: ResourceRowSummary

        public init(id: String, object: AnyResourceObject, summary: ResourceRowSummary) {
            self.id = id
            self.object = object
            self.summary = summary
        }

        public var name: String { object.metadata.name }
        public var namespace: String? { object.metadata.namespace }
    }

    public let rows: [Row]
    public let resourceVersion: String?
    public let freshness: DataFreshness
    /// The failure that stopped the watch, if one did. Rows are still carried: a
    /// denial or a drop is shown over the last known data, never as an empty list.
    public let failure: KubernetesError?
    /// Items the server returned that could not be decoded. The list says it is
    /// partial rather than quietly showing fewer rows (PRD §9.2).
    public let undecodableItemCount: Int

    public init(
        rows: [Row],
        resourceVersion: String?,
        freshness: DataFreshness,
        failure: KubernetesError? = nil,
        undecodableItemCount: Int = 0
    ) {
        self.rows = rows
        self.resourceVersion = resourceVersion
        self.freshness = freshness
        self.failure = failure
        self.undecodableItemCount = undecodableItemCount
    }

    public var isPartial: Bool { undecodableItemCount > 0 }
}

/// Wraps a concrete `ResourceWatcher` and publishes erased snapshots.
///
/// `ResourceWatcher` is deliberately left alone — it is the most heavily tested type
/// in the package, and the list/watch loop it implements is the one thing least
/// worth disturbing. Erasure is a layer on top, with its own tests.
public actor ErasedResourceWatcher<Object: ResourceObject & Codable>: ResourceWatching {
    private let watcher: ResourceWatcher<Object>
    private let summarize: @Sendable (Object) -> ResourceRowSummary

    public init(
        watcher: ResourceWatcher<Object>,
        summarize: @escaping @Sendable (Object) -> ResourceRowSummary
    ) {
        self.watcher = watcher
        self.summarize = summarize
    }

    public func snapshots() async -> AsyncStream<ErasedResourceSnapshot> {
        let upstream = await watcher.snapshots()
        let summarize = self.summarize
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await snapshot in upstream {
                    continuation.yield(
                        ErasedResourceSnapshot(
                            rows: snapshot.objects.map { object in
                                ErasedResourceSnapshot.Row(
                                    id: object.id,
                                    object: AnyResourceObject(object),
                                    summary: summarize(object)
                                )
                            },
                            resourceVersion: snapshot.resourceVersion,
                            freshness: snapshot.freshness,
                            failure: snapshot.failure
                        )
                    )
                }
                continuation.finish()
            }
            // Cancelling the consumer has to reach the underlying watcher, or the
            // HTTP request outlives the view that opened it.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() async {
        await watcher.stop()
    }
}
