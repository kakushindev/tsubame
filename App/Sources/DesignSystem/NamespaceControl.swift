import SwiftUI

/// The resource table's scope control: which namespace the list is showing.
///
/// It lists what the cluster actually has, because typing a namespace from memory
/// is the kind of small friction that makes a tool feel like a form. Typing still
/// works, and is the only thing that works when the account may read inside a
/// namespace but may not list them — which PRD §12 requires be said plainly rather
/// than shown as an empty menu.
struct NamespaceControl: View {
    /// What the cluster said when asked for its namespaces.
    enum Options: Equatable {
        case loading
        case loaded([String])
        /// RBAC allows working in a namespace without listing them all.
        case denied
        case failed(String)
    }

    let selected: [String]
    let change: ([String]) -> String?
    /// What was read last time. Shown at once, so opening the control is instant
    /// and does not flash a spinner over a list that is almost certainly current.
    var cached: Options?
    /// Re-reads in the background while the cached list is already on screen.
    var refresh: (@Sendable () async -> Options)?

    @State private var showing = false
    @State private var draft = ""
    @State private var failure: String?
    @State private var options: Options = .loading
    @State private var working: [String] = []
    @FocusState private var searchFocused: Bool
    /// Tracks the text size, so the list's height is a number of rows rather than
    /// a guess that truncates at larger Dynamic Type settings.
    @ScaledMetric(relativeTo: .callout) private var rowHeight = 29

    /// "default", or "default +2" once several are in view.
    static func scopeLabel(_ namespaces: [String]) -> String {
        guard let first = namespaces.first else { return "No namespace" }
        return namespaces.count > 1 ? "\(first) +\(namespaces.count - 1)" : first
    }

    private var matches: [String] {
        guard case .loaded(let all) = options else { return [] }
        let query = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter { $0.lowercased().contains(query) }
    }

    /// Offer what was typed when it is not already a namespace, so a namespace that
    /// exists but cannot be listed is still reachable.
    private var typedIsNew: Bool {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !working.contains(value) else { return false }
        if case .loaded(let all) = options { return !all.contains(value) }
        return true
    }

    var body: some View {
        Button {
            draft = ""
            failure = nil
            working = selected
            showing = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(Self.scopeLabel(selected)).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption)
            }
        }
        .help(selected.count > 1 ? selected.joined(separator: ", ") : "Change namespace")
        .accessibilityLabel(
            selected.count > 1
                ? "Namespaces: \(selected.joined(separator: ", "))"
                : "Namespace: \(selected.first ?? "none")"
        )
        // Below the control, not above it: the toolbar sits near the top of the
        // window, so opening upward covered the tab strip the user was just in.
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            content
                .frame(width: 280)
                .task(id: showing) {
                    guard showing else { return }
                    // Only the very first open has nothing to show.
                    options = cached ?? .loading
                    searchFocused = true
                    guard let refresh else { return }
                    let latest = await refresh()
                    guard !Task.isCancelled else { return }
                    options = latest
                }
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search or enter a namespace", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit {
                    let value = draft.trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { toggle(value); draft = "" } else { commit() }
                }
                .padding(10)

            switch options {
            case .loading:
                row { ProgressView().controlSize(.small); Text("Loading namespaces…").foregroundStyle(.secondary) }
            case .denied:
                // Not an empty menu: the account may use a namespace without being
                // allowed to enumerate them.
                notice("Your account cannot list namespaces. Enter one to use it.")
            case .failed(let reason):
                notice(reason)
            case .loaded:
                namespaceList
            }

            if typedIsNew {
                Divider()
                Button { toggle(draft.trimmingCharacters(in: .whitespaces)); draft = "" } label: {
                    row {
                        Image(systemName: "plus").foregroundStyle(.secondary)
                        Text("Add “\(draft.trimmingCharacters(in: .whitespaces))”").lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }

            if let failure {
                Divider()
                Text(failure).font(.callout).foregroundStyle(.red).padding(10)
            }
        }
    }

    @ViewBuilder private var namespaceList: some View {
        if matches.isEmpty {
            notice("No namespace matches “\(draft.trimmingCharacters(in: .whitespaces))”.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches, id: \.self) { name in
                        namespaceRow(name)
                    }
                }
            }
            // Tall enough to browse, short enough that the popover stays a control.
            // An explicit height, because `maxHeight` only caps a ScrollView and
            // leaves it as short as its content — which is why this opened barely
            // taller than one row. Shows up to twelve namespaces; more scroll.
            .frame(height: min(CGFloat(matches.count), 12) * rowHeight)
        }
    }

    /// Two targets in one row, because they answer two different questions.
    ///
    /// The checkbox adds or removes a namespace from what is already in view and
    /// leaves the list open, so several can be picked in one visit. The name is
    /// the common case — look at this one — and narrows to it and closes.
    private func namespaceRow(_ name: String) -> some View {
        let isOn = working.contains(name)
        return HStack(spacing: 8) {
            Button { toggle(name) } label: {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isOn ? "Stop showing \(name)" : "Also show \(name)")
            .accessibilityLabel(isOn ? "Stop showing \(name)" : "Also show \(name)")
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)

            Button { showOnly(name) } label: {
                HStack(spacing: 0) {
                    Text(name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Show only \(name)")
            .accessibilityLabel("Show only \(name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isOn ? Color.accentColor.opacity(0.14) : .clear)
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
    }

    private func toggle(_ name: String) {
        guard !name.isEmpty else { return }
        if let index = working.firstIndex(of: name) {
            // Never leave the table with no scope at all.
            guard working.count > 1 else { return }
            working.remove(at: index)
        } else {
            working.append(name)
        }
        commit()
    }

    /// Narrows to one namespace and closes, which is what picking a name means.
    private func showOnly(_ name: String) {
        guard !name.isEmpty else { return }
        working = [name]
        commit()
        if failure == nil { showing = false }
    }

    /// Applies as the user picks, so the table follows the selection rather than
    /// waiting for a confirm step the rest of the toolbar does not have.
    private func commit() {
        failure = change(working)
    }
}
