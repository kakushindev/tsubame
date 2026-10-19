import Foundation
import Observation

/// The tools that open in the workspace's bottom pane.
///
/// YAML editing and log reading are long-lived: the user keeps one open while
/// looking something up in the table or the tree beside it. Presenting either
/// modally takes the rest of the window away for the whole task, which is the one
/// thing a reference lookup needs. Confirmations are deliberately not here — a
/// delete or a scale wants protected focus, so it stays modal.
@MainActor @Observable
final class WorkspacePaneModel {
    struct Tool: Identifiable {
        enum Kind: Hashable {
            case editor, logs

            var title: String {
                switch self {
                case .editor: return "YAML"
                case .logs: return "Logs"
                }
            }

            var symbol: String {
                switch self {
                case .editor: return "curlybraces"
                case .logs: return "text.alignleft"
                }
            }
        }

        let id: String
        let kind: Kind
        /// What this tool is pointed at, shown beside the title so the pane never
        /// becomes ambiguous once several are open.
        let subject: String
        let content: Content

        enum Content {
            case editor(YAMLEditorModel)
            case logs(LogsModel)
        }
    }

    private(set) var tools: [Tool] = []
    private(set) var selection: String?
    /// Collapsed keeps the tool open and its state alive while giving the table back
    /// its room, which is what a user wants between two edits.
    var isCollapsed = false
    /// Carried here rather than in the view so a context switch or a tab change
    /// cannot silently reset the size the user chose.
    var height: Double = 320

    static let minimumHeight: Double = 140
    static let headerHeight: Double = 30

    var selected: Tool? { tools.first { $0.id == selection } }
    var isEmpty: Bool { tools.isEmpty }

    /// Opens a tool, replacing any existing one of the same kind for the same
    /// object so repeated taps do not stack duplicates.
    func open(_ kind: Tool.Kind, id: String, subject: String, content: Tool.Content) {
        let tool = Tool(id: id, kind: kind, subject: subject, content: content)
        if let index = tools.firstIndex(where: { $0.id == id }) {
            tools[index] = tool
        } else {
            tools.append(tool)
        }
        selection = id
        isCollapsed = false
    }

    func select(_ id: String) {
        guard tools.contains(where: { $0.id == id }) else { return }
        selection = id
        isCollapsed = false
    }

    func close(_ id: String) {
        guard let index = tools.firstIndex(where: { $0.id == id }) else { return }
        tools.remove(at: index)
        if selection == id {
            selection = tools.isEmpty ? nil : tools[min(index, tools.count - 1)].id
        }
    }

    /// Closes everything belonging to a context that is going away, so a pane never
    /// outlives the session whose client it holds.
    func closeAll(matching prefix: String) {
        tools.removeAll { $0.id.hasPrefix(prefix) }
        if let selection, !tools.contains(where: { $0.id == selection }) {
            self.selection = tools.last?.id
        }
    }

    func closeAll() {
        tools.removeAll()
        selection = nil
    }

    /// Any draft the pane is holding, so a context switch can ask before discarding.
    var openEditors: [YAMLEditorModel] {
        tools.compactMap {
            if case .editor(let model) = $0.content { return model }
            return nil
        }
    }
}
