import SwiftUI
// The upstream Swift 5.9 module has unannotated mutable default themes. All
// access stays on this main-actor SwiftUI view; strict checking stays on elsewhere.
@preconcurrency import CodeEditorView
import LanguageSupport

/// The only view coupled to the editor package; a TextEditor can replace it here.
struct YAMLSourceEditor: View {
    @Binding var text: String
    @State private var position = CodeEditor.Position()
    @State private var messages: Set<TextLocated<Message>> = []
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var editorFontSize = 14

    var body: some View {
        CodeEditor(text: $text, position: $position, messages: $messages, language: YAMLConfiguration.language)
            .environment(\.codeEditorTheme, theme)
            .accessibilityLabel("YAML source")
    }

    private var theme: Theme {
        var theme = colorScheme == .dark ? Theme.defaultDark : Theme.defaultLight
        theme.fontSize = editorFontSize
        return theme
    }
}

@MainActor
enum YAMLConfiguration {
    static let language = LanguageConfiguration(
        name: "YAML", supportsSquareBrackets: true, supportsCurlyBrackets: true,
        indentationSensitiveScoping: true,
        stringRegex: /"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'/,
        characterRegex: nil,
        numberRegex: /[-+]?[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?/,
        singleLineComment: "#", nestedComment: nil,
        identifierRegex: /[a-zA-Z_][a-zA-Z0-9_-]*/,
        operatorRegex: nil, reservedIdentifiers: ["true", "false", "null", "~"], reservedOperators: []
    )
}
