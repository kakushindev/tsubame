import Foundation
import Testing
import KubeModels
import KubeKit
@testable import Tsubame

@Suite("ClusterListModel")
@MainActor
struct ClusterListModelTests {
    private func makeModel() -> ClusterListModel {
        ClusterListModel(environment: .inMemory(), discovery: NoKubeconfigDiscovery())
    }

    private let configuration = """
    apiVersion: v1
    kind: Config
    current-context: dev
    clusters:
      - name: local
        cluster: {server: 'https://dev.example.invalid:6443'}
    contexts:
      - name: dev
        context: {cluster: local, user: developer, namespace: default}
    users:
      - name: developer
        user: {token: sample-test-credential}
    """

    @Test("Discovered contexts appear before any credential is saved")
    func discoveredContextsAreReadOnlyUntilConnect() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try configuration.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CountingContextStore()
        let environment = AppEnvironment(credentialStore: store, kubeconfigParser: KubeconfigParser(),
                                         kubeconfigDiscovery: ContextDiscoveryFixture(urls: [url]), clientIdentities: nil, execRunner: nil)
        let model = ClusterListModel(environment: environment)
        model.loadDiscoveredConfigurations()
        #expect(model.availableContexts.map(\.name) == ["dev"])
        #expect(model.selectedContext?.name == "dev")
        #expect(model.connections.isEmpty)
        #expect(await store.writeCount == 0)
        let connected = try #require(await model.connectSelectedContext())
        #expect(connected.contextName == "dev")
        #expect(connected.defaultNamespace == "default")
        #expect(await store.writeCount == 1)
        let again = await model.connectSelectedContext()
        #expect(again?.id == connected.id)
        #expect(await store.writeCount == 1, "Reconnecting an unchanged source does not duplicate stored credentials")
    }

    @Test("Changed file contents cannot reuse a previously imported destination")
    func refreshedContextUsesNewDestination() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try configuration.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CountingContextStore()
        let environment = AppEnvironment(credentialStore: store, kubeconfigParser: KubeconfigParser(),
                                         kubeconfigDiscovery: ContextDiscoveryFixture(urls: [url]), clientIdentities: nil, execRunner: nil)
        let model = ClusterListModel(environment: environment)
        model.loadDiscoveredConfigurations()
        let first = try #require(await model.connectSelectedContext())
        try configuration.replacingOccurrences(of: "dev.example.invalid", with: "other.example.invalid")
            .write(to: url, atomically: true, encoding: .utf8)
        model.loadDiscoveredConfigurations(refresh: true)
        #expect(model.importPlan?.serverURL.host == "other.example.invalid")
        let next = try #require(await model.connectSelectedContext())
        #expect(next.id != first.id)
        #expect(next.serverURL.host == "other.example.invalid")
    }

    @Test("Separate discovered files remain separate sources instead of silently merging")
    func duplicateContextNamesStayDistinguishable() throws {
        let urls = (0..<2).map { _ in FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        for url in urls { try configuration.write(to: url, atomically: true, encoding: .utf8) }
        let environment = AppEnvironment(credentialStore: EphemeralCredentialStore(), kubeconfigParser: KubeconfigParser(),
                                         kubeconfigDiscovery: ContextDiscoveryFixture(urls: urls), clientIdentities: nil, execRunner: nil)
        let model = ClusterListModel(environment: environment)
        model.loadDiscoveredConfigurations()
        #expect(model.availableContexts.count == 2)
        #expect(Set(model.availableContexts.map(\.id)).count == 2)
        #expect(Set(model.availableContexts.map(\.sourceLabel)).count == 2)
    }

    @Test("Offers the contexts in an imported kubeconfig without storing anything")
    func offersContexts() {
        let model = makeModel()

        model.importKubeconfig(text: """
        apiVersion: v1
        kind: Config
        current-context: dev
        clusters:
          - name: dev-cluster
            cluster:
              server: https://dev.example.com:6443
        contexts:
          - name: dev
            context:
              cluster: dev-cluster
              user: dev-user
        users:
          - name: dev-user
            user:
              token: sample
        """)

        guard case .choosingContext(let contexts) = model.importState else {
            Issue.record("Expected choosingContext, got \(model.importState)")
            return
        }
        #expect(contexts.map(\.contextName) == ["dev"])
        #expect(contexts[0].namespace == ClusterConnection.defaultNamespaceName)
        #expect(model.connections.isEmpty)
    }

    @Test("Keeps the failure on screen when the document cannot be read")
    func reportsParseFailure() {
        let model = makeModel()

        model.importKubeconfig(text: "clusters: [this is: not valid")

        guard case .failed = model.importState else {
            Issue.record("Expected failed, got \(model.importState)")
            return
        }
    }

    @Test("Reports a kubeconfig with no contexts as a failure, not an empty picker")
    func reportsEmptyContextList() {
        let model = makeModel()

        model.importKubeconfig(text: "apiVersion: v1\nkind: Config\n")

        guard case .failed(let message) = model.importState else {
            Issue.record("Expected failed, got \(model.importState)")
            return
        }
        #expect(message.contains("no contexts"))
    }
}

private struct ContextDiscoveryFixture: KubeconfigDiscovery {
    let urls: [URL]
    func discoveredConfigurations() -> [URL] { urls }
}

private actor CountingContextStore: CredentialStore {
    private(set) var writeCount = 0
    private var values: [CredentialReference: Data] = [:]
    func credential(for reference: CredentialReference) async throws -> Data? { values[reference] }
    func store(_ credential: Data, for reference: CredentialReference) async throws { values[reference] = credential; writeCount += 1 }
    func removeCredential(for reference: CredentialReference) async throws { values[reference] = nil }
}
