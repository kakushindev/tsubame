import Foundation
import KubeModels

/// How often a connection may poll, across every view that is polling.
///
/// PRD §9.3 allows polling only as a rate-limited fallback. The limit has to be per
/// connection rather than per watcher, because a dozen open views each politely
/// polling every fifteen seconds is not polite to the API server.
public actor PollingBudget {
    private let maximumRequestsPerMinute: Int
    private var recentRequests: [Date] = []
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        maximumRequestsPerMinute: Int = 20,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.maximumRequestsPerMinute = maximumRequestsPerMinute
        self.now = now
        self.sleep = sleep
    }

    /// Waits until another request is allowed, then records it.
    func acquire() async {
        while true {
            let cutoff = now().addingTimeInterval(-60)
            recentRequests.removeAll { $0 < cutoff }
            guard recentRequests.count >= maximumRequestsPerMinute,
                  let oldest = recentRequests.first
            else {
                recentRequests.append(now())
                return
            }
            let wait = max(0.1, 60 - now().timeIntervalSince(oldest))
            guard (try? await sleep(wait)) != nil else { return }
        }
    }

    var requestCount: Int { recentRequests.count }
}

/// Keeps a collection current by relisting, for resources the server will not watch.
///
/// Publishes the same `ResourceSnapshot` a `ResourceWatcher` does, so the browse
/// layer cannot tell the difference — except through `DataFreshness.polling`, which
/// it must show, because this is not a live view.
public actor PollingResourceWatcher<Object: ResourceObject & Codable> {
    private let client: KubernetesClient
    private let resource: GroupVersionResource
    private let namespace: String?
    private let listOptions: ListOptions
    private let interval: TimeInterval
    private let budget: PollingBudget
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var runTask: Task<Void, Never>?
    private var continuation: AsyncStream<ResourceSnapshot<Object>>.Continuation?
    private var objects: [Object] = []
    private var session = 0

    public init(
        client: KubernetesClient,
        resource: GroupVersionResource,
        namespace: String?,
        options: ListOptions = ListOptions(),
        interval: TimeInterval = 15,
        budget: PollingBudget = PollingBudget(),
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.client = client
        self.resource = resource
        self.namespace = namespace
        self.listOptions = options
        self.interval = interval
        self.budget = budget
        self.now = now
        self.sleep = sleep
    }

    public func snapshots() -> AsyncStream<ResourceSnapshot<Object>> {
        session += 1
        let identifier = session
        runTask?.cancel()

        let (stream, continuation) = AsyncStream<ResourceSnapshot<Object>>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop(session: identifier) }
        }
        runTask = Task { await self.run() }
        return stream
    }

    public func stop() { stop(session: session) }

    private func stop(session identifier: Int) {
        guard identifier == session else { return }
        runTask?.cancel()
        runTask = nil
        continuation?.finish()
        continuation = nil
    }

    private func run() async {
        while !Task.isCancelled {
            await budget.acquire()
            guard !Task.isCancelled else { break }
            do {
                try await relist()
            } catch is CancellationError {
                break
            } catch let error as KubernetesError {
                emit(failure: error)
                if case .throttled(let retryAfter, _) = error {
                    // The cluster named its own delay; honor it rather than the
                    // configured interval.
                    guard (try? await sleep(retryAfter)) != nil else { break }
                    continue
                }
            } catch {
                emit(failure: .streamInterrupted(underlying: String(describing: error)))
            }
            guard (try? await sleep(interval)) != nil else { break }
        }
        continuation?.finish()
    }

    private func relist() async throws {
        var options = listOptions
        options.continueToken = nil
        options.resourceVersion = nil

        var collected: [Object] = []
        while true {
            let page = try await client.list(
                resource, namespace: namespace, options: options, as: Object.self
            )
            collected.append(contentsOf: page.items)
            guard let token = page.continueToken, !token.isEmpty else { break }
            options.continueToken = token
            await budget.acquire()
        }
        objects = collected
        continuation?.yield(
            ResourceSnapshot(
                objects: collected,
                resourceVersion: nil,
                freshness: .polling(lastUpdated: now(), interval: interval)
            )
        )
    }

    private func emit(failure: KubernetesError) {
        continuation?.yield(
            ResourceSnapshot(
                objects: objects,
                resourceVersion: nil,
                // A failed poll leaves the last data on screen, marked stale rather
                // than polling: it is no longer being kept current.
                freshness: .stale(lastUpdated: now()),
                failure: failure
            )
        )
    }
}

/// Publishes a polling watcher's snapshots in the erased shape the browse layer uses.
actor ErasedPollingWatcher<Object: ResourceObject & Codable>: ResourceWatching {
    private let watcher: PollingResourceWatcher<Object>
    private let summarize: @Sendable (Object) -> ResourceRowSummary

    init(
        watcher: PollingResourceWatcher<Object>,
        summarize: @escaping @Sendable (Object) -> ResourceRowSummary
    ) {
        self.watcher = watcher
        self.summarize = summarize
    }

    func snapshots() async -> AsyncStream<ErasedResourceSnapshot> {
        let upstream = await watcher.snapshots()
        let summarize = self.summarize
        return AsyncStream { continuation in
            let task = Task {
                for await snapshot in upstream {
                    continuation.yield(
                        ErasedResourceSnapshot(
                            rows: snapshot.objects.map {
                                ErasedResourceSnapshot.Row(
                                    id: $0.id,
                                    object: AnyResourceObject($0),
                                    summary: summarize($0)
                                )
                            },
                            resourceVersion: snapshot.resourceVersion,
                            freshness: snapshot.freshness,
                            failure: snapshot.failure
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop() async { await watcher.stop() }
}
