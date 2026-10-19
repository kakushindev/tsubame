import SwiftUI

/// How menu commands reach the window they act on.
///
/// Commands live outside the view hierarchy and cannot read its state, so the
/// window publishes what it can do and the menu reads it back. A command is absent
/// when it would do nothing, which is also what disables its menu item.
struct WorkspaceCommands: Equatable {
    /// Closes whichever tab currently has focus: a tool in the bottom pane when
    /// that is where the user is working, otherwise the open resource tab.
    var closeFocusedTab: (() -> Void)?
    /// What the menu item should call itself, so the user knows what ⌘W will take
    /// away before pressing it.
    var closeFocusedTabTitle: String = "Close Tab"

    static func == (lhs: WorkspaceCommands, rhs: WorkspaceCommands) -> Bool {
        (lhs.closeFocusedTab == nil) == (rhs.closeFocusedTab == nil)
            && lhs.closeFocusedTabTitle == rhs.closeFocusedTabTitle
    }
}

extension FocusedValues {
    @Entry var workspaceCommands: WorkspaceCommands?
}
