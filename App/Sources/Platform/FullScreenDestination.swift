import SwiftUI

extension View {
    /// Full-screen tools on mobile, an independent resizable sheet on macOS.
    @ViewBuilder func fullScreenDestination<Item: Identifiable, Content: View>(
        item: Binding<Item?>, onDismiss: @escaping () -> Void, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(macOS)
        sheet(item: item, onDismiss: onDismiss) { item in
            content(item).frame(minWidth: 680, minHeight: 520)
        }
        #else
        fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #endif
    }
}

extension View {
    @ViewBuilder func workspaceMinimumSize() -> some View {
        #if os(macOS)
        frame(minWidth: 850, minHeight: 540)
        #else
        self
        #endif
    }
}

extension Scene {
    func workspaceDefaultSize() -> some Scene {
        #if os(macOS)
        defaultSize(width: 1180, height: 760)
        #else
        self
        #endif
    }
}

extension View {
    @ViewBuilder func workspaceTableAppearance() -> some View {
        #if os(macOS)
        self.alternatingRowBackgrounds(.disabled)
        #else
        self
        #endif
    }
}
