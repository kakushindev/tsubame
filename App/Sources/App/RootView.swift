import SwiftUI

/// The three-column shell shared by every platform.
///
/// SwiftUI collapses it to a stack on iPhone and to a split view on iPad and Mac,
/// which is how PRD §10's "one codebase, device-adapted screens" is met without a
/// per-platform view hierarchy.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var navigation = NavigationModel()

    var body: some View {
        NavigationSplitView {
            ClusterListView(model: ClusterListModel(environment: environment))
        } content: {
            ResourceSectionPlaceholder(selection: navigation.clusterSelection)
        } detail: {
            DetailPlaceholder()
        }
    }
}

/// Stands in for the resource browser until it lands, and says so rather than
/// showing an empty list that reads as "this cluster has nothing in it".
private struct ResourceSectionPlaceholder: View {
    let selection: ClusterSelection?

    var body: some View {
        if let selection {
            ContentUnavailableView(
                "Resource browsing is not built yet",
                systemImage: "square.stack.3d.up",
                description: Text("\(selection.clusterName) · \(selection.namespace)")
            )
        } else {
            ContentUnavailableView(
                "No cluster selected",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Add a cluster to begin.")
            )
        }
    }
}

private struct DetailPlaceholder: View {
    var body: some View {
        ContentUnavailableView(
            "Nothing selected",
            systemImage: "doc.text",
            description: Text("Resource details appear here.")
        )
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment.inMemory())
}
