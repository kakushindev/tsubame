import SwiftUI

/// A block of text meant to be taken away: a policy to install, a command to run.
///
/// Copying is an explicit action, which is also what keeps resource content out
/// of the pasteboard by accident (PRD §12).
struct CopyableCodeBlock: View {
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(.automatic)

            Button {
                copy()
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(copied ? "Copied to the clipboard" : "Copy to the clipboard")
        }
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
