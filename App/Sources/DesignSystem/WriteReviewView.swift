import SwiftUI
import KubeKit

struct ClusterScopeBar: View {
    let cluster: String
    let target: WriteTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(cluster, systemImage: "point.3.connected.trianglepath.dotted")
            Text("\(target.namespace ?? "Cluster scope") · \(target.resource.kind) · \(target.name)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cluster \(cluster), namespace \(target.namespace ?? "cluster scope"), \(target.resource.kind), \(target.name)")
    }
}

struct WriteReviewView: View {
    let rehearsal: WriteRehearsal
    let diff: [DiffLine]
    @State private var showResult = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Server dry-run succeeded", systemImage: "checkmark.circle")
                .font(.headline)
            ForEach(Array(rehearsal.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
            Toggle("Show server result", isOn: $showResult)
            if showResult {
                Text((try? ManifestParser().yaml(from: rehearsal.proposed)) ?? "Unable to render the server result.")
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            } else {
                ForEach(Array(diff.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(marker(line.change)).accessibilityHidden(true)
                        Text(line.text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .background(diffBackground(line.change))
                    .accessibilityLabel("\(description(line.change)): \(line.text)")
                }
                .textSelection(.enabled)
            }
        }
    }

    private func marker(_ change: DiffLine.Change) -> String {
        switch change { case .added: "+"; case .removed: "−"; case .unchanged: " " }
    }
    private func description(_ change: DiffLine.Change) -> String {
        switch change { case .added: "Added"; case .removed: "Removed"; case .unchanged: "Unchanged" }
    }

    /// Text always uses the system's full-contrast foreground. Tint reinforces
    /// the explicit +/− markers without carrying information by color alone.
    private func diffBackground(_ change: DiffLine.Change) -> Color {
        switch change {
        case .added: .green.opacity(0.12)
        case .removed: .red.opacity(0.12)
        case .unchanged: .clear
        }
    }
}
