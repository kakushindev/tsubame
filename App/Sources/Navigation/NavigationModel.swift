import Foundation
import Observation
import KubeModels

/// Which cluster and namespace the browsing columns are showing.
///
/// PRD §13 requires the active cluster and namespace to be identifiable at all
/// times, so selection is explicit state rather than something each view derives.
struct ClusterSelection: Hashable, Sendable {
    let connectionID: ClusterConnection.ID
    let clusterName: String
    var namespace: String
}

/// Owns navigation state for one window.
///
/// Keeping it out of the feature models means a context switch can cancel in-flight
/// work in one place instead of each screen guessing.
@MainActor
@Observable
final class NavigationModel {
    var clusterSelection: ClusterSelection?

    init(clusterSelection: ClusterSelection? = nil) {
        self.clusterSelection = clusterSelection
    }

    func select(_ connection: ClusterConnection) {
        clusterSelection = ClusterSelection(
            connectionID: connection.id,
            clusterName: connection.displayName,
            namespace: connection.defaultNamespace
        )
    }
}
