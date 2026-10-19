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

    let namespace: String
    let change: (String) -> String?
    var load: (@Sendable () async -> Options)?

    @State private var showing = false
    @State private var draft = ""
    @State private var failure: String?
    @State private var options: Options = .loading
    @FocusState private var searchFocused: Bool

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
        guard !value.isEmpty, value != namespace else { return false }
        if case .loaded(let all) = options { return !all.contains(value) }
        return true
    }

    var body: some View {
        Button {
            draft = ""
            failure = nil
            showing = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(namespace).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption)
            }
        }
        .help("Change namespace")
        .accessibilityLabel("Namespace: \(namespace)")
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
                .onSubmit { apply(draft) }
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
                Button { apply(draft) } label: {
                    row {
                        Image(systemName: "arrow.turn.down.left").foregroundStyle(.secondary)
                        Text("Use “\(draft.trimmingCharacters(in: .whitespaces))”").lineLimit(1)
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
                        Button { apply(name) } label: {
                            row {
                                Image(systemName: name == namespace ? "checkmark" : "folder")
                                    .foregroundStyle(name == namespace ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    .frame(width: 14)
                                Text(name).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .background(name == namespace ? Color.accentColor.opacity(0.14) : .clear)
                        .accessibilityAddTraits(name == namespace ? [.isButton, .isSelected] : .isButton)
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

    private func apply(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        failure = change(trimmed)
        if failure == nil { showing = false }
    }
}
