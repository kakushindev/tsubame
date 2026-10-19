import Foundation

/// Parses the timestamp formats the Kubernetes API emits.
///
/// The only place this project turns an API timestamp string into a `Date`.
/// `metav1.Time` has whole seconds; `metav1.MicroTime` carries microseconds, and
/// appears on `Event.eventTime` and several `lastTransitionTime` fields.
///
/// It exists because `JSONDecoder.DateDecodingStrategy.iso8601` behaves differently
/// depending on the Foundation shipped with the running OS: it accepts fractional
/// seconds on current releases and rejects them on the macOS 14 / iOS 17 floor this
/// app supports. Code that parsed timestamps itself would work in development and
/// fail for users on older systems.
public enum RFC3339 {
    public static func date(from text: String) -> Date? {
        if let date = try? Date(text, strategy: fractionalSeconds) { return date }
        if let date = try? Date(text, strategy: wholeSeconds) { return date }
        return nil
    }

    // Value types, so they are `Sendable` and safe to share across the concurrent
    // decodes a paged list performs. `DateFormatter` would not be.
    private static let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
}
