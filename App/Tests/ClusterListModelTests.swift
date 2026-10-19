import Foundation
import Testing
import KubeModels
@testable import Tsubame

@Suite("ClusterListModel")
@MainActor
struct ClusterListModelTests {
    private func makeModel() -> ClusterListModel {
        ClusterListModel(environment: .inMemory(), discovery: NoKubeconfigDiscovery())
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
