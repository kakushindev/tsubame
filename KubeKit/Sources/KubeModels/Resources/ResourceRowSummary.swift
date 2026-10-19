import Foundation

/// The one-glance state of an object, formatted for a list row.
///
/// Values are already strings: the row is rendered thousands of times and must not
/// re-derive anything. `tone` is not a color — PRD §18 requires status to survive
/// without color, so the view maps tone to a symbol and a word as well as a tint.
public struct ResourceRowSummary: Hashable, Sendable {
    public enum Tone: Hashable, Sendable {
        /// Working as intended.
        case normal
        /// On its way somewhere: pending, creating, rolling out.
        case pending
        /// Needs a look, but not failed: partially ready, suspended, evicted.
        case attention
        /// Failed outright.
        case failure
        /// Being deleted.
        case terminating
    }

    public struct Field: Hashable, Sendable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// The headline state, such as "Running", "2/3", or "CrashLoopBackOff".
    public let headline: String
    /// Extra columns, formatted, in display order.
    public let fields: [Field]
    public let tone: Tone

    public init(headline: String, fields: [Field] = [], tone: Tone = .normal) {
        self.headline = headline
        self.fields = fields
        self.tone = tone
    }
}

extension ResourceObject {
    /// What a list row shows for a kind with no typed model.
    ///
    /// Deliberately modest. It reports what any object carries — deletion, a
    /// `status.phase`, a `Ready` condition — and otherwise says nothing rather than
    /// inventing a status for a kind it does not understand.
    public var genericRowSummary: ResourceRowSummary {
        if metadata.deletionTimestamp != nil {
            return ResourceRowSummary(headline: "Terminating", tone: .terminating)
        }
        if let phase = raw["status", "phase"]?.stringValue {
            return ResourceRowSummary(headline: phase, tone: Self.tone(forPhase: phase))
        }
        if let conditions = raw["status", "conditions"]?.arrayValue {
            for condition in conditions
            where condition.objectValue?["type"]?.stringValue == "Ready" {
                let status = condition.objectValue?["status"]?.stringValue
                return ResourceRowSummary(
                    headline: status == "True" ? "Ready" : "Not ready",
                    tone: status == "True" ? .normal : .attention
                )
            }
        }
        return ResourceRowSummary(headline: "—", tone: .normal)
    }

    static func tone(forPhase phase: String) -> ResourceRowSummary.Tone {
        switch phase {
        case "Running", "Active", "Succeeded", "Bound", "Available": return .normal
        case "Pending", "ContainerCreating": return .pending
        case "Failed", "Lost": return .failure
        case "Terminating": return .terminating
        default: return .attention
        }
    }
}
