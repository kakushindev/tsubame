import SwiftUI
import KubeModels

/// A resource's state in a list row or a detail header.
///
/// The symbol distinguishes the states on its own, and colour reinforces it rather
/// than carrying it: PRD §18 requires status to survive Increase Contrast and
/// colour-blind vision. The text stays at full contrast; only the symbol is tinted,
/// so a dense table does not turn into a colour chart.
struct ResourceStatusBadge: View {
    let summary: ResourceRowSummary

    var body: some View {
        Label {
            Text(summary.headline).foregroundStyle(.primary)
        } icon: {
            Image(systemName: Self.symbol(summary.tone))
                .foregroundStyle(Self.tint(summary.tone))
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .fixedSize(horizontal: true, vertical: false)
        .help(summary.headline)
        .accessibilityLabel(summary.headline)
    }

    static func symbol(_ tone: ResourceRowSummary.Tone) -> String {
        switch tone {
        case .normal: "checkmark.circle.fill"
        case .pending: "clock.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        case .terminating: "trash.circle.fill"
        }
    }

    static func tint(_ tone: ResourceRowSummary.Tone) -> Color {
        switch tone {
        case .normal: .green
        case .pending: .blue
        case .attention: .orange
        case .failure: .red
        // Going away: present, but not something to look at.
        case .terminating: .secondary
        }
    }
}
