import Foundation
import KubeModels

/// Keeps one collection current with the list-then-watch loop the Kubernetes API
/// requires (PRD §9.3, §17).
///
/// The loop is: page through a list, remember the list's `resourceVersion`, watch
/// from there, and apply events to the cache. A `410 Gone` means the server's
/// history moved past that version, so the cache is discarded and relisted exactly
/// once. A dropped connection reconnects with bounded backoff; a `Retry-After` from
/// the server replaces that backoff. Every state change is published as a snapshot
/// carrying the current `DataFreshness`, so stale data is never presented as live.
///
/// One watcher serves one consumer. Cancelling that consumer — a view closing, a
/// context switch — terminates the snapshot stream, which cancels the run task and
/// with it the open request.
public actor ResourceWatcher<Object: ResourceObject & Codable> {
    /// Replaces `Task.sleep` in tests, so backoff can be asserted without waiting.
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let client: KubernetesClient
    private let resource: GroupVersionResource
    private let namespace: String?
    private let listOptions: ListOptions
    private let retryPolicy: RetryPolicy
    /// How many snapshots may wait for a slow consumer before the oldest are
    /// dropped. Each snapshot is complete, so dropping an intermediate one loses
    /// nothing: the consumer still sees the latest state of every object.
    private let snapshotBufferLimit: Int
    /// After this many failed reconnects the data stops being "reconnecting" and is
    /// labelled stale, because a user watching a spinner for that long is reading
    /// numbers that may no longer be true.
    private let reconnectsBeforeStale: Int
    private let sleep: Sleeper

    private var objects: [String: Object] = [:]
    private var resourceVersion: String?
    private var lastConfirmed: Date?
    private var disconnectedSince: Date?
    private var liveSince: Date?
    private var reconnectAttempt = 0
    private var hasGivenUp = false
    private var failure: KubernetesError?
    private var continuation: AsyncStream<ResourceSnapshot<Object>>.Continuation?
    private var runTask: Task<Void, Never>?
    /// Identifies the current consumer, so a stream that is torn down after a newer
    /// one started cannot stop the newer one.
    private var session = 0

    public init(
        client: KubernetesClient,
        resource: GroupVersionResource,
        namespace: String?,
        options: ListOptions = ListOptions(),
        retryPolicy: RetryPolicy = .watchReconnect,
        snapshotBufferLimit: Int = 64,
        reconnectsBeforeStale: Int = 3,
        sleep: @escaping Sleeper = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.client = client
        self.resource = resource
        self.namespace = namespace
        self.listOptions = options
        self.retryPolicy = retryPolicy
        self.snapshotBufferLimit = max(1, snapshotBufferLimit)
        self.reconnectsBeforeStale = max(0, reconnectsBeforeStale)
        self.sleep = sleep
    }

    /// Whether the loop is still running. Nothing is left behind after the consumer
    /// goes away, which is what this answers for the caller and for tests.
    public var isRunning: Bool { runTask != nil }

    public var currentFreshness: DataFreshness { freshness() }

    /// How many states have been published since this watcher started. A consumer
    /// that received fewer fell behind and had intermediate states dropped, which
    /// is safe here because every snapshot is complete.
    private(set) public var publishedSnapshots = 0

    /// Starts the loop and publishes every state it reaches. Calling this again
    /// replaces the previous consumer and its connection.
    public func snapshots() -> AsyncStream<ResourceSnapshot<Object>> {
        stop()
        session += 1
        hasGivenUp = false
        publishedSnapshots = 0
        let current = session

        let (stream, continuation) = AsyncStream<ResourceSnapshot<Object>>.makeStream(
            bufferingPolicy: .bufferingNewest(snapshotBufferLimit)
        )
        self.continuation = continuation
        runTask = Task { await self.run() }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop(session: current) }
        }
        emit()
        return stream
    }

    /// Cancels the loop and closes the stream. Safe to call more than once.
    public func stop() {
        stop(session: session)
    }

    private func stop(session identifier: Int) {
        guard identifier == session else { return }
        runTask?.cancel()
        runTask = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - The loop

    private func run() async {
        while !Task.isCancelled {
            do {
                if resourceVersion == nil {
                    try await listAll()
                }
                guard !Task.isCancelled else { break }

                switch try await consumeWatch() {
                case .expired:
                    // The server told us to start over. That is an instruction, not
                    // a failure: discard the cache and relist with no backoff.
                    discardCache()
                    continue
                case .closed:
                    break
                }
            } catch is CancellationError {
                break
            } catch let error as KubernetesError {
                if isTerminal(error) {
                    finish(with: error)
                    return
                }
                if case .resourceVersionExpired = error {
                    // The same instruction as the in-stream event, arriving as a
                    // failed request instead: start over rather than retrying a
                    // version the server has already forgotten.
                    discardCache()
                    continue
                }
                failure = error
                if case .throttled(let retryAfter, _) = error {
                    // The cluster named its own delay; honor it exactly.
                    guard await waitBeforeReconnect(seconds: retryAfter) else { return }
                    continue
                }
            } catch {
                failure = .streamInterrupted(underlying: String(describing: error))
            }

            guard await waitBeforeReconnect(seconds: nil) else { return }
        }

        finish(with: nil)
    }

    /// Pages through the collection, then publishes it as live.
    private func listAll() async throws {
        var options = listOptions
        options.continueToken = nil
        options.resourceVersion = nil

        var collected: [String: Object] = [:]
        var version: String?

        while true {
            let page = try await client.list(resource, namespace: namespace, options: options, as: Object.self)
            for object in page.items { collected[Self.key(for: object)] = object }
            version = page.resourceVersion ?? version
            guard let token = page.continueToken, !token.isEmpty else { break }
            options.continueToken = token
        }

        objects = collected
        resourceVersion = version
        reconnectAttempt = 0
        failure = nil
        markLive()
        emit()
    }

    private enum WatchOutcome {
        /// `410 Gone`: the stored `resourceVersion` is no longer usable.
        case expired
        /// The server closed the watch, as it does when its own timeout elapses.
        case closed
    }

    private func consumeWatch() async throws -> WatchOutcome {
        var options = listOptions
        options.limit = nil
        options.continueToken = nil
        options.resourceVersion = resourceVersion

        let events = try await client.watch(resource, namespace: namespace, options: options, as: Object.self)

        for try await event in events {
            // Any event proves the connection works, so the backoff starts over.
            reconnectAttempt = 0
            failure = nil

            switch event {
            case .added(let object), .modified(let object):
                objects[Self.key(for: object)] = object
                advance(to: object.resourceVersion)
            case .deleted(let object):
                objects.removeValue(forKey: Self.key(for: object))
                advance(to: object.resourceVersion)
            case .bookmark(let version):
                // A bookmark carries no object; its whole purpose is to move the
                // version forward so a quiet collection does not expire.
                resourceVersion = version
            case .resourceVersionExpired:
                return .expired
            }

            markLive()
            emit()
        }

        return .closed
    }

    /// Counts a reconnect, publishes the resulting freshness, and waits. Returns
    /// `false` when the policy says to stop trying, which ends the loop.
    private func waitBeforeReconnect(seconds: TimeInterval?) async -> Bool {
        guard !Task.isCancelled else {
            finish(with: nil)
            return false
        }
        guard retryPolicy.shouldRetry(attempt: reconnectAttempt) else {
            finish(with: failure)
            return false
        }

        reconnectAttempt += 1
        if disconnectedSince == nil { disconnectedSince = Date() }
        liveSince = nil
        emit()

        do {
            try await sleep(seconds ?? retryPolicy.delay(forAttempt: reconnectAttempt))
        } catch {
            finish(with: nil)
            return false
        }
        return !Task.isCancelled
    }

    // MARK: - State

    private func discardCache() {
        objects.removeAll()
        resourceVersion = nil
    }

    private func advance(to version: String?) {
        guard let version, !version.isEmpty else { return }
        resourceVersion = version
    }

    private func markLive() {
        let now = Date()
        lastConfirmed = now
        disconnectedSince = nil
        if liveSince == nil { liveSince = now }
    }

    private func freshness() -> DataFreshness {
        if let liveSince { return .live(since: liveSince) }
        let since = disconnectedSince ?? Date()
        guard !objects.isEmpty, let lastConfirmed else { return .disconnected(since: since) }
        guard !hasGivenUp, reconnectAttempt <= reconnectsBeforeStale else {
            return .stale(lastUpdated: lastConfirmed)
        }
        return .reconnecting(since: since, attempt: reconnectAttempt)
    }

    private func emit() {
        guard let continuation else { return }
        publishedSnapshots += 1
        continuation.yield(
            ResourceSnapshot(
                objects: objects.values.sorted {
                    ($0.namespace ?? "", $0.name) < ($1.namespace ?? "", $1.name)
                },
                resourceVersion: resourceVersion,
                freshness: freshness(),
                failure: failure
            )
        )
    }

    /// Publishes the last state and closes. Used both when giving up and when the
    /// consumer went away, so no path leaves the run task alive.
    private func finish(with error: KubernetesError?) {
        if let error { failure = error }
        hasGivenUp = true
        liveSince = nil
        if disconnectedSince == nil { disconnectedSince = Date() }
        if failure != nil || !Task.isCancelled { emit() }
        runTask = nil
        continuation?.finish()
        continuation = nil
    }

    /// Retrying these cannot help without the user doing something first, so the
    /// watcher stops instead of reconnecting against a wall.
    private func isTerminal(_ error: KubernetesError) -> Bool {
        switch error {
        case .permissionDenied, .unauthenticated, .notFound, .invalidConfiguration,
             .invalidRequest, .unsupportedAuthentication, .decodingFailure, .tlsTrustFailure:
            return true
        case .networkUnreachable, .throttled, .streamInterrupted, .conflict,
             .resourceVersionExpired, .serverError:
            return false
        }
    }

    /// Identity across a delete and a recreate: the UID when the server gave one,
    /// and the namespaced name otherwise.
    private static func key(for object: Object) -> String {
        object.metadata.uid ?? "\(object.namespace ?? "")/\(object.name)"
    }
}
