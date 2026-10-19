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
    var load: (@Sendable () async -> Options)?

    @State private var showing = false
    @State private var draft = ""
    @State private var failure: String?
    @State private var options: Options = .loading
    @State private var working: [String] = []
    @FocusState private var searchFocused: Bool

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
        .popover(isPresented: $showing) {
            content
                .frame(width: 280)
                .task(id: showing) {
                    guard showing, let load else { return }
                    options = .loading
                    options = await load()
                    searchFocused = true
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
                        let isOn = working.contains(name)
                        Button { toggle(name) } label: {
                            row {
                                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    .frame(width: 14)
                                Text(name).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .background(isOn ? Color.accentColor.opacity(0.14) : .clear)
                        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
            // Tall enough to browse, short enough that the popover stays a control.
            .frame(maxHeight: 260)
        }
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

    /// Applies as the user picks, so the table follows the selection rather than
    /// waiting for a confirm step the rest of the toolbar does not have.
    private func commit() {
        failure = change(working)
    }
}
