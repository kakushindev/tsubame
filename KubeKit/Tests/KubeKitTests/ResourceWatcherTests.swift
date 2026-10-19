import Foundation
import Testing
import KubeModels
import KubeTestSupport
@testable import KubeKit

@Suite("ResourceWatcher")
struct ResourceWatcherTests {
    private let pods = GroupVersionResource(groupVersion: .core, resource: "pods", isNamespaced: true)

    @Test("Pages the list, then watches from the list's resource version")
    func listsThenWatches() async throws {
        let transport = StubTransport(
            replies: [
                .response(.ok(json: Fixtures.podList(resourceVersion: "100", names: ["a"], continueToken: "page-2"))),
                .response(.ok(json: Fixtures.podList(resourceVersion: "100", names: ["b"]))),
            ],
            streams: [.linesThenHoldOpen([Fixtures.added(name: "c", resourceVersion: "101")])]
        )
        let watcher = makeWatcher(transport: transport)

        var latest: ResourceSnapshot<GenericResource>?
        for await snapshot in await watcher.snapshots() {
            latest = snapshot
            if snapshot.objects.count == 3 { break }
        }

        let snapshot = try #require(latest)
        #expect(snapshot.objects.map(\.name) == ["a", "b", "c"])
        // Listed items take their type from the list; watched ones carry their own.
        #expect(snapshot.objects.allSatisfy { $0.groupVersionKind.kind == "Pod" })
        #expect(snapshot.resourceVersion == "101")
        #expect(snapshot.isLive)
        #expect(snapshot.failure == nil)

        let requests = await transport.sentRequests
        #expect(requests.count == 3)
        #expect(requests[1].queryItems.contains(URLQueryItem(name: "continue", value: "page-2")))
        let watchRequest = try #require(requests.last)
        #expect(watchRequest.queryItems.contains(URLQueryItem(name: "watch", value: "1")))
        #expect(watchRequest.queryItems.contains(URLQueryItem(name: "resourceVersion", value: "100")))
        // A watch is never paged; `limit` on a watch would truncate the stream.
        #expect(watchRequest.queryItems.contains { $0.name == "limit" } == false)
    }

    @Test("An expired resource version discards the cache and relists exactly once")
    func relistsOnceAfterExpiry() async throws {
        let transport = StubTransport(
            replies: [
                .response(.ok(json: Fixtures.podList(resourceVersion: "100", names: ["a"]))),
                .response(.ok(json: Fixtures.podList(resourceVersion: "200", names: ["b"]))),
            ],
            streams: [
                .lines([Fixtures.expired]),
                .linesThenHoldOpen([]),
            ]
        )
        let watcher = makeWatcher(transport: transport)

        var latest: ResourceSnapshot<GenericResource>?
        for await snapshot in await watcher.snapshots() {
            latest = snapshot
            if snapshot.resourceVersion == "200" { break }
        }

        let snapshot = try #require(latest)
        // The stale object is gone, not merged with the new list.
        #expect(snapshot.objects.map(\.name) == ["b"])
        #expect(snapshot.isLive)

        let listRequests = await transport.sentRequests.filter { request in
            request.queryItems.contains { $0.name == "watch" } == false
        }
        #expect(listRequests.count == 2)
    }

    @Test("A 410 on the watch request itself relists instead of retrying the old version")
    func relistsWhenTheWatchRequestIsRejected() async throws {
        let sleeper = RecordedSleeper()
        let transport = StubTransport(
            replies: [
                .response(.ok(json: Fixtures.podList(resourceVersion: "100", names: ["a"]))),
                .response(.ok(json: Fixtures.podList(resourceVersion: "200", names: ["b"]))),
            ],
            streams: [
                .failure(KubernetesError.resourceVersionExpired(status: nil)),
                .linesThenHoldOpen([]),
            ]
        )
        let watcher = makeWatcher(transport: transport, sleeper: sleeper)

        for await snapshot in await watcher.snapshots() where snapshot.resourceVersion == "200" {
            break
        }

        let listRequests = await transport.sentRequests.filter { request in
            request.queryItems.contains { $0.name == "watch" } == false
        }
        #expect(listRequests.count == 2)
        // Relisting is an instruction from the server, not a failure to back off from.
        #expect(await sleeper.delays.isEmpty)
    }

