import SwiftUI
import UniformTypeIdentifiers
import KubeKit
import KubeModels

/// Connections are a destination in the window, not a modal onboarding sequence.
struct ClusterConnectionsView: View {
    @Bindable var model: ClusterListModel
    let connect: () -> Void
    var back: (() -> Void)? = nil
    @State private var pastedText = ""
    @State private var showingPaste = false
    @State private var choosingFile = false
    @State private var sortOrder = [KeyPathComparator(\ClusterListModel.AvailableContext.name)]
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            header
            if showingPaste { pasteEditor }
            Divider()
            contextBrowser.workspaceTableAppearance().disabled(model.isSaving)
            Divider()
            connectionBar
        }
        .navigationTitle("Clusters")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if let back {
                ToolbarItem(placement: .navigation) {
                    Button("Back to Workspace", systemImage: "chevron.left", action: back)
                }
            }
        }
        .task { model.loadDiscoveredConfigurations() }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                model.importKubeconfig(contentsOf: url)
            case .failure(let error): model.reportImportFailure(error)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your clusters").font(.title.weight(.semibold))
                    Text("Choose a cluster to connect.").foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if model.isSaving { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 12) {
                Button("Import File…", systemImage: "square.and.arrow.down") { choosingFile = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Paste…", systemImage: "doc.on.clipboard") { showingPaste.toggle() }
                    .accessibilityLabel("Paste kubeconfig configuration")
                Spacer()
                Button { model.loadDiscoveredConfigurations(refresh: true) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh discovered clusters")
                .accessibilityLabel("Refresh discovered clusters")
            }
            .disabled(model.isSaving)
        }
        .padding(24)
    }

    private var pasteEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste kubeconfig").font(.headline)
            TextEditor(text: $pastedText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 150)
                .accessibilityLabel("Kubeconfig text")
                .overlay { Rectangle().stroke(.quaternary) }
            HStack {
                Text("Credentials are saved only when you connect.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Load Clusters") {
                    model.importKubeconfig(text: pastedText)
                    if case .choosingContext = model.importState { showingPaste = false }
                }
                .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 20)
    }

    @ViewBuilder private var contextBrowser: some View {
        if model.availableContexts.isEmpty {
            ContentUnavailableView {
                Label("No clusters found", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("Import a kubeconfig file or paste one to see its clusters here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sizeClass != .compact && !typeSize.isAccessibilitySize {
            Table(model.availableContexts.sorted(using: sortOrder), selection: $model.selection, sortOrder: $sortOrder) {
                TableColumn("Cluster", value: \.name) { context in
                    Label(context.name, systemImage: context.summary.isCurrent ? "circle.inset.filled" : "circle")
                        .help(context.summary.isCurrent ? "Current cluster connection in this file" : context.name)
                }.width(min: 150, ideal: 220)
                TableColumn("Cluster entry", value: \.cluster).width(min: 110, ideal: 180)
                TableColumn("Server", value: \.server).width(min: 150, ideal: 240)
                TableColumn("Namespace", value: \.namespace).width(min: 100, ideal: 130)
                TableColumn("Source", value: \.sourceLabel).width(min: 120, ideal: 170)
            }
        } else {
            List {
                ForEach(model.availableContexts) { context in
                    Button { model.selection = context.id } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(context.name).font(.headline).foregroundStyle(.primary)
                                Text(context.server).font(.subheadline).foregroundStyle(.secondary)
                                Text("\(context.namespace) · \(context.sourceLabel)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if context.id == model.selection { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                        }
                        .padding(.vertical, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(context.id == model.selection ? .isSelected : [])
                }
            }.listStyle(.plain)
        }
    }

    private var connectionBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .failed(let reason) = model.importState {
                Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
            }
            ForEach(model.sourceFailures, id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
            }
            if let plan = model.importPlan {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plan.contextName).font(.headline)
                        Text("\(plan.credentialUser) · \(plan.namespace)").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(model.isSaving ? "Connecting…" : "Connect", action: connect)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canConnect)
                }
                ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning.message, systemImage: "exclamationmark.triangle").font(.callout)
                }
                switch plan.support {
                case .supported: EmptyView()
                case .requiresApproval:
                    Text("This cluster uses an exec credential plugin. Plugin approval is not available in this build; no command will run.").font(.callout)
                case .needsSetup(let reason): Text(reason).font(.callout)
                case .unsupported(_, _, let reason): Text(reason).font(.callout)
                }
            } else {
                Text("Select a cluster to see its connection details.").foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
