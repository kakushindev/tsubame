import SwiftUI

/// Keep the mark size and iOS background aligned with LaunchScreen.storyboard
/// for a continuous cold-launch appearance. BrandMark adapts to light/dark mode.
struct SplashScreen: View {
    var body: some View {
        Image("BrandMark")
            .resizable()
            .scaledToFit()
            .frame(width: 128, height: 128)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
            .ignoresSafeArea()
            .accessibilityLabel("Tsubame is starting")
    }

    private var background: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

#Preview {
    SplashScreen()
}
