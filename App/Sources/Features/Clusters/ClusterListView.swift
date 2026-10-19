import SwiftUI
import KubeModels

/// The cluster sidebar: saved clusters, plus the entry point for importing one.
struct ClusterListView: View {
    @State var model: ClusterListModel

    var body: some View {
        List {
            if model.connections.isEmpty {
                Section("Clusters") {
                    Text("No clusters yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Clusters") {
                    ForEach(model.connections) { connection in
                        ClusterRow(connection: connection)
                    }
                }
            }

            if !model.discoveredConfigurations.isEmpty {
                Section("Found on this Mac") {
                    ForEach(model.discoveredConfigurations, id: \.self) { url in
                        Button(url.path) {
                            model.importKubeconfig(contentsOf: url)
                        }
                    }
                }
            }
        }
        .navigationTitle("Tsubame")
        .overlay {
            if case .failed(let message) = model.importState {
                ContentUnavailableView(
                    "Could not read that kubeconfig",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
    }
}

private struct ClusterRow: View {
    let connection: ClusterConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(connection.displayName)
            Text("\(connection.contextName) · \(connection.defaultNamespace)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        ClusterListView(model: ClusterListModel(environment: .inMemory()))
    }
}
