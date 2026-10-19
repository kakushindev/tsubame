import Foundation

/// Bounded exponential backoff with jitter.
///
/// The cluster's `Retry-After` always wins; this covers network failures and
/// stream drops, where the server gave no guidance. The bound is what keeps a
/// cluster that is down from turning into an unbounded retry loop on a phone.
public struct RetryPolicy: Hashable, Sendable {
    public let initialDelay: TimeInterval
    public let maximumDelay: TimeInterval
    public let multiplier: Double
    public let jitterFraction: Double
    public let maximumAttempts: Int?

    public init(
        initialDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 30,
        multiplier: Double = 2,
        jitterFraction: Double = 0.2,
        maximumAttempts: Int? = nil
    ) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.multiplier = multiplier
        self.jitterFraction = jitterFraction
        self.maximumAttempts = maximumAttempts
    }

    /// Reconnecting a dropped watch retries indefinitely: the view stays on screen
    /// showing a reconnecting state, so giving up would strand it.
    public static let watchReconnect = RetryPolicy()

    /// A one-off request gives up so the user sees an error instead of a spinner.
    public static let singleRequest = RetryPolicy(maximumAttempts: 3)

    public func shouldRetry(attempt: Int) -> Bool {
        guard let maximumAttempts else { return true }
        return attempt < maximumAttempts
    }

    /// Delay before the attempt numbered `attempt`, counting the first retry as 1.
    public func delay(forAttempt attempt: Int, randomness: Double = Double.random(in: 0...1)) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let exponential = initialDelay * pow(multiplier, Double(attempt - 1))
        let bounded = min(exponential, maximumDelay)
        let jitter = bounded * jitterFraction * (randomness * 2 - 1)
        return max(0, bounded + jitter)
    }
}
