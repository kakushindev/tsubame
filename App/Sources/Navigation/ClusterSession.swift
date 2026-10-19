import Foundation
import Observation
import KubeKit
import KubeModels

/// One context's collaborators. SwiftUI tasks below its id are cancelled together
/// on context switches; each screen closes its own stream on cancellation.
@MainActor @Observable
final class ClusterSession: Identifiable {
    let id = UUID()
    let connection: ClusterConnection
    let client: KubernetesClient
    let writer: ResourceWriter
    let discovery: any APIDiscovering
    var namespace: String
    private(set) var catalog: APIResourceCatalog?
    private(set) var failure: String?

    /// How this context is doing, as the navigator needs to show it.
    ///
    /// The navigator distinguishes these three rather than printing the failure
    /// text: a wrapped error message in a sidebar costs more room than the whole
    /// tree and still does not say what to do about it.
    enum State: Hashable {
        case connecting
        case ready
        case failed
    }

    var state: State {
        if failure != nil { return .failed }
        return catalog == nil ? .connecting : .ready
    }

    init(connection: ClusterConnection, client: KubernetesClient) {
        self.connection = connection
        self.client = client
        self.writer = ResourceWriter(client: client)
        self.discovery = ServerAPIDiscovery(client: client)
        self.namespace = connection.defaultNamespace
    }

    func discover() async {
        do {
            let discovery = self.discovery
            let result = try await withTaskCancellationHandler {
                try await discovery.catalog()
            } onCancel: {
                Task { await discovery.invalidate() }
            }
            try Task.checkCancellation()
            catalog = result
            failure = nil
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }

    /// Discards the failed catalog and discovers again.
    func retry() async {
        failure = nil
        catalog = nil
        await discovery.invalidate()
        await discover()
    }

    var resources: [DiscoveredResource] {
        guard let catalog else { return [] }
        // Prefer the server's preferred version; avoid duplicate kinds in navigation.
        var seen: Set<String> = []
        return catalog.resources.sorted {
            if $0.isPreferredVersion != $1.isPreferredVersion { return $0.isPreferredVersion }
            return $0.groupVersion.apiVersion < $1.groupVersion.apiVersion
        }.filter {
            $0.isListable && seen.insert("\($0.groupVersion.group)/\($0.kind)").inserted
        }.sorted { ($0.kind, $0.groupVersion.group) < ($1.kind, $1.groupVersion.group) }
    }
}
