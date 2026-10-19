import Foundation
import Testing
import KubeModels
@testable import Tsubame

@Suite("Workspace tabs") @MainActor
struct WorkspaceTabsTests {
    private let pods = DiscoveredResource(
        groupVersionResource: .init(groupVersion: .core, resource: "pods", isNamespaced: true),
        kind: "Pod", singularName: "pod", verbs: ["list", "watch"]
    )
    private let services = DiscoveredResource(
        groupVersionResource: .init(groupVersion: .core, resource: "services", isNamespaced: true),
        kind: "Service", singularName: "service", verbs: ["list", "watch"]
    )
    private func connection(_ name: String) -> ClusterConnection {
        .init(displayName: name, serverURL: URL(string: "https://example.invalid")!, contextName: name,
              defaultNamespace: "development", authenticationMethod: .bearerToken,
              credentialReference: .init(account: name), tls: .systemDefault)
    }

    @Test("Reopening a view preserves its own namespace and search across contexts")
    func independentScopes() throws {
        let tabs = WorkspaceTabs()
        let local = connection("local"), production = connection("production")
        let localPods = tabs.open(pods, connection: local)
        tabs.setNamespaces(["tools"]); tabs.setSearch("api")
        tabs.open(services, connection: local)
        #expect(tabs.selected?.namespaces == ["development"])
        tabs.setSearch("gateway")
        let remotePods = tabs.open(pods, connection: production)
        #expect(remotePods.id != localPods.id)
        #expect(tabs.selected?.search == "")
        tabs.open(pods, connection: local)
        #expect(tabs.items.count == 3)
        #expect(tabs.selected?.namespaces == ["tools"])
        #expect(tabs.selected?.search == "api")
    }

    @Test("Closing a background tab leaves the active scope alone; closing the active tab chooses its neighbor")
    func closing() throws {
        let tabs = WorkspaceTabs(), local = connection("local"), remote = connection("remote")
        let first = tabs.open(pods, connection: local)
        let second = tabs.open(services, connection: local)
        let third = tabs.open(pods, connection: remote)
        #expect(tabs.nextSelection(afterClosing: first.id)?.id == third.id)
        tabs.close(first.id)
        #expect(tabs.selection == third.id)
        #expect(tabs.nextSelection(afterClosing: third.id)?.connectionID == local.id)
        tabs.close(third.id)
        #expect(tabs.selection == second.id)
        tabs.close(second.id)
        #expect(tabs.selection == nil)
        #expect(tabs.selected == nil)
    }

    @Test("A tab keeps several namespaces, and never ends up with none")
    func holdsSeveralNamespaces() throws {
        let tabs = WorkspaceTabs()
        tabs.open(pods, connection: connection("local"))

        tabs.setNamespaces(["tools", "payments", "default"])
        #expect(tabs.selected?.namespaces == ["tools", "payments", "default"])

        // An empty scope would leave the table listing nothing with no way back.
        tabs.setNamespaces([])
        #expect(tabs.selected?.namespaces == ["tools", "payments", "default"])
    }
}
