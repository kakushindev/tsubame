import Foundation
import Observation
import KubeKit
import KubeModels

@MainActor @Observable
final class ResourceDetailModel {
    private(set) var object: GenericResource?
    private(set) var failure: String?
    private(set) var loadedAt: Date?
    private(set) var freshness: DataFreshness = .disconnected(since: .now)
    private let client: KubernetesClient
    let target: WriteTarget

    init(client: KubernetesClient, target: WriteTarget) {
        self.client = client
        self.target = target
    }

    /// One needed object, using the same list/watch recovery as a collection.
    /// The name selector is present on both requests, including reconnects.
    func run() async {
        let binding = ResourceKindRegistry(bindings: []).binding(for: target.resource.groupVersionKind)
        let watcher = binding.makeWatcher(
            client, target.resource, target.namespace,
            ListOptions(fieldSelector: "metadata.name=\(target.name)")
        )
        for await snapshot in await watcher.snapshots() {
            guard !Task.isCancelled else { break }
            adopt(snapshot)
        }
        await watcher.stop()
    }

    private func adopt(_ snapshot: ErasedResourceSnapshot) {
        freshness = snapshot.freshness
        failure = snapshot.failure?.localizedDescription
        if let row = snapshot.rows.first(where: { $0.name == target.name && $0.namespace == target.namespace }) {
            object = GenericResource(groupVersionKind: row.object.groupVersionKind,
                                     metadata: row.object.metadata, raw: row.object.raw)
            if snapshot.freshness.isLive || isPolling(snapshot.freshness) { loadedAt = Date() }
        } else if snapshot.freshness.isLive || isPolling(snapshot.freshness) {
            // An authoritative empty list or delete event is different from a
            // failed connection. Do not leave actions pointing at a deleted object.
            object = nil
            failure = "This object no longer exists."
        }
    }

    func pause() {
        freshness = loadedAt.map { .stale(lastUpdated: $0) } ?? .disconnected(since: .now)
    }

    private func isPolling(_ freshness: DataFreshness) -> Bool {
        if case .polling = freshness { return true }
        return false
    }

    var yaml: String { object.flatMap { try? ManifestParser().yaml(from: $0.raw) } ?? "" }
    var secret: Secret? {
        guard target.resource.groupVersion.group.isEmpty, target.resource.kind == "Secret",
              let raw = object?.raw, let data = try? JSONEncoder().encode(raw) else { return nil }
        return try? KubernetesCoder().decoder.decode(Secret.self, from: data)
    }
}