    @Test("A bookmark advances the version the next watch resumes from")
    func bookmarkAdvancesResourceVersion() async throws {
        let transport = StubTransport(
            replies: [.response(.ok(json: Fixtures.podList(resourceVersion: "100", names: ["a"])))],
            streams: [
                .lines([Fixtures.bookmark(resourceVersion: "150")]),
                .linesThenHoldOpen([]),
            ]
        )
        let watcher = makeWatcher(transport: transport)

        // The watcher is left running while the reconnect happens; the snapshots it
        // publishes in the meantime are drained afterwards.
        let stream = await watcher.snapshots()
        await waitUntil("the watch reconnects") {
            await transport.sentRequests.count == 3
        }
        await watcher.stop()

        var publishedVersions: [String?] = []
        for await snapshot in stream { publishedVersions.append(snapshot.resourceVersion) }
        #expect(publishedVersions.contains("150"))

        let reconnect = try #require(await transport.sentRequests.last)
        #expect(reconnect.queryItems.contains(URLQueryItem(name: "resourceVersion", value: "150")))
        // A bookmark carries no object, so the list itself is unchanged.
        #expect(await transport.sentRequests.filter { $0.queryItems.contains { $0.name == "watch" } }.count == 2)
    }

    @Test("Reconnect backoff is bounded and gives up when the policy says to")
    func backoffIsBounded() async throws {
        let sleeper = RecordedSleeper()
        let policy = RetryPolicy(
            initialDelay: 1,
            maximumDelay: 4,
            multiplier: 2,
            jitterFraction: 0,
            maximumAttempts: 3
        )
        let transport = StubTransport(
            replies: [.response(.ok(json: Fixtures.podList(resourceVersion: "100", names: ["a"])))],
            streams: []
        )
        let watcher = makeWatcher(transport: transport, retryPolicy: policy, sleeper: sleeper)

        var snapshots: [ResourceSnapshot<GenericResource>] = []
        for await snapshot in await watcher.snapshots() { snapshots.append(snapshot) }

        #expect(await sleeper.delays == [1, 2, 4])
        let last = try #require(snapshots.last)
        guard case .stale = last.freshness else {
            Issue.record("Expected stale after giving up, got \(last.freshness).")
            return
        }
        #expect(last.objects.map(\.name) == ["a"])
        #expect(await watcher.isRunning == false)
    }

    @Test("A Retry-After from the cluster replaces the client's own backoff")
    func honorsRetryAfter() async throws {
        let sleeper = RecordedSleeper()
        let transport = StubTransport(
            replies: [.response(.ok(json: Fixtures.podList(resourceVersion: "100", names: ["a"])))],
            streams: [
                .failure(KubernetesError.throttled(retryAfter: 7, status: nil)),
                .linesThenHoldOpen([Fixtures.added(name: "b", resourceVersion: "101")]),
            ]
        )
        let watcher = makeWatcher(transport: transport, sleeper: sleeper)

        for await snapshot in await watcher.snapshots() where snapshot.objects.count == 2 {
            break
        }
        await watcher.stop()

        #expect(await sleeper.delays == [7])
    }

    @Test("Freshness goes live, then reconnecting, then stale — never back to live")
    func freshnessTransitions() async throws {
        let policy = RetryPolicy(jitterFraction: 0, maximumAttempts: 3)
        let transport = StubTransport(
            replies: [.response(.ok(json: Fixtures.podList(resourceVersion: "100", names: ["a"])))],
            streams: []
        )
        let watcher = makeWatcher(
            transport: transport,
            retryPolicy: policy,
            reconnectsBeforeStale: 1,
            sleeper: RecordedSleeper()
        )

        var states: [String] = []
        for await snapshot in await watcher.snapshots() {
            let label: String
            switch snapshot.freshness {
            case .live: label = "live"
            case .reconnecting: label = "reconnecting"
            case .stale: label = "stale"
            case .disconnected: label = "disconnected"
            }
            if states.last != label { states.append(label) }
        }

        #expect(states == ["disconnected", "live", "reconnecting", "stale"])
    }

    @Test("A busy namespace cannot grow the published buffer without limit")
    func bufferStaysBounded() async throws {
        let events = (0..<50).map { Fixtures.added(name: "pod-\($0)", resourceVersion: "\(200 + $0)") }
        let transport = StubTransport(
            replies: [.response(.ok(json: Fixtures.podList(resourceVersion: "100", names: ["a"])))],
            streams: [.linesThenHoldOpen(events)]
        )
        let watcher = makeWatcher(transport: transport, snapshotBufferLimit: 4)

        let stream = await watcher.snapshots()
        // One for the initial state, one for the list, one per event.
        await waitUntil("every event is published") {
            await watcher.publishedSnapshots == 52
        }
        await watcher.stop()

        var received: [ResourceSnapshot<GenericResource>] = []
        for await snapshot in stream { received.append(snapshot) }

        #expect(received.count <= 4)
        // The newest state survives, so a consumer that fell behind still sees every object.
        #expect(try #require(received.last).objects.count == 51)
    }

