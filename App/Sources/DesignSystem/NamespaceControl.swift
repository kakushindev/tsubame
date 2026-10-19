import SwiftUI

/// A direct scope control, shared by the resource table's toolbar.
struct NamespaceControl: View {
    let namespace: String
    let change: (String) -> String?
    @State private var showing = false
    @State private var draft = ""
    @State private var failure: String?

    var body: some View {
        Button {
            draft = namespace
            failure = nil
            showing = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(namespace).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption)
            }
        }
        .help("Change namespace").accessibilityLabel("Namespace: \(namespace)")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Namespace").font(.headline)
                TextField("Namespace", text: $draft).textFieldStyle(.roundedBorder).onSubmit(apply)
                if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
                Text("You can enter a namespace even if your account cannot list them.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Use Namespace", action: apply).keyboardShortcut(.return) }
            }.padding(20).frame(idealWidth: 300)
        }
    }

    private func apply() {
        failure = change(draft)
        if failure == nil { showing = false }
    }
}
