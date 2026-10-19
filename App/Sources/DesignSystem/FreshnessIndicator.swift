import SwiftUI
import KubeModels

/// Shows whether what is on screen is live, reconnecting, stale, or disconnected.
///
/// PRD §7 and §12 make this a correctness requirement, not decoration: no browsing
/// screen may present cached data without it.
struct FreshnessIndicator: View {
    let freshness: DataFreshness

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
        }
        .font(.caption)
        .accessibilityLabel(Text(title))
    }

    private var title: String {
        switch freshness {
        case .live:
            return "Live"
        case .reconnecting(_, let attempt):
            return "Reconnecting (attempt \(attempt))"
        case .stale(let lastUpdated):
            return "Last updated \(lastUpdated.formatted(.relative(presentation: .named)))"
        case .disconnected:
            return "Disconnected"
        }
    }

    private var symbolName: String {
        switch freshness {
        case .live: return "dot.radiowaves.left.and.right"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .stale: return "clock.arrow.circlepath"
        case .disconnected: return "bolt.horizontal.circle"
        }
    }

    private var tint: Color {
        switch freshness {
        case .live: return .green
        case .reconnecting: return .orange
        case .stale: return .secondary
        case .disconnected: return .red
        }
    }
}

#Preview {
    VStack(alignment: .leading) {
        FreshnessIndicator(freshness: .live(since: .now))
        FreshnessIndicator(freshness: .reconnecting(since: .now, attempt: 2))
        FreshnessIndicator(freshness: .stale(lastUpdated: .now.addingTimeInterval(-300)))
        FreshnessIndicator(freshness: .disconnected(since: .now))
    }
    .padding()
}
