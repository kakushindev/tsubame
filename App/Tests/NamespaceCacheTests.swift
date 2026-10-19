import Foundation
import Testing
import KubeKit
import KubeModels
import KubeTestSupport
@testable import Tsubame

@Suite("Namespace cache") @MainActor
struct NamespaceCacheTests {
    private func session(_ replies: [StubTransport.Reply]) -> ClusterSession {
        let connection = ClusterConnection(
            displayName: "prod", serverURL: URL(string: "https://cluster.example:6443")!,
            contextName: "prod", authenticationMethod: .bearerToken,
            credentialReference: .init(account: "prod"), tls: .systemDefault
        )
        return ClusterSession(
            connection: connection,
            client: KubernetesClient(transport: StubTransport(replies: replies))
        )
    }

    private func namespaceList(_ names: [String]) -> StubTransport.Reply {
        let items = names.map { #"{"metadata":{"name":"\#($0)","uid":"uid-\#($0)"}}"# }
        return .response(.ok(json: """
        {"apiVersion":"v1","kind":"NamespaceList","metadata":{"resourceVersion":"1"},
         "items":[\(items.joined(separator: ","))]}
        """))
    }

    private func discovered() -> APIResourceCatalog {
        APIResourceCatalog(groupVersions: [.core], resources: [
            DiscoveredResource(
                groupVersionResource: .init(groupVersion: .core, resource: "namespaces", isNamespaced: false),
                kind: "Namespace", singularName: "namespace", verbs: ["list"], isPreferredVersion: true
            ),
        ])
    }

    @Test("Nothing is cached until the control first asks")
    func startsEmpty() {
        #expect(session([]).namespaceOptions == nil)
    }

    @Test("A refresh that finds the same namespaces leaves the cache alone")
    func unchangedListIsNotReplaced() async throws {
        let subject = session([namespaceList(["a", "b"]), namespaceList(["b", "a"])])
        subject.adoptCatalogForTesting(discovered())

        #expect(await subject.refreshNamespaces() == .loaded(["a", "b"]))
        // Same names, different order: still the same answer, so no redraw.
        #expect(await subject.refreshNamespaces() == .loaded(["a", "b"]))
    }

    @Test("A namespace that appeared is picked up")
    func newNamespaceIsAdopted() async throws {
        let subject = session([namespaceList(["a"]), namespaceList(["a", "payments"])])
        subject.adoptCatalogForTesting(discovered())

        #expect(await subject.refreshNamespaces() == .loaded(["a"]))
        #expect(await subject.refreshNamespaces() == .loaded(["a", "payments"]))
        #expect(subject.namespaceOptions == .loaded(["a", "payments"]))
    }

    @Test("A failed refresh keeps the namespaces already known")
    func failureKeepsTheCache() async throws {
        // One refused or dropped request is not evidence the namespaces went
        // away, and dropping them would take away the names being worked with.
        let subject = session([
            namespaceList(["a", "b"]),
            .response(.failure(statusCode: 403, reason: "Forbidden", message: "denied")),
            .failure(KubernetesError.networkUnreachable(underlying: "offline")),
        ])
        subject.adoptCatalogForTesting(discovered())

        #expect(await subject.refreshNamespaces() == .loaded(["a", "b"]))
        #expect(await subject.refreshNamespaces() == .loaded(["a", "b"]))
        #expect(await subject.refreshNamespaces() == .loaded(["a", "b"]))
    }

    @Test("A denial with nothing cached is reported, not hidden")
    func denialWithoutCacheSurfaces() async throws {
        let subject = session([
            .response(.failure(statusCode: 403, reason: "Forbidden", message: "denied")),
        ])
        subject.adoptCatalogForTesting(discovered())
        // The account may still use a namespace it cannot enumerate, so the
        // control has to say so rather than show an empty list (PRD §12).
        #expect(await subject.refreshNamespaces() == .denied)
    }

    @Test("Invalidating a session forgets what it had read")
    func invalidateClearsState() async throws {
        let subject = session([namespaceList(["a", "b"])])
        subject.adoptCatalogForTesting(discovered())
        #expect(await subject.refreshNamespaces() == .loaded(["a", "b"]))

        await subject.invalidate()

        // Nothing is kept from a context the user closed: reconnecting reads the
        // cluster again rather than showing what it looked like before.
        #expect(subject.namespaceOptions == nil)
        #expect(subject.catalog == nil)
        #expect(subject.state == .connecting)
    }
}
