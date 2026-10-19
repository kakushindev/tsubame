import SwiftUI
import KubeKit
import KubeModels

struct ResourceListView: View {
    @State var model: ResourceListModel
    let cluster: String
    let resource: DiscoveredResource
    let namespaces: [String]
    @Binding var selection: String?
    let didSelect: (ResourceListModel.Row?) -> Void
    var changeNamespaces: ([String]) -> String? = { _ in nil }
    var loadNamespaces: (@Sendable () async -> NamespaceControl.Options)?
    var searchChanged: (String) -> Void = { _ in }
    @State private var sortOrder = [KeyPathComparator(\ResourceListModel.Row.name)]
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: [String] { ResourceKindRegistry.mvp.binding(for: resource.groupVersionKind).columns }
    private var rows: [ResourceListModel.Row] { model.filteredRows.sorted(using: sortOrder) }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    scopeControl
                    searchControl
                    itemCount
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { scopeControl; Spacer(); itemCount }
                    searchControl
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if let snapshot = model.snapshot {
                if let failure = snapshot.failure {
                    Label(failure.localizedDescription, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                if snapshot.isPartial {
                    Label("Some resources could not be read. This list is partial.", systemImage: "exclamationmark.triangle")
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }
            resourceBrowser
                .workspaceTableAppearance()
                .overlay { emptyState }
            Divider()
            HStack(spacing: 16) {
                Text("\(cluster) · \(resource.isNamespaced ? NamespaceControl.scopeLabel(namespaces) : "Cluster scope")")
                Spacer()
                if let snapshot = model.snapshot { FreshnessIndicator(freshness: snapshot.freshness) }
                else { Text("Connecting…") }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(.bar)
        }
        .navigationTitle(ResourceKindPresentation.name(resource))
        .task { await model.run() }
        .onChange(of: model.search) { _, value in searchChanged(value) }
        .onChange(of: selection) { _, id in didSelect(model.rows.first { $0.id == id }) }
    }

    @ViewBuilder private var scopeControl: some View {
        if resource.isNamespaced {
            NamespaceControl(selected: namespaces, change: changeNamespaces, load: loadNamespaces)
        } else { Label("Cluster scope", systemImage: "globe").font(.callout).foregroundStyle(.secondary) }
    }

    private var itemCount: some View {
        Text("\(rows.count) items").font(.callout).foregroundStyle(.secondary).fixedSize()
    }

    private var searchControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search \(ResourceKindPresentation.name(resource).lowercased())", text: $model.search)
                .textFieldStyle(.plain).accessibilityLabel("Search resources by name")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.background, in: RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(.quaternary) }
        .frame(minWidth: 160, idealWidth: 280, maxWidth: 360)
    }

    @ViewBuilder private var resourceBrowser: some View {
        if sizeClass != .compact && !typeSize.isAccessibilitySize {
            if #available(macOS 14.4, iOS 17.4, *) { detailedTable }
            else { compatibleTable }
        } else {
            List(rows) { row in
                Button { selection = row.id; didSelect(row) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(row.name).font(.headline).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        status(row.summary)
                        if !row.summary.fields.isEmpty {
                            Text(row.summary.fields.prefix(3).map { "\($0.label) \($0.value)" }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }.listStyle(.plain)
        }
    }

    @available(macOS 14.4, iOS 17.4, *)
    private var detailedTable: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { row in
                    Text(row.name).fontWeight(.medium).help(row.name)
                }.width(min: 180, ideal: 280)
                TableColumn("Status") { row in status(row.summary) }.width(min: 180, ideal: 200)
                if columns.count > 0 {
                    TableColumn(columns[0]) { row in
                        Text(field(row, at: 0))
                    }.width(min: 70, ideal: columns[0] == "Message" ? 260 : 110)
                }
                if columns.count > 1 {
                    TableColumn(columns[1]) { row in
                        Text(field(row, at: 1))
                    }.width(min: 70, ideal: columns[1] == "Message" ? 260 : 110)
                }
                if columns.count > 2 {
                    TableColumn(columns[2]) { row in
                        Text(field(row, at: 2))
                    }.width(min: 70, ideal: columns[2] == "Message" ? 260 : 110)
                }
                if columns.count > 3 {
                    TableColumn(columns[3]) { row in
                        Text(field(row, at: 3))
                    }.width(min: 70, ideal: columns[3] == "Message" ? 260 : 110)
                }
                TableColumn("Age") { row in
                    if let date = row.createdAt { Text(date, format: .relative(presentation: .numeric)) }
                    else { Text("—") }
                }.width(min: 70, ideal: 100)
            }
    }

    // The original deployment floors precede optional/dynamic table columns.
    // Keep the same information in one summary column on those releases.
    private var compatibleTable: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name).width(min: 180, ideal: 280)
            TableColumn("Status") { row in status(row.summary) }.width(min: 180, ideal: 200)
            TableColumn("Details") { row in
                Text(row.summary.fields.map { "\($0.label) \($0.value)" }.joined(separator: " · "))
            }.width(min: 180, ideal: 300)
            TableColumn("Age") { row in
                if let date = row.createdAt { Text(date, format: .relative(presentation: .numeric)) }
                else { Text("—") }
            }.width(min: 70, ideal: 100)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.snapshot == nil { ProgressView("Loading \(ResourceKindPresentation.name(resource).lowercased())…") }
        else if rows.isEmpty, model.snapshot?.failure == nil {
            ContentUnavailableView {
                Label(model.search.isEmpty ? "No \(ResourceKindPresentation.name(resource).lowercased())" : "No matching resources",
                      systemImage: model.search.isEmpty ? ResourceKindPresentation.symbol(resource) : "magnifyingglass")
            } description: {
                Text(model.search.isEmpty ? "\(cluster) · \(NamespaceControl.scopeLabel(namespaces))" : "Try a different name or clear your search.")
            }
            .allowsHitTesting(false)
        }
    }

    private func field(_ row: ResourceListModel.Row, at index: Int) -> String {
        row.summary.fields.first { $0.label == columns[index] }?.value ?? "—"
    }

    private func status(_ summary: ResourceRowSummary) -> some View {
        ResourceStatusBadge(summary: summary)
    }
}
