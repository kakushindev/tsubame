import SwiftUI
import KubeKit
import KubeModels

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        #if DEBUG
        if let mode = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--preview-") }) {
            WorkflowPreview(mode: mode)
        } else { workspace }
        #else
        workspace
        #endif
    }

    private var workspace: some View {
        WorkspaceView(clusters: ClusterListModel(environment: environment), environment: environment)
    }
}

/// Cross-feature navigation and presentations stay in the composition root.
struct WorkspaceView: View {
    @State var clusters: ClusterListModel
    let environment: AppEnvironment
    #if DEBUG
    var previewAutoConnect = false
    var isInterfacePreview = false
    #endif
    @State private var session: ClusterSession?
    @State private var sessions: [UUID: ClusterSession] = [:]
    @State private var tabs = WorkspaceTabs()
    @State private var kind: DiscoveredResource?
    @State private var rowID: String?
    @State private var objectTarget: WriteTarget?
    @State private var drafts = EditorDraftStore()
    @State private var showingConnections = false
    @State private var inspecting = false
    @State private var expandedContexts: Set<UUID> = []
    @State private var expandedGroups: Set<String> = []
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var compactColumn = NavigationSplitViewColumn.detail
    @State private var showDraftGuard = false
    @State private var pending: PendingSelection?
    @State private var destination: Destination?
    @State private var pane = WorkspacePaneModel()
    /// Which surface ⌘W acts on. Set where the user's attention moves, rather
    /// than inferred, so the shortcut never closes something they were not
    /// looking at.
    @State private var paneHasFocus = false
    @State private var detailGeneration = UUID()
    @ScaledMetric(relativeTo: .body) private var tabLineHeight = 22.0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    private enum PendingSelection {
        case context(String), tab(String), resource(UUID, DiscoveredResource), close(String)
    }
    /// Only confirmations present modally now. A delete or a scale is exactly the
    /// case a modal is for: it wants protected focus and a deliberate answer.
    /// Editing YAML and reading logs moved to the bottom pane, because both are
    /// things the user keeps open while looking something else up.
    private struct Destination: Identifiable {
        enum Tool {
            case editor(YAMLEditorModel), logs(LogsModel), action(ResourceActionModel)
        }
        let id = UUID()
        let tool: Tool
    }

