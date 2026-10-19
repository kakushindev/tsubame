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
        case .polling(_, let interval):
            // Deliberately not "Live": this resource cannot be watched, so the data
            // is as old as the last poll. PRD §7 says not to present it otherwise.
            return "Updates every \(Int(interval))s"
        }
    }

    private var symbolName: String {
        switch freshness {
        case .live: return "dot.radiowaves.left.and.right"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .stale: return "clock.arrow.circlepath"
        case .disconnected: return "bolt.horizontal.circle"
        case .polling: return "arrow.clockwise"
        }
    }

    private var tint: Color {
        switch freshness {
        case .live: return .green
        case .reconnecting: return .orange
        case .stale: return .secondary
        case .disconnected: return .red
        case .polling: return .secondary
        }
    }
}

#Preview {
    VStack(alignment: .leading) {
        FreshnessIndicator(freshness: .live(since: .now))
        FreshnessIndicator(freshness: .reconnecting(since: .now, attempt: 2))
        FreshnessIndicator(freshness: .stale(lastUpdated: .now.addingTimeInterval(-300)))
        FreshnessIndicator(freshness: .disconnected(since: .now))
        FreshnessIndicator(freshness: .polling(lastUpdated: .now, interval: 15))
    }
    .padding()
}
