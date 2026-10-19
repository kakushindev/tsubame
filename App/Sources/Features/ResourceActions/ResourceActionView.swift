import SwiftUI

struct ResourceActionView: View {
    @State var model: ResourceActionModel
    @State private var operation: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var cancelFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ClusterScopeBar(cluster: model.cluster, target: model.target)
                    if model.action == .scale {
                        Text("Current replicas: \(model.original.raw["spec", "replicas"]?.integerValue ?? 1)")
                        Stepper("Proposed replicas: \(model.replicas)", value: $model.replicas, in: 0...100_000)
                            .disabled(model.isBusy)
                    }
                    if model.action == .delete {
                        Text("Deletion may remove dependent resources. A dry-run does not predict the cascade.")
                    }
                    if model.action == .restart { Text("Updates the pod-template restart annotation and triggers a rollout.") }
                    if let rehearsal = model.rehearsal {
                        WriteReviewView(rehearsal: rehearsal, diff: model.diff)
                    }
                    if let failure = model.failure {
                        Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                    }
                    if model.succeeded { Label("\(model.action.rawValue) succeeded", systemImage: "checkmark.circle") }
                    if model.isBusy { ProgressView("Waiting for the cluster…") }
                }.padding()
            }
            .navigationTitle("\(model.action.rawValue) \(model.target.name)")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.succeeded ? "Done" : "Cancel") { dismiss() }
                        .focused($cancelFocused).disabled(model.isBusy)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !model.succeeded {
                        Button("Dry-run") { operation = Task { await model.dryRun() } }.disabled(model.isBusy)
                        Button("Confirm \(model.action.rawValue)", role: model.action == .delete ? .destructive : nil) {
                            operation = Task { await model.confirm() }
                        }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(model.rehearsal == nil || model.isBusy)
                    }
                }
            }
            .interactiveDismissDisabled(model.isBusy)
        }
        .onAppear { cancelFocused = true }
        .onDisappear { operation?.cancel() }
    }
}
