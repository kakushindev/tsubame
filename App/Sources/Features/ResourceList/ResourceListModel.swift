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

    init(client: KubernetesClient, resource: DiscoveredResource, namespace: String?, search: String = "") {
        self.search = search
        watcher = ResourceKindRegistry.mvp.binding(for: resource.groupVersionKind)
            .makeWatcher(client, resource, namespace, ListOptions(limit: 500))
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
