import Foundation
import Testing
@testable import KubeKit

@Suite("RetryPolicy")
struct RetryPolicyTests {
    @Test("Grows the delay exponentially and caps it")
    func growsAndCaps() {
        let policy = RetryPolicy(initialDelay: 1, maximumDelay: 8, multiplier: 2, jitterFraction: 0)

        #expect(policy.delay(forAttempt: 0, randomness: 0.5) == 0)
        #expect(policy.delay(forAttempt: 1, randomness: 0.5) == 1)
        #expect(policy.delay(forAttempt: 2, randomness: 0.5) == 2)
        #expect(policy.delay(forAttempt: 4, randomness: 0.5) == 8)
        #expect(policy.delay(forAttempt: 10, randomness: 0.5) == 8)
    }

    @Test("Keeps jitter within the configured fraction and never negative")
    func boundsJitter() {
        let policy = RetryPolicy(initialDelay: 4, maximumDelay: 30, multiplier: 2, jitterFraction: 0.25)

        #expect(policy.delay(forAttempt: 1, randomness: 0) == 3)
        #expect(policy.delay(forAttempt: 1, randomness: 1) == 5)
        #expect(policy.delay(forAttempt: 1, randomness: 0) >= 0)
    }

    @Test("A watch reconnects indefinitely; a single request gives up")
    func stopsOnlyWhenBounded() {
        #expect(RetryPolicy.watchReconnect.shouldRetry(attempt: 1000))
        #expect(RetryPolicy.singleRequest.shouldRetry(attempt: 2))
        #expect(RetryPolicy.singleRequest.shouldRetry(attempt: 3) == false)
    }
}
