import SwiftUI

struct YAMLEditorView: View {
    @State var model: YAMLEditorModel
    @State private var pane = Pane.source
    @State private var showClose = false
    @State private var operation: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    private enum Pane: String, CaseIterable { case source = "YAML", review = "Review" }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                ClusterScopeBar(cluster: model.cluster, target: model.target).padding()
                Picker("Editor pane", selection: $pane) {
                    ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).padding(.horizontal).padding(.bottom)
                Divider()
                if pane == .source {
                    YAMLSourceEditor(text: $model.text).disabled(model.isBusy)
                } else {
                    ScrollView {
                        if let rehearsal = model.rehearsal {
                            WriteReviewView(rehearsal: rehearsal, diff: model.diff).padding()
                        } else {
                            ContentUnavailableView("Run dry-run to review", systemImage: "checkmark.shield",
                                                   description: Text("The server result and diff appear here before Apply becomes available."))
                        }
                    }
                }
                Divider()
                status.padding(.horizontal).padding(.vertical, 8)
            }
            .navigationTitle("Edit \(model.target.name)")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { if model.hasChanges { showClose = true } else { dismiss() } }
                        .disabled(model.isBusy)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Dry-run") {
                        operation = Task { await model.dryRun(); pane = .review }
                    }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.isBusy)
                    Button("Apply") { operation = Task { await model.apply() } }
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                        .disabled(!canApply)
                }
            }
            .interactiveDismissDisabled(model.hasChanges || model.isBusy)
            .confirmationDialog("Keep this draft?", isPresented: $showClose, titleVisibility: .visible) {
                Button("Keep Draft") { dismiss() }
                Button("Discard Draft", role: .destructive) { model.discard(); dismiss() }
                Button("Continue Editing", role: .cancel) {}
            } message: {
                Text("Drafts stay in memory for this window. Switch clusters after applying or discarding them.")
            }
        }
        .onDisappear { operation?.cancel() }
    }

    private var canApply: Bool { if case .reviewed = model.state { return true }; return false }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .editing: Text("Edit YAML, then run a server-side dry-run.").foregroundStyle(.secondary)
        case .dryRunning: ProgressView("Running server dry-run…")
        case .reviewed: Label("Review the diff and destination, then choose Apply.", systemImage: "checkmark.shield")
        case .applying: ProgressView("Applying reviewed manifest…")
        case .applied: Label("Applied successfully", systemImage: "checkmark.circle")
        case .rejected(let reason), .conflict(let reason):
            Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
        }
    }
}
