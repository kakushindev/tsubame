import Foundation
import Testing
import KubeKit
import KubeModels
import KubeTestSupport
@testable import Tsubame

@Suite("Write workflows") @MainActor
struct WriteWorkflowTests {
    private let resource = DiscoveredResource(
        groupVersionResource: .init(groupVersion: .core, resource: "configmaps", isNamespaced: true),
        kind: "ConfigMap", singularName: "configmap", verbs: ["patch", "delete"]
    )
    private let original: JSONValue = .object([
        "apiVersion": .string("v1"), "kind": .string("ConfigMap"),
        "metadata": .object(["name": .string("settings"), "namespace": .string("default"), "resourceVersion": .string("1")]),
        "data": .object(["password": .string("actual-value")]),
    ])
    private var key: EditorDraftStore.Key {
        .init(connectionID: UUID(), target: .init(resource: resource, namespace: "default", name: "settings"))
    }
    private func model(transport: StubTransport, store: EditorDraftStore, key: EditorDraftStore.Key) -> YAMLEditorModel {
        YAMLEditorModel(cluster: "test", key: key, original: original,
                        writer: ResourceWriter(client: KubernetesClient(transport: transport)), drafts: store)
    }
    private func ok(_ value: JSONValue) throws -> StubTransport.Reply {
        .response(APIResponse(statusCode: 200, headers: [:], body: try JSONEncoder().encode(value)))
    }

    @Test func rejectedDryRunKeepsDraftAndBlocksApply() async {
        let store = EditorDraftStore()
        let key = key
        let transport = StubTransport(replies: [.response(.failure(statusCode: 403, reason: "Forbidden", message: "patch denied"))])
        let model = model(transport: transport, store: store, key: key)
        model.text += "\n# preserved edit"
        let edited = model.text
        await model.dryRun()
        #expect(model.text == edited)
        #expect(store.text(for: key) == edited)
        #expect(model.rehearsal == nil)
        await model.apply()
        #expect(await transport.sentRequests.count == 1)
        guard case .rejected = model.state else { Issue.record("Denial must be explicit"); return }
    }

    @Test func editAfterReviewInvalidatesApproval() async throws {
        let transport = StubTransport(replies: [try ok(original)])
        let store = EditorDraftStore()
        let model = model(transport: transport, store: store, key: key)
        await model.dryRun()
        #expect(model.rehearsal != nil)
        model.text += "\n# new edit"
        #expect(model.rehearsal == nil)
        await model.apply()
        #expect(await transport.sentRequests.count == 1)
    }

    @Test func changedServerResultPreservesDraftAndReturnsToReview() async throws {
        let changed = ManifestParser()
        let proposal = try changed.parse("apiVersion: v1\nkind: ConfigMap\nmetadata: {name: settings, namespace: default}\ndata: {password: changed-by-server}")
        let transport = StubTransport(replies: [try ok(original), try ok(proposal)])
        let store = EditorDraftStore()
        let key = key
        let model = model(transport: transport, store: store, key: key)
        model.text += "\n# keep"
        await model.dryRun()
        await model.apply()
        guard case .conflict = model.state else { Issue.record("Expected conflict"); return }
        #expect(store.text(for: key) == model.text)
        #expect(model.rehearsal == nil)
        #expect(await transport.sentRequests.count == 2)
    }

    @Test func applyNeedsSeparateActionAndClearsOnlyTheAppliedDraft() async throws {
        let transport = StubTransport(replies: [try ok(original), try ok(original), try ok(original)])
        let store = EditorDraftStore()
        let key = key
        let otherKey = self.key
        store.save("other resource content", for: otherKey)
        let model = model(transport: transport, store: store, key: key)
        model.text += "\n# edit"
        await model.dryRun()
        #expect(await transport.sentRequests.count == 1)
        await model.apply()
        #expect(store.text(for: key) == nil)
        #expect(store.text(for: otherKey) == "other resource content")
        guard case .applied = model.state else { Issue.record("Expected applied"); return }
    }

    @Test func keptDraftReopensAndRemainsScopedToItsCluster() {
        let store = EditorDraftStore()
        let key = key
        let first = model(transport: StubTransport(), store: store, key: key)
        first.text = "preserved text"
        let reopened = model(transport: StubTransport(), store: store, key: key)
        #expect(reopened.text == "preserved text")
        let other = model(transport: StubTransport(), store: store, key: self.key)
        #expect(other.text != "preserved text")
        #expect(store.hasPendingDrafts)
    }

    @Test func revertingToInitialSourceAfterApplyIsANewDraft() async throws {
        let parser = ManifestParser()
        let updated = try parser.parse(parser.yaml(from: original).replacingOccurrences(of: "actual-value", with: "new-value"))
        let transport = StubTransport(replies: [try ok(updated), try ok(updated), try ok(updated), try ok(original)])
        let store = EditorDraftStore()
        let key = key
        let model = model(transport: transport, store: store, key: key)
        let initialSource = model.text
        model.text = initialSource.replacingOccurrences(of: "actual-value", with: "new-value")
        await model.dryRun()
        await model.apply()
        #expect(!model.hasChanges)
        model.text = initialSource
        #expect(model.hasChanges)
        #expect(store.text(for: key) == initialSource)
        await model.dryRun()
        #expect(model.diff.contains { $0.change == .removed && $0.text.contains("new-value") })
        #expect(model.diff.contains { $0.change == .added && $0.text.contains("actual-value") })
    }

    @Test func logsOfferPreviousOnlyForTerminatedContainers() throws {
        let pod = try KubernetesCoder().decoder.decode(GenericResource.self, from: Data("""
        {"apiVersion":"v1","kind":"Pod","metadata":{"name":"api","namespace":"default"},
         "spec":{"containers":[{"name":"web"},{"name":"sidecar"}],"initContainers":[{"name":"init"}]},
         "status":{"containerStatuses":[{"name":"web","lastState":{"terminated":{"exitCode":1}}}]}}
        """.utf8))
        let model = LogsModel(cluster: "test", pod: pod, client: KubernetesClient(transport: StubTransport()))
        #expect(model.containers.map(\.name) == ["web", "sidecar", "init"])
        #expect(model.canReadPrevious)
        model.container = "sidecar"
        #expect(!model.canReadPrevious)
        model.start()
        #expect(model.isStarted)
        model.setForeground(false) // inactive
        #expect(!model.isStarted)
        model.setForeground(false) // background
        model.setForeground(true)
        #expect(model.isStarted, "Inactive → background must not lose the pending resume")
        model.stop()
    }
}
