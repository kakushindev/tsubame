import SwiftUI

/// Text stands in for the future logo. Keep the default size and iOS background
/// aligned with LaunchScreen.storyboard for a continuous cold-launch appearance.
struct SplashScreen: View {
    @ScaledMetric(relativeTo: .largeTitle) private var wordmarkSize = 34

    var body: some View {
        Text("Tsubame")
            .font(.system(size: wordmarkSize, weight: .semibold))
            .foregroundStyle(.primary)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .padding(32)
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
