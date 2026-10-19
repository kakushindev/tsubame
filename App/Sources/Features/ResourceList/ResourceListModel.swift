import Foundation
import Observation
import KubeKit
import KubeModels

@MainActor @Observable
final class ResourceListModel {
    struct Row: Identifiable, Hashable {
        let id: String
        let name: String
        let namespace: String?
        let summary: ResourceRowSummary
        let createdAt: Date?
    }

    private(set) var snapshot: ErasedResourceSnapshot?
    private(set) var rows: [Row] = []
    var search = ""
    private let watcher: any ResourceWatching

    /// `namespaces` is empty for a cluster-scoped kind. More than one means one
    /// watch per namespace, merged: the API has no call that lists a chosen few.
    init(
        client: KubernetesClient,
        resource: DiscoveredResource,
        namespaces: [String],
        search: String = ""
    ) {
        self.search = search
        let binding = ResourceKindRegistry.mvp.binding(for: resource.groupVersionKind)
        let options = ListOptions(limit: 500)
        if namespaces.count <= 1 {
            watcher = binding.makeWatcher(client, resource, namespaces.first, options)
        } else {
            watcher = CompositeResourceWatcher(
                children: namespaces.map { binding.makeWatcher(client, resource, $0, options) }
            )
        }
    }

    var filteredRows: [Row] {
        search.isEmpty ? rows : rows.filter { $0.name.localizedStandardContains(search) }
    }

    func run() async {
        for await snapshot in await watcher.snapshots() {
            guard !Task.isCancelled else { break }
            rows = snapshot.rows.map {
                Row(id: $0.id, name: $0.name, namespace: $0.namespace, summary: $0.summary,
                    createdAt: $0.object.metadata.creationTimestamp)
            }
            self.snapshot = snapshot
        }
        await watcher.stop()
    }
}
