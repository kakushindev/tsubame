import Foundation
import Observation
import KubeModels

struct ResourceWorkspaceTab: Hashable, Identifiable {
    let id: String
    let connectionID: UUID
    let contextName: String
    let resource: DiscoveredResource
    var namespaces: [String]
    var search = ""
}

/// Tabs retain navigation choices, not inactive watches or resource payloads.
@MainActor @Observable
final class WorkspaceTabs {
    private(set) var items: [ResourceWorkspaceTab] = []
    private(set) var selection: String?
    var selected: ResourceWorkspaceTab? { items.first { $0.id == selection } }

    @discardableResult
    func open(_ resource: DiscoveredResource, connection: ClusterConnection) -> ResourceWorkspaceTab {
        let id = "\(connection.id)/\(resource.groupVersion.apiVersion)/\(resource.resourceName)"
        if let existing = items.first(where: { $0.id == id }) { selection = id; return existing }
        let tab = ResourceWorkspaceTab(id: id, connectionID: connection.id, contextName: connection.contextName,
                                       resource: resource, namespaces: [connection.defaultNamespace])
        items.append(tab)
        selection = id
        return tab
    }

    func select(_ id: String) { if items.contains(where: { $0.id == id }) { selection = id } }

    func nextSelection(afterClosing id: String) -> ResourceWorkspaceTab? {
        guard selection == id, let index = items.firstIndex(where: { $0.id == id }) else { return selected }
        let remaining = items.filter { $0.id != id }
        return remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
    }

    func close(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        if selection == id { selection = items.isEmpty ? nil : items[min(index, items.count - 1)].id }
    }

    func setNamespaces(_ values: [String]) {
        guard let index = items.firstIndex(where: { $0.id == selection }), !values.isEmpty else { return }
        items[index].namespaces = values
    }

    func setSearch(_ value: String) {
        guard let index = items.firstIndex(where: { $0.id == selection }) else { return }
        items[index].search = value
    }
}
