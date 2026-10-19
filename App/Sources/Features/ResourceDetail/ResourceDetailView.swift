import SwiftUI
import KubeKit
import KubeModels

struct ResourceDetailView: View {
    enum Action { case edit, logs, delete, restart, scale }
    @State var model: ResourceDetailModel
    let cluster: String
    let perform: (Action, GenericResource) -> Void
    var close: (() -> Void)? = nil
    @State private var pane = Pane.overview
    @State private var refreshID = UUID()
    private enum Pane: String, CaseIterable { case overview = "Overview", yaml = "YAML" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if pane == .yaml {
                ScrollView([.horizontal, .vertical]) {
                    Text(model.yaml).font(.system(.body, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled).padding(16)
                }.defaultScrollAnchor(.topLeading)
            } else {
                overview
            }
        }
        .task(id: refreshID) { await model.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.target.resource.kind).font(.caption).foregroundStyle(.secondary)
                    Text(model.target.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Button { refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh resource").accessibilityLabel("Refresh resource")
                if let close {
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Close details").accessibilityLabel("Close details")
                }
            }
            Text("\(cluster) · \(model.target.namespace ?? "Cluster scope")")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let object = model.object {
                HStack {
                    Button("Edit YAML", systemImage: "square.and.pencil") { perform(.edit, object) }
                        .disabled(!model.target.resource.supports("patch"))
                        .keyboardShortcut("e", modifiers: .command)
                    if model.target.resource.kind == "Pod", model.target.resource.subresources.contains("log") {
                        Button("Logs", systemImage: "text.alignleft") { perform(.logs, object) }
                            .keyboardShortcut("l", modifiers: .command)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        if model.target.resource.groupVersion.group == "apps",
                           ["Deployment", "StatefulSet", "DaemonSet"].contains(model.target.resource.kind) {
                            Button("Restart…") { perform(.restart, object) }.disabled(!model.target.resource.supports("patch"))
                        }
                        if model.target.resource.subresources.contains("scale") { Button("Scale…") { perform(.scale, object) } }
                        Button("Delete…", role: .destructive) { perform(.delete, object) }
                            .disabled(!model.target.resource.isDeletable)
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.automatic).fixedSize().help("Resource actions").accessibilityLabel("Resource actions")
                }
            }
            Picker("Detail view", selection: $pane) {
                ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
        }.padding(16)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let failure = model.failure {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                }
                if let object = model.object {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Metadata").font(.headline)
                        LabeledContent("Namespace", value: object.namespace ?? "Cluster scope")
                        if let created = object.metadata.creationTimestamp {
                            LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened))
                        }
                        LabeledContent("Version", value: object.resourceVersion ?? "Unavailable")
                    }
                    keyValues("Labels", values: object.metadata.labels)
                    keyValues("Annotations", values: object.metadata.annotations)
                    if !object.metadata.ownerReferences.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Owned by").font(.headline)
                            ForEach(object.metadata.ownerReferences, id: \.uid) { owner in
                                Text("\(owner.kind) · \(owner.name)").textSelection(.enabled)
                            }
                        }
                    }
                    if let secret = model.secret {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Secret values").font(.headline)
                            Text("Text is decoded. Binary data remains base64.").font(.caption).foregroundStyle(.secondary)
                            ForEach(secret.values.keys.sorted(), id: \.self) { key in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(key).font(.subheadline.weight(.semibold))
                                    switch secret.values[key] {
                                    case .text(let text): Text(text).textSelection(.enabled)
                                    case .binary(let base64, let count):
                                        Text("Binary · \(count) bytes").font(.caption)
                                        Text(base64).textSelection(.enabled)
                                    case nil: EmptyView()
                                    }
                                }
                            }
                        }
                    }
                    if let loadedAt = model.loadedAt {
                        Text("Snapshot loaded \(loadedAt.formatted(date: .omitted, time: .standard)). Refresh to check for changes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.failure == nil { ProgressView("Loading resource…") }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    @ViewBuilder private func keyValues(_ title: String, values: [String: String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                ForEach(values.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(key).font(.caption).foregroundStyle(.secondary)
                        Text(values[key] ?? "").font(.callout).textSelection(.enabled)
                    }
                }
            }
        }
    }
}
