import SwiftUI

struct LogsView: View {
    @State var model: LogsModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(model.cluster) · \(model.namespace) · Pod · \(model.podName)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    ViewThatFits(in: .horizontal) {
                        HStack { controls }
                        VStack(alignment: .leading) { controls }
                    }
                    if !model.isStarted {
                        Label(model.snapshot?.state == .ended ? "Log stream ended" : "Stopped — output is not live", systemImage: "pause.circle")
                            .font(.caption)
                    } else if let snapshot = model.snapshot {
                        FreshnessIndicator(freshness: snapshot.freshness)
                    } else { ProgressView("Connecting…") }
                    if let failure = model.snapshot?.failure {
                        Label(failure.localizedDescription, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }.padding()
                Divider()
                ScrollViewReader { reader in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if let count = model.snapshot?.droppedLineCount, count > 0 {
                                Label("\(count) earlier lines discarded to keep memory bounded", systemImage: "arrow.up.doc")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(model.snapshot?.lines ?? []) { line in
                                Text(model.showTimestamps ? "\(line.timestamp ?? "") \(line.text)" : line.text)
                                    .font(.system(.body, design: .monospaced))
                                    .fixedSize(horizontal: true, vertical: false)
                                    .textSelection(.enabled)
                                    .id(line.id)
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.topLeading)
                    .onChange(of: model.snapshot?.lines.last?.id) { _, id in
                        if model.followOutput, let id { reader.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            .navigationTitle("Pod Logs")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { model.stop(); dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(model.isStarted ? "Stop" : "Start", systemImage: model.isStarted ? "stop.fill" : "play.fill") {
                        if model.isStarted { model.stop() } else { model.start() }
                    }.disabled(model.containers.isEmpty)
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.container) { _, _ in model.selectionChanged() }
        .onChange(of: model.previous) { _, _ in model.selectionChanged() }
        .onChange(of: scenePhase) { _, phase in
            model.setForeground(phase == .active)
        }
    }

    @ViewBuilder private var controls: some View {
        Picker("Container", selection: $model.container) {
            ForEach(model.containers) { Text($0.name).tag($0.name) }
        }
        Toggle("Previous", isOn: $model.previous).disabled(!model.canReadPrevious)
        Toggle("Timestamps", isOn: $model.showTimestamps)
        Toggle("Follow output", isOn: $model.followOutput)
        Picker("Starting window", selection: $model.tailLines) {
            Text("100 lines").tag(100)
            Text("500 lines").tag(500)
            Text("1,000 lines").tag(1_000)
        }
        .onChange(of: model.tailLines) { _, _ in model.start() }
    }
}
