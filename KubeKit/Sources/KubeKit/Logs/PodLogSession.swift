import Foundation
import KubeModels

/// One foreground log stream. Stop on background or target change; a new consumer
/// resumes from the last timestamp. No log content is persisted or put in errors.
public actor PodLogSession {
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    private let client: KubernetesClient
    private let target: PodLogTarget
    private let options: PodLogOptions
    private let retryPolicy: RetryPolicy
    private let sleep: Sleeper
    private var buffer: LogBuffer
    private var lastTimestamp: String?
    private var lastUpdated: Date?
    private var continuation: AsyncStream<LogSnapshot>.Continuation?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var pendingEmission: Task<Void, Never>?

    public init(
        client: KubernetesClient, target: PodLogTarget, options: PodLogOptions = PodLogOptions(),
        maximumLines: Int = 5_000, maximumBytes: Int = 2 * 1024 * 1024,
        retryPolicy: RetryPolicy = .watchReconnect,
        sleep: @escaping Sleeper = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.client = client
        self.target = target
        self.options = options
        self.retryPolicy = retryPolicy
        self.sleep = sleep
        buffer = LogBuffer(maximumLines: maximumLines, maximumBytes: maximumBytes)
    }

    public var isRunning: Bool { task != nil }

    public func snapshots() -> AsyncStream<LogSnapshot> {
        stop()
        generation += 1
        let current = generation
        // A single pending full snapshot bounds memory for a slow renderer.
        let (stream, output) = AsyncStream<LogSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = output
        output.onTermination = { [weak self] _ in Task { await self?.stop(generation: current) } }
        emit(.connecting)
        task = Task { await self.run(generation: current) }
        return stream
    }

    public func stop() { stop(generation: generation) }

    private func stop(generation current: Int) {
        guard current == generation else { return }
        generation += 1
        task?.cancel()
        pendingEmission?.cancel()
        pendingEmission = nil
        task = nil
        emit(.stopped)
        continuation?.finish()
        continuation = nil
    }

    private func run(generation current: Int) async {
        var attempt = 0
        while current == generation && !Task.isCancelled {
            do {
                // Replay suppression counts occurrences so repeated identical
                // messages within one timestamp remain separate legitimate lines.
                let resume = lastTimestamp
                var replay: [String: Int] = [:]
                if let resume, let lastDate = RFC3339.date(from: resume) {
                    // Some kubelets round sinceTime to whole seconds. Include
                    // that entire second of the retained tail in replay checks.
                    let boundary = floor(lastDate.timeIntervalSince1970)
                    for line in buffer.lines {
                        if let stamp = line.timestamp, let date = RFC3339.date(from: stamp), date.timeIntervalSince1970 >= boundary {
                            replay[stamp + "\u{0}" + line.text, default: 0] += 1
                        }
                    }
                }
                let stream = try await client.stream(options.request(for: target, resumingFrom: resume))
                guard current == generation, !Task.isCancelled else { return }
                emit(.streaming)
                for try await bytes in stream {
                    guard current == generation, !Task.isCancelled else { return }
                    let raw = String(decoding: bytes, as: UTF8.self)
                    let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                    let stamp = parts.count == 2 && RFC3339.date(from: String(parts[0])) != nil ? String(parts[0]) : nil
                    let text = stamp == nil ? raw : String(parts[1])
                    let replayKey = (stamp ?? "") + "\u{0}" + text
                    if let remaining = replay[replayKey], remaining > 0 {
                        replay[replayKey] = remaining - 1
                        continue
                    }
                    buffer.append(timestamp: stamp, text: text)
                    if let stamp { lastTimestamp = stamp }
                    lastUpdated = Date()
                    attempt = 0
                    scheduleEmission(generation: current)
                }
                guard options.follow && !options.previous else { finish(.ended, generation: current); return }
                throw KubernetesError.streamInterrupted(underlying: "The server closed the log stream.")
            } catch is CancellationError {
                finish(.stopped, generation: current)
                return
            } catch {
                guard current == generation, !Task.isCancelled else { return }
                // Unknown failures must not quote a log chunk in diagnostics.
                let failure = error as? KubernetesError ?? .streamInterrupted(underlying: "The log stream ended unexpectedly.")
                emit(.interrupted, failure: failure, attempt: attempt + 1)
                guard failure.isTransient, retryPolicy.shouldRetry(attempt: attempt) else {
                    finish(.interrupted, failure: failure, generation: current)
                    return
                }
                attempt += 1
                let delay: TimeInterval
                if case .throttled(let retryAfter, _) = failure { delay = retryAfter }
                else { delay = retryPolicy.delay(forAttempt: attempt) }
                do { try await sleep(delay) }
                catch { finish(.stopped, generation: current); return }
            }
        }
        finish(.stopped, generation: current)
    }

    private func emit(_ state: LogSnapshot.State, failure: KubernetesError? = nil, attempt: Int = 0) {
        if state != .streaming {
            pendingEmission?.cancel()
            pendingEmission = nil
        }
        let freshness: DataFreshness
        if state == .streaming { freshness = .live(since: Date()) }
        else if state == .interrupted && attempt > 0 { freshness = .reconnecting(since: Date(), attempt: attempt) }
        else if let lastUpdated { freshness = .stale(lastUpdated: lastUpdated) }
        else { freshness = .disconnected(since: Date()) }
        continuation?.yield(LogSnapshot(
            lines: buffer.lines, droppedLineCount: buffer.droppedLineCount,
            freshness: freshness, state: state, failure: failure
        ))
    }

    /// Coalesce bursts off the main actor; the ring remains current, while the UI
    /// receives at most ten full-buffer copies per second.
    private func scheduleEmission(generation current: Int) {
        guard pendingEmission == nil else { return }
        pendingEmission = Task {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard current == generation, !Task.isCancelled else { return }
            pendingEmission = nil
            emit(.streaming)
        }
    }

    private func finish(_ state: LogSnapshot.State, failure: KubernetesError? = nil, generation current: Int) {
        guard current == generation else { return }
        pendingEmission?.cancel()
        pendingEmission = nil
        emit(state, failure: failure)
        task = nil
        continuation?.finish()
        continuation = nil
    }
}