    @Test("Cancelling the consumer cancels the request and leaves nothing running")
    func cancellationLeavesNothingRunning() async throws {
        let transport = StubTransport(
            replies: [.response(.ok(json: Fixtures.podList(resourceVersion: "100", names: ["a"])))],
            streams: [.linesThenHoldOpen([Fixtures.added(name: "b", resourceVersion: "101")])]
        )
        let watcher = makeWatcher(transport: transport)

        for await snapshot in await watcher.snapshots() where snapshot.objects.count == 2 {
            break
        }

        await waitUntil("the watcher stops") { await watcher.isRunning == false }
        await waitUntil("the open request is closed") { await transport.terminatedStreams == 1 }
        #expect(await watcher.isRunning == false)
        #expect(await transport.terminatedStreams == 1)
        // Nothing reconnected behind the consumer's back.
        #expect(await transport.sentRequests.count == 2)
    }

    @Test("A permission denial stops the watcher and travels with the snapshot")
    func permissionDenialIsCarried() async throws {
        let transport = StubTransport(
            replies: [.response(.failure(statusCode: 403, reason: "Forbidden", message: "pods is forbidden"))]
        )
        let watcher = makeWatcher(transport: transport, sleeper: RecordedSleeper())

        var snapshots: [ResourceSnapshot<GenericResource>] = []
        for await snapshot in await watcher.snapshots() { snapshots.append(snapshot) }

        let last = try #require(snapshots.last)
        guard case .permissionDenied(let status) = try #require(last.failure) else {
            Issue.record("Expected a permission denial, got \(String(describing: last.failure)).")
            return
        }
        #expect(status?.message == "pods is forbidden")
        // A denial is never shown as "no objects, all good".
        #expect(last.isLive == false)
        #expect(await watcher.isRunning == false)
        // Retrying a denial without the user doing something would be a hot loop.
        #expect(await transport.sentRequests.count == 1)
    }

    // MARK: - Harness

    private func makeWatcher(
        transport: StubTransport,
        retryPolicy: RetryPolicy = RetryPolicy(jitterFraction: 0),
        snapshotBufferLimit: Int = 64,
        reconnectsBeforeStale: Int = 3,
        sleeper: RecordedSleeper = RecordedSleeper()
    ) -> ResourceWatcher<GenericResource> {
        ResourceWatcher<GenericResource>(
            client: KubernetesClient(transport: transport),
            resource: pods,
            namespace: "prod",
            options: ListOptions(limit: 2),
            retryPolicy: retryPolicy,
            snapshotBufferLimit: snapshotBufferLimit,
            reconnectsBeforeStale: reconnectsBeforeStale,
            sleep: { await sleeper.record($0) }
        )
    }

    private func waitUntil(_ description: String, condition: @Sendable () async -> Bool) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for \(description).")
    }
}

/// Stands in for the backoff clock, so a bounded-retry test asserts the delays
/// instead of waiting them out.
private actor RecordedSleeper {
    private(set) var delays: [TimeInterval] = []

    func record(_ seconds: TimeInterval) {
        delays.append(seconds)
    }
}

private enum Fixtures {
    static func podList(resourceVersion: String, names: [String], continueToken: String? = nil) -> String {
        // As a real server sends it: the type is on the list, not on the items.
        let items = names.map { name in
            """
            {"metadata":{"name":"\(name)","namespace":"prod",\
            "uid":"uid-\(name)","resourceVersion":"\(resourceVersion)"}}
            """
        }
        let continuation = continueToken.map { ",\"continue\":\"\($0)\"" } ?? ""
        return """
        {"apiVersion":"v1","kind":"PodList",
         "metadata":{"resourceVersion":"\(resourceVersion)"\(continuation)},
         "items":[\(items.joined(separator: ","))]}
        """
    }

    static func added(name: String, resourceVersion: String) -> Data {
        Data("""
        {"type":"ADDED","object":{"apiVersion":"v1","kind":"Pod","metadata":{"name":"\(name)",\
        "namespace":"prod","uid":"uid-\(name)","resourceVersion":"\(resourceVersion)"}}}
        """.utf8)
    }

    static func bookmark(resourceVersion: String) -> Data {
        Data("""
        {"type":"BOOKMARK","object":{"apiVersion":"v1","kind":"Pod",\
        "metadata":{"name":"","resourceVersion":"\(resourceVersion)"}}}
        """.utf8)
    }

    static let expired = Data(
        #"{"type":"ERROR","object":{"kind":"Status","code":410,"reason":"Expired","message":"too old"}}"#.utf8
    )
}
