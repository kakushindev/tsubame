import Foundation
import Observation
import KubeKit
import KubeModels

/// Discovers and stages contexts without storing credentials or selecting a cluster.
@MainActor @Observable
final class ClusterListModel {
    enum ImportState: Equatable {
        case idle, parsing
        case choosingContext([KubeconfigContextSummary])
        case failed(String)
    }

    struct AvailableContext: Identifiable, Hashable {
        let id: String
        let summary: KubeconfigContextSummary
        let sourceID: String
        let sourceLabel: String
        var name: String { summary.contextName }
        var cluster: String { summary.clusterName }
        var server: String { summary.server.flatMap(URL.init(string:))?.host ?? summary.server ?? "Unavailable" }
        var namespace: String { summary.namespace }
        var user: String { summary.userName }
    }

    private(set) var connections: [ClusterConnection] = []
    private(set) var availableContexts: [AvailableContext] = []
    private(set) var importState: ImportState = .idle
    private(set) var importPlan: KubeconfigImportPlan?
    private(set) var isSaving = false
    private(set) var sourceFailures: [String] = []
    var selection: String? { didSet { prepareSelection() } }

    private let parser: any KubeconfigParsing
    private let discovery: any KubeconfigDiscovery
    private let importer: KubeconfigImporter
    private var documents: [String: Kubeconfig] = [:]
    private var directories: [String: URL] = [:]
    private var savedContexts: [String: UUID] = [:]
    private var discovered = false

    init(environment: AppEnvironment, discovery: (any KubeconfigDiscovery)? = nil) {
        parser = environment.kubeconfigParser
        self.discovery = discovery ?? environment.kubeconfigDiscovery
        importer = KubeconfigImporter(
            store: environment.credentialStore,
            identities: environment.clientIdentities,
            platform: environment.platform
        )
    }

    var discoveredConfigurations: [URL] { discovery.discoveredConfigurations() }
    var selectedContext: AvailableContext? { availableContexts.first { $0.id == selection } }
    var canConnect: Bool { selectedContext != nil && importPlan?.support.isUsableNow == true && !isSaving }

    /// Every file remains a separate source. This does not decide KUBECONFIG merge policy.
    func loadDiscoveredConfigurations(refresh: Bool = false) {
        guard !discovered || refresh else { return }
        discovered = true
        sourceFailures = []
        for url in discoveredConfigurations {
            do {
                try stage(String(contentsOf: url, encoding: .utf8), sourceID: url.absoluteString,
                          label: url.path,
                          directory: url.deletingLastPathComponent(), selectNew: false)
            } catch {
                sourceFailures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if selectedContext == nil {
            selection = availableContexts.first { $0.summary.isCurrent }?.id ?? availableContexts.first?.id
        }
    }

    func importKubeconfig(text: String) {
        do { try stage(text, sourceID: "pasted", label: "Pasted configuration", directory: nil, selectNew: true) }
        catch { importState = .failed(error.localizedDescription) }
    }

    func importKubeconfig(contentsOf url: URL) {
        do {
            try stage(String(contentsOf: url, encoding: .utf8), sourceID: url.absoluteString,
                      label: url.lastPathComponent, directory: url.deletingLastPathComponent(), selectNew: true)
        } catch { importState = .failed(error.localizedDescription) }
    }

    func reportImportFailure(_ error: any Error) { importState = .failed(error.localizedDescription) }

    func chooseContext(_ name: String) {
        selection = availableContexts.last { $0.name == name }?.id
    }

    func cancelImport() {
        selection = nil
        importPlan = nil
        importState = .idle
    }

    /// Connect is the single deliberate action which writes protected storage.
    /// The caller, not this model, decides whether to activate the returned context.
    func connectSelectedContext() async -> ClusterConnection? {
        guard canConnect, let entry = selectedContext, let plan = importPlan,
              let document = documents[entry.sourceID] else { return nil }
        if let id = savedContexts[entry.id], let connection = connections.first(where: { $0.id == id }) { return connection }
        isSaving = true
        defer { isSaving = false }
        do {
            let connection = try await importer.import(plan, from: document, sourceDirectory: directories[entry.sourceID])
            connections.append(connection)
            savedContexts[entry.id] = connection.id
            return connection
        } catch { importState = .failed(error.localizedDescription); return nil }
    }

    /// The context entry a saved connection came from, for a row that only knows
    /// the connection it is showing.
    func contextID(forConnection id: UUID) -> String? {
        savedContexts.first { $0.value == id }?.key
    }

    func connection(forContextID id: String) -> ClusterConnection? {
        guard let connectionID = savedContexts[id] else { return nil }
        return connections.first { $0.id == connectionID }
    }

    func saveContext() async { _ = await connectSelectedContext() }

    private func stage(_ text: String, sourceID: String, label: String, directory: URL?, selectNew: Bool) throws {
        importState = .parsing
        do {
            let document = try parser.parse(text)
            guard !document.contextSummaries.isEmpty else {
                throw KubernetesError.invalidConfiguration(reason: "That kubeconfig contains no cluster connections.")
            }
            if let previous = documents[sourceID], previous != document {
                for entry in availableContexts where entry.sourceID == sourceID { savedContexts[entry.id] = nil }
            }
            documents[sourceID] = document
            directories[sourceID] = directory
            let entries = document.contextSummaries.map {
                AvailableContext(id: sourceID + "#" + $0.contextName, summary: $0, sourceID: sourceID, sourceLabel: label)
            }
            availableContexts.removeAll { $0.sourceID == sourceID }
            availableContexts.append(contentsOf: entries)
            importState = .choosingContext(document.contextSummaries)
            if selectNew { selection = entries.first { $0.summary.isCurrent }?.id ?? entries.first?.id }
            else if selectedContext?.sourceID == sourceID { prepareSelection() }
        } catch {
            importState = .failed(error.localizedDescription)
            throw error
        }
    }

    private func prepareSelection() {
        importPlan = nil
        guard let entry = selectedContext, let document = documents[entry.sourceID] else { return }
        do { importPlan = try importer.plan(contextNamed: entry.name, in: document, sourceDirectory: directories[entry.sourceID]) }
        catch { importState = .failed(error.localizedDescription) }
    }
}