    /// The pane needs the window's height to keep itself from swallowing the table;
    /// on iPhone there is no height to share, so tools stay full-screen there.
    private var usesBottomPane: Bool { sizeClass == .regular }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            navigator.navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
        } detail: {
            VStack(spacing: 0) {
                #if DEBUG
                if isInterfacePreview {
                    Text("Preview · synthetic data · no cluster connection")
                        .font(.caption).foregroundStyle(.secondary).padding(6)
                        .frame(maxWidth: .infinity).background(.bar)
                }
                #endif
                if !tabs.items.isEmpty { tabStrip }
                if showingConnections {
                    ClusterConnectionsView(model: clusters, connect: requestConnect,
                                           back: session == nil ? nil : { showingConnections = false })
                } else if session == nil {
                    welcome
                } else if let session {
                    GeometryReader { proxy in
                        VStack(spacing: 0) {
                            resourceContent(session)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if usesBottomPane, !pane.isEmpty {
                                WorkspaceBottomPane(model: pane, availableHeight: proxy.size.height,
                                                    focused: { paneHasFocus = true }) { tool in
                                    switch tool.content {
                                    case .editor(let model): YAMLEditorView(model: model)
                                    case .logs(let model): LogsView(model: model)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .toolbar {
                if usesTouchNavigation && sizeClass == .regular {
                    ToolbarItem(placement: .navigation) {
                        Button(columnVisibility == .all ? "Hide Navigator" : "Show Navigator", systemImage: "sidebar.left") {
                            if columnVisibility == .all { columnVisibility = .detailOnly }
                            else { columnVisibility = .all; compactColumn = .sidebar }
                        }.labelStyle(.titleAndIcon)
                    }
                }
                if !showingConnections && session != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button { inspecting.toggle() } label: { Image(systemName: "sidebar.right") }
                            .disabled(objectTarget == nil).help("Toggle resource details")
                            .accessibilityLabel("Toggle resource details")
                            .keyboardShortcut("i", modifiers: [.command, .option])
                    }
                }
            }
            .inspector(isPresented: $inspecting) {
                if let session, let target = objectTarget {
                    ResourceDetailView(model: ResourceDetailModel(client: session.client, target: target), cluster: session.connection.displayName,
                                       perform: { present($0, object: $1, target: target, session: session) }, close: { inspecting = false })
                        .id("\(session.id)/\(target)/\(detailGeneration)")
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
                }
            }
        }
        .workspaceMinimumSize()
        .focusedSceneValue(\.workspaceCommands, workspaceCommands)
        .task {
            clusters.loadDiscoveredConfigurations()
            #if DEBUG
            if previewAutoConnect { await connectSelected() }
            #endif
        }
        .task(id: session?.id) {
            guard let session else { return }
            if session.catalog == nil { await session.discover() }
            guard !Task.isCancelled, kind == nil, tabs.items.allSatisfy({ $0.connectionID != session.connection.id }) else { return }
            if let resource = session.resources.first(where: { $0.kind == "Pod" && $0.groupVersion.group.isEmpty }) ?? session.resources.first {
                openResource(resource, in: session)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { clusters.loadDiscoveredConfigurations(refresh: true) }
        }
        .fullScreenDestination(item: $destination, onDismiss: { detailGeneration = UUID() }) { destination in
            switch destination.tool {
            case .editor(let model): YAMLEditorView(model: model)
            case .logs(let model): LogsView(model: model)
            case .action(let model): ResourceActionView(model: model)
            }
        }
        .alert("Unsaved YAML drafts", isPresented: $showDraftGuard) {
            Button("Keep Editing", role: .cancel) { pending = nil }
            Button("Discard Drafts and Switch", role: .destructive) {
                drafts.discardAll()
                // Close the editors that held them too, or the pane keeps showing
                // text the store no longer has.
                for tool in pane.tools where tool.kind == .editor { pane.close(tool.id) }
                if let pending { perform(pending) }
                pending = nil
            }
        } message: {
            Text("Apply or discard this window’s drafts before switching clusters.")
        }
    }

    private var navigator: some View {
        Group {
            if usesTouchNavigation {
                List { Section("Contexts") { navigatorEntries } }.listStyle(.sidebar)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Text("Contexts").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 8)
                        navigatorEntries
                    }.padding(.horizontal, 8).padding(.bottom, 8)
                }
                .background(.bar)
            }
        }
        .navigationTitle("Navigator")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    showingConnections = true
                    inspecting = false
                    revealContent()
                } label: {
                    Label("Manage Contexts…", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.background(.bar)
        }
    }

    @ViewBuilder private var navigatorEntries: some View {
        ForEach(clusters.availableContexts) { context in
            if let connection = clusters.connection(forContextID: context.id), let cached = sessions[connection.id] {
                contextTree(cached)
            } else {
                Button {
                    clusters.selection = context.id
                    inspecting = false
                    showingConnections = false
                    requestConnect()
                } label: {
                    Label(context.name, systemImage: "server.rack")
                        .padding(.leading, usesTouchNavigation ? 0 : 26)
                        .frame(maxWidth: .infinity, minHeight: usesTouchNavigation ? nil : 24, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Connect to \(context.name)")
                .contextMenu {
                    // Reviewing a context's identity and warnings before connecting
                    // is still available, just no longer in the way of connecting.
                    Button("Review in Manage Contexts…") {
                        clusters.selection = context.id
                        showingConnections = true
                        inspecting = false
                        revealContent()
                    }
                }
            }
        }
        // An edited import can replace its staging entry without changing an already-open target.
        ForEach(clusters.connections.filter { connection in
            !clusters.availableContexts.contains { clusters.connection(forContextID: $0.id)?.id == connection.id }
        }) { connection in
            if let cached = sessions[connection.id] { contextTree(cached) }
        }
        if clusters.availableContexts.isEmpty && clusters.connections.isEmpty {
            Text("Import a kubeconfig to see your contexts here.").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func contextTree(_ cached: ClusterSession) -> some View {
        if usesTouchNavigation { touchContextTree(cached) }
        else { compactContextTree(cached) }
    }

    @ViewBuilder private func compactContextTree(_ cached: ClusterSession) -> some View {
        let expanded = expansion(cached.connection.id, in: $expandedContexts)
        navigatorDisclosure(
            cached.connection.contextName,
            expanded: expanded,
            depth: 0,
            // Reserved rather than overlaid: an overlay let a long context name run
            // underneath the retry button instead of truncating before it.
            trailingInset: cached.state == .failed ? retryWidth + 6 : 0
        ) {
            contextRowLabel(cached)
        }
        .overlay(alignment: .trailing) {
            // Still a sibling of the row, so retrying never also collapses the
            // group being looked at.
            if cached.state == .failed { retryButton(cached).padding(.trailing, 4) }
        }
        if expanded.wrappedValue {
            ForEach(ResourceKindPresentation.Category.allCases) { category in
                let resources = cached.resources.filter { ResourceKindPresentation.category($0) == category }
                if !resources.isEmpty {
                    let group = expansion("\(cached.connection.id)/\(category.rawValue)", in: $expandedGroups)
                    navigatorDisclosure(category.rawValue, expanded: group, depth: 18) { Text(category.rawValue) }
                    if group.wrappedValue {
                        ForEach(resources, id: \.self) { resource in
                            let selected = !showingConnections && session?.connection.id == cached.connection.id && kind == resource
                            Button { request(.resource(cached.connection.id, resource), target: cached.connection.id) } label: {
                                Label { Text(ResourceKindPresentation.name(resource)) } icon: {
                                    Image(systemName: ResourceKindPresentation.symbol(resource)).foregroundStyle(.tint)
                                }
                                    .padding(.leading, 44).padding(.trailing, 8)
                                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(selected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .help("\(resource.kind) · \(resource.groupVersion.apiVersion)")
                        }
                    }
                }
            }
            // Partial discovery stays visible: some kinds resolved and some did
            // not, which is a different thing from the context failing, and PRD
            // §9.2 requires it to be explicit rather than a shorter list.
            if let failures = cached.catalog?.failures, !failures.isEmpty {
                ForEach(failures.keys.sorted { $0.apiVersion < $1.apiVersion }, id: \.self) { group in
                    Text(discoveryFailure(group, failures[group])).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A context's name, its state, and nothing else.
    @ViewBuilder private func contextRowLabel(_ cached: ClusterSession) -> some View {
        Label {
            HStack(spacing: 4) {
                Text(cached.connection.contextName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                switch cached.state {
                case .failed:
                    // The shape carries the meaning, not the colour, and the
                    // message the sidebar no longer prints lives in the tooltip
                    // and the accessibility label.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .layoutPriority(2)
                        .accessibilityLabel("Not connected: \(cached.failure ?? "unknown error")")
                case .connecting:
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .layoutPriority(2)
                        .accessibilityLabel("Connecting")
                case .ready:
                    EmptyView()
                }
            }
        } icon: {
            Image(systemName: "server.rack")
                .foregroundStyle(cached.state == .ready ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .help(cached.failure ?? cached.connection.contextName)
    }

    private func retryButton(_ cached: ClusterSession) -> some View {
        Button {
            Task { await cached.retry() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .frame(width: usesTouchNavigation ? 44 : 22, height: usesTouchNavigation ? 44 : 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Try connecting to \(cached.connection.contextName) again")
        .accessibilityLabel("Retry \(cached.connection.contextName)")
    }

    private var retryWidth: CGFloat { usesTouchNavigation ? 44 : 22 }

    private func navigatorDisclosure<Content: View>(
        _ title: String, expanded: Binding<Bool>, depth: CGFloat,
        trailingInset: CGFloat = 0, @ViewBuilder label: () -> Content
    ) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12)
                label()
            }
            .padding(.leading, depth + 8).padding(.trailing, 8 + trailingInset)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
        .onKeyPress(.rightArrow) { expanded.wrappedValue = true; return .handled }
        .onKeyPress(.leftArrow) { expanded.wrappedValue = false; return .handled }
    }

    private func touchContextTree(_ cached: ClusterSession) -> some View {
        DisclosureGroup(isExpanded: expansion(cached.connection.id, in: $expandedContexts)) {
            ForEach(ResourceKindPresentation.Category.allCases) { category in
                let resources = cached.resources.filter { ResourceKindPresentation.category($0) == category }
                if !resources.isEmpty {
                    DisclosureGroup(category.rawValue, isExpanded: expansion("\(cached.connection.id)/\(category.rawValue)", in: $expandedGroups)) {
                        ForEach(resources, id: \.self) { resource in
                            let selected = !showingConnections && session?.connection.id == cached.connection.id && kind == resource
                            Button { request(.resource(cached.connection.id, resource), target: cached.connection.id) } label: {
                                Label(ResourceKindPresentation.name(resource), systemImage: ResourceKindPresentation.symbol(resource))
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(selected ? Color.accentColor.opacity(0.16) : Color.clear)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .help("\(resource.kind) · \(resource.groupVersion.apiVersion)")
                        }
                    }
                }
            }
            if let failures = cached.catalog?.failures, !failures.isEmpty {
                ForEach(failures.keys.sorted { $0.apiVersion < $1.apiVersion }, id: \.self) { group in
                    Text(discoveryFailure(group, failures[group])).font(.caption).foregroundStyle(.secondary)
                }
            }
        } label: {
            HStack(spacing: 0) {
                contextRowLabel(cached)
                if cached.state == .failed {
                    Spacer(minLength: 8)
                    retryButton(cached)
                }
            }
        }
    }

    private func expansion<Value: Hashable>(_ value: Value, in set: Binding<Set<Value>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(value) }, set: { expanded in
            if expanded { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) }
        })
    }

    private var tabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(tabs.items) { tab in
                    let selected = !showingConnections && tab.id == tabs.selection
                    HStack(spacing: 8) {
                        Button { request(.tab(tab.id), target: tab.connectionID) } label: {
                            Label("\(ResourceKindPresentation.name(tab.resource)) · \(tab.contextName)", systemImage: ResourceKindPresentation.symbol(tab.resource))
                                .lineLimit(1).padding(.leading, 12).padding(.vertical, 11)
                                .frame(minHeight: usesTouchNavigation ? 44 : 32).contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        Button {
                            let nextConnection = tabs.nextSelection(afterClosing: tab.id)?.connectionID
                            request(.close(tab.id), target: nextConnection ?? session?.connection.id)
                        } label: {
                            Image(systemName: "xmark").font(.caption)
                                .frame(width: usesTouchNavigation ? 44 : 28, height: usesTouchNavigation ? 44 : 28)
                                .contentShape(Rectangle())
                        }
                        .help("Close \(ResourceKindPresentation.name(tab.resource)) · \(tab.contextName)")
                        .accessibilityLabel("Close \(ResourceKindPresentation.name(tab.resource)) · \(tab.contextName)")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .background(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.bar))
                    .overlay(alignment: .bottom) { if selected { Rectangle().fill(.tint).frame(height: 2) } }
                    Divider()
                }
            }.fixedSize(horizontal: false, vertical: true)
        }
        .frame(height: usesTouchNavigation ? max(44, tabLineHeight + 22) : 42)
        .scrollIndicators(.hidden)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// What the window shows before anything is connected.
    ///
    /// The context table used to stand here, which made choosing a cluster feel
    /// like a form to complete before the app would start. This says what to do and
    /// leaves the sidebar to do it.
    @ViewBuilder private var welcome: some View {
        if clusters.availableContexts.isEmpty && clusters.connections.isEmpty {
            ContentUnavailableView {
                Label("No clusters yet", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("Import a kubeconfig to see your contexts.")
            } actions: {
                Button("Manage Contexts…") {
                    showingConnections = true
                    revealContent()
                }
            }
        } else {
            ContentUnavailableView {
                Label("Not connected", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("Choose a context in the sidebar to connect.")
            }
        }
    }

    @ViewBuilder private func resourceContent(_ session: ClusterSession) -> some View {
        if let kind, let tab = tabs.selected {
            if scenePhase == .active {
                ResourceListView(
                    model: ResourceListModel(client: session.client, resource: kind, namespaces: kind.isNamespaced ? session.namespaces : [], search: tab.search),
                    cluster: session.connection.contextName, resource: kind, namespaces: session.namespaces, selection: $rowID,
                    didSelect: { row in
                        objectTarget = row.map { WriteTarget(resource: kind, namespace: $0.namespace, name: $0.name) }
                        inspecting = row != nil
                    }, changeNamespaces: applyNamespaces,
                    loadNamespaces: { await session.namespaces() },
                    searchChanged: { tabs.setSearch($0) }
                )
                .id("\(tab.id)/\(session.namespaces.joined(separator: ","))")
            } else {
                ContentUnavailableView("Updates paused", systemImage: "pause.circle",
                                       description: Text("Resources reload when the app becomes active."))
            }
        } else if let failure = session.failure {
            // The detail pane is where the message belongs: there is room to read
            // it, and it is the one place the user is looking when a context will
            // not open.
            ContentUnavailableView {
                Label("Could not read the API", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("Try Again") { Task { await session.retry() } }
            }
        } else if session.catalog != nil {
            ContentUnavailableView("Choose a resource kind", systemImage: "square.stack",
                                   description: Text("Open a resource from the navigator to create a tab."))
        } else { ProgressView("Discovering resources…").frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    /// What ⌘W closes, and what the menu calls it.
    private var workspaceCommands: WorkspaceCommands {
        if paneHasFocus, let tool = pane.selected {
            return WorkspaceCommands(
                closeFocusedTab: {
                    pane.close(tool.id)
                    if pane.isEmpty { paneHasFocus = false }
                },
                closeFocusedTabTitle: "Close \(tool.kind.title)"
            )
        }
        if let tab = tabs.selected {
            return WorkspaceCommands(
                closeFocusedTab: {
                    let nextConnection = tabs.nextSelection(afterClosing: tab.id)?.connectionID
                    request(.close(tab.id), target: nextConnection ?? session?.connection.id)
                },
                closeFocusedTabTitle: "Close \(ResourceKindPresentation.name(tab.resource))"
            )
        }
        // Nothing to close, so ⌘W goes back to meaning Close Window.
        return WorkspaceCommands()
    }

    private func request(_ action: PendingSelection, target: UUID?) {
        if drafts.hasPendingDrafts && target != nil && target != session?.connection.id {
            pending = action; showDraftGuard = true
        } else { perform(action) }
    }
    private func perform(_ action: PendingSelection) {
        switch action {
        case .context(let id): clusters.selection = id; Task { await connectSelected() }
        case .tab(let id): tabs.select(id); activateSelectedTab()
        case .resource(let id, let resource):
            if let cached = sessions[id] { openResource(resource, in: cached) }
        case .close(let id):
            let wasSelected = tabs.selection == id
            tabs.close(id)
            if wasSelected {
                if tabs.selected != nil { activateSelectedTab() }
                else { kind = nil; clearSelection() }
            }
        }
    }
    private func requestConnect() {
        guard let id = clusters.selection else { return }
        let target = clusters.connection(forContextID: id)?.id
        if drafts.hasPendingDrafts && target != session?.connection.id {
            pending = .context(id); showDraftGuard = true
        } else { Task { await connectSelected() } }
    }
    private func connectSelected() async {
        if let connection = await clusters.connectSelectedContext() { activate(connection) }
    }
    private func activate(_ connection: ClusterConnection) {
        let cached: ClusterSession
        if let existing = sessions[connection.id] { cached = existing }
        else {
            cached = ClusterSession(connection: connection, client: environment.makeClient(for: connection))
            sessions[connection.id] = cached
        }
        expandedContexts.insert(connection.id)
        expandedGroups.insert("\(connection.id)/Workloads")
        if let tab = tabs.items.last(where: { $0.connectionID == connection.id }) {
            tabs.select(tab.id); activateSelectedTab()
        } else {
            session = cached; kind = nil; showingConnections = false; clearSelection(); revealContent()
        }
    }
    private func openResource(_ resource: DiscoveredResource, in session: ClusterSession) {
        tabs.open(resource, connection: session.connection)
        activateSelectedTab()
    }
    private func activateSelectedTab() {
        paneHasFocus = false
        guard let tab = tabs.selected, let cached = sessions[tab.connectionID] else { return }
        session = cached
        kind = tab.resource
        cached.namespaces = tab.namespaces
        showingConnections = false
        clearSelection()
        revealContent()
    }
    private func clearSelection() { rowID = nil; objectTarget = nil; inspecting = false }
    private var usesTouchNavigation: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }
    private func revealContent() {
        guard usesTouchNavigation else { return }
        compactColumn = .detail
        if sizeClass == .compact { columnVisibility = .detailOnly }
        else if sizeClass == .regular { columnVisibility = .automatic }
    }
    private func applyNamespaces(_ raw: [String]) -> String? {
        let values = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !values.isEmpty else { return "Choose at least one namespace." }
        if let invalid = values.first(where: {
            $0.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) == nil
        }) {
            return "“\(invalid)” is not a namespace name. Use up to 63 lowercase letters, numbers, and hyphens."
        }
        tabs.setNamespaces(values)
        session?.namespaces = values
        clearSelection()
        return nil
    }
    private func present(_ action: ResourceDetailView.Action, object: GenericResource, target: WriteTarget, session: ClusterSession) {
        let cluster = session.connection.displayName
        let tool: Destination.Tool
        switch action {
        case .edit:
            let key = EditorDraftStore.Key(connectionID: session.connection.id, target: target)
            let model = YAMLEditorModel(cluster: cluster, key: key, original: object.raw, writer: session.writer, drafts: drafts)
            if usesBottomPane {
                pane.open(.editor, id: "\(session.connection.id)/editor/\(target)",
                          subject: target.name, content: .editor(model))
                paneHasFocus = true
                return
            }
            tool = .editor(model)
        case .logs:
            let model = LogsModel(cluster: cluster, pod: object, client: session.client)
            if usesBottomPane {
                pane.open(.logs, id: "\(session.connection.id)/logs/\(target)",
                          subject: target.name, content: .logs(model))
                paneHasFocus = true
                return
            }
            tool = .logs(model)
        case .delete: tool = .action(ResourceActionModel(action: .delete, cluster: cluster, target: target, original: object, writer: session.writer))
        case .restart: tool = .action(ResourceActionModel(action: .restart, cluster: cluster, target: target, original: object, writer: session.writer))
        case .scale: tool = .action(ResourceActionModel(action: .scale, cluster: cluster, target: target, original: object, writer: session.writer))
        }
        destination = Destination(tool: tool)
    }
    private func discoveryFailure(_ group: GroupVersion, _ failure: DiscoveryFailure?) -> String {
        switch failure {
        case .permissionDenied: "\(group.apiVersion): permission denied"
        case .unavailable: "\(group.apiVersion): unavailable"
        case nil: group.apiVersion
        }
    }
}

#Preview { RootView().environment(AppEnvironment.inMemory()) }
