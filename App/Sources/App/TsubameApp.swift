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
        }
    }
}
