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
    let access: any AccessReviewing
    var namespaces: [String]
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
        let discovery = ServerAPIDiscovery(client: client)
        self.discovery = discovery
        self.access = SelfSubjectAccessReviewer(client: client, discovery: discovery)
        self.namespaces = [connection.defaultNamespace]
    }

    /// How long discovery may run before the context is reported as unreachable.
    ///
    /// A cluster behind a VPN that is not connected accepts the TCP connection and
    /// then says nothing, so without a bound the navigator spins indefinitely and
    /// never explains itself.
    static let discoveryTimeout: TimeInterval = 15

    func discover() async {
        do {
            let discovery = self.discovery
            let result = try await withTaskCancellationHandler {
                try await Self.withTimeout(seconds: Self.discoveryTimeout) {
                    try await discovery.catalog()
                }
            } onCancel: {
                Task { await discovery.invalidate() }
            }
            try Task.checkCancellation()
            catalog = result
            failure = nil
        } catch is CancellationError { }
        catch {
            // Stop the sweep that is still running against a cluster nobody is
            // waiting for any more.
            let discovery = self.discovery
            Task { await discovery.invalidate() }
            failure = error.localizedDescription
        }
    }

    /// Runs `work`, failing if it has not finished within `seconds`.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw KubernetesError.networkUnreachable(
                    underlying: "it did not respond within \(Int(seconds)) seconds."
                )
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    /// Discards the failed catalog and discovers again.
    func retry() async {
        failure = nil
        catalog = nil
        await discovery.invalidate()
        await discover()
    }

    /// The namespaces last read from this cluster.
    ///
    /// Held for the life of the context so opening the scope control does not
    /// re-ask the cluster every time. In memory only, and gone with the session:
    /// nothing the cluster returns is written anywhere (PRD §12).
    private(set) var namespaceOptions: NamespaceControl.Options?

    /// Re-reads the namespaces and keeps the result when it says something new.
    ///
    /// A list that comes back unchanged leaves the cached value alone, so the
    /// control does not redraw for nothing. A read that fails after a good list
    /// keeps the list: one refused or dropped request is not evidence the
    /// namespaces went away, and dropping them would take away the names the user
    /// is working with.
    @discardableResult
    func refreshNamespaces() async -> NamespaceControl.Options {
        let fresh = await loadNamespaces()
        switch (namespaceOptions, fresh) {
        case (.some(.loaded(let known)), .loaded(let found)) where known == found:
            break
        case (_, .loaded):
            namespaceOptions = fresh
        case (.some(.loaded), _):
            break
        default:
            namespaceOptions = fresh
        }
        return namespaceOptions ?? fresh
    }

    /// A denial is its own answer rather than an error: an account may be allowed
    /// to work inside a namespace and not to enumerate them, and the control says
    /// so instead of showing an empty menu (PRD §12).
    private func loadNamespaces() async -> NamespaceControl.Options {
        guard let resource = catalog?.resource(forKind: "Namespace", inGroup: "") else {
            return .denied
        }
        do {
            let list = try await client.list(
                resource.groupVersionResource,
                namespace: nil,
                options: ListOptions(limit: 500),
                as: GenericResource.self
            )
            return .loaded(list.items.map(\.name).sorted())
        } catch KubernetesError.permissionDenied {
            return .denied
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Stops this context's work and forgets what it had read.
    ///
    /// Called when the user disconnects: the client is about to be dropped, and a
    /// discovery sweep still running against a cluster nobody is watching is both
    /// wasted and a request the user did not ask for.
    func invalidate() async {
        await discovery.invalidate()
        catalog = nil
        namespaceOptions = nil
        failure = nil
    }

    #if DEBUG
    /// Lets a test supply the catalog that discovery would otherwise fetch.
    func adoptCatalogForTesting(_ value: APIResourceCatalog) { catalog = value }
    #endif

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
