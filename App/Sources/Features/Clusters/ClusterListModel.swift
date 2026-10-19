import Foundation
import Observation
import KubeKit
import KubeModels

/// Drives the cluster sidebar and the kubeconfig import flow.
///
/// Holding the state here keeps `ClusterListView` free of logic, and keeps the
/// parsing and storage work off the view's identity, so a redraw never re-runs it.
@MainActor
@Observable
final class ClusterListModel {
    /// What the sidebar is doing. A failed import stays on screen with its reason
    /// instead of resetting to an empty list.
    enum ImportState: Equatable {
        case idle
        case parsing
        case choosingContext([KubeconfigContextSummary])
        case failed(String)
    }

    private(set) var connections: [ClusterConnection] = []
    private(set) var importState: ImportState = .idle

    private let parser: any KubeconfigParsing
    private let discovery: any KubeconfigDiscovery

    init(environment: AppEnvironment, discovery: (any KubeconfigDiscovery)? = nil) {
        self.parser = environment.kubeconfigParser
        self.discovery = discovery ?? environment.kubeconfigDiscovery
    }

    /// Paths worth offering without a file picker. Empty on iOS and iPadOS.
    var discoveredConfigurations: [URL] {
        discovery.discoveredConfigurations()
    }

    /// Parses pasted or imported kubeconfig text and presents its contexts.
    /// Nothing is stored and no request is sent until the user picks a context.
    func importKubeconfig(text: String) {
        importState = .parsing
        do {
            let contexts = try parser.parse(text).contextSummaries
            guard !contexts.isEmpty else {
                importState = .failed("That kubeconfig contains no contexts.")
                return
            }
            importState = .choosingContext(contexts)
        } catch {
            importState = .failed(error.localizedDescription)
        }
    }

    func importKubeconfig(contentsOf url: URL) {
        do {
            importState = .parsing
            importKubeconfig(text: try String(contentsOf: url, encoding: .utf8))
        } catch {
            importState = .failed(error.localizedDescription)
        }
    }

    func cancelImport() {
        importState = .idle
    }
}
