import SwiftUI

@main
struct TsubameApp: App {
    /// One environment per process. Feature models receive their dependencies from
    /// it rather than reaching for singletons, so each one can be built with test
    /// doubles.
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)

        }
        .workspaceDefaultSize()
        .commands {
            // PRD §10: macOS needs menu commands and shortcuts for the actions the
            // toolbar exposes. They are added as the matching screens land.
            SidebarCommands()
            CommandGroup(before: .saveItem) {
                CloseFocusedTabCommand()
            }
        }
    }
}

/// ⌘W closes the focused tab, and the window only once nothing is left — the
/// behaviour every tabbed Mac app has. Disabled when there is no tab to close, so
/// the shortcut falls through to the system's own Close.
private struct CloseFocusedTabCommand: View {
    @FocusedValue(\.workspaceCommands) private var commands

    var body: some View {
        Button(commands?.closeFocusedTabTitle ?? "Close Tab") {
            commands?.closeFocusedTab?()
        }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(commands?.closeFocusedTab == nil)
    }
}
