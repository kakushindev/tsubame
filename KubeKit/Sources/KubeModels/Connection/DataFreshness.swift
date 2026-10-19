import Foundation

/// How current the data on screen is.
///
/// The UI must never present `.stale` or `.disconnected` data as live, so this is a
/// required part of every watched view's state rather than a presentation detail.
public enum DataFreshness: Hashable, Sendable {
    /// A watch is open and delivering events.
    case live(since: Date)
    /// The watch dropped and the client is retrying.
    case reconnecting(since: Date, attempt: Int)
    /// Last known data, with the time it was last confirmed current.
    case stale(lastUpdated: Date)
    /// Kept current by polling, because the server does not support watching this
    /// resource.
    ///
    /// Its own case rather than `.live` on purpose: data refreshed every fifteen
    /// seconds is not a live watch, and PRD §7 says not to present it as one. The
    /// UI says "updates every 15s" instead.
    case polling(lastUpdated: Date, interval: TimeInterval)
    /// No connection and no usable data.
    case disconnected(since: Date)

    public var isLive: Bool {
        if case .live = self { return true }
        return false
    }
}
