import Foundation
import Testing
import KubeModels
import KubeTestSupport
@testable import KubeKit

/// The reliability cases PRD §9.3 and §12 require, and the §8 gate before UI
/// breadth: a watch must survive drops, expiry, duplicates and rapid navigation
/// without losing data, inventing rows, or leaving work behind.
@Suite("Watch reliability")
struct WatchReliabilityTests {
    private let pods = GroupVersionResource(
        groupVersion: .core, resource: "pods", isNamespaced: true
    )

    private func watcher(
        transport: StubTransport,
        retryPolicy: RetryPolicy = RetryPolicy(initialDelay: 1, maximumDelay: 4, jitterFraction: 0),
        reconnectsBeforeStale: Int = 3,
        sleeper: RecordedSleeper = RecordedSleeper()
    ) -> ResourceWatcher<GenericResource> {
        ResourceWatcher<GenericResource>(
            client: KubernetesClient(transport: transport),
            resource: pods,
            namespace: "prod",
            retryPolicy: retryPolicy,
            reconnectsBeforeStale: reconnectsBeforeStale,
            sleep: { [sleeper] in await sleeper.record($0) }
        )
    }

    // MARK: - 3. A 410 arriving as an HTTP failure, not an in-stream event

    @Test("A 410 on the watch request itself relists once and drops the stale object")
    func relistsAfterHTTPExpiry() async throws {
        // The in-stream ERROR form is already covered. This is the other shape: the
        // watch request is refused outright, which a client that only handles the
        // in-stream event would treat as a reconnectable failure and retry forever
        // against a resourceVersion the server has already forgotten.
        let transport = StubTransport(
            replies: [
                .response(.ok(json: Fixtures.podList(resourceVersion: "100", names: ["gone"]))),
                .response(.ok(json: Fixtures.podList(resourceVersion: "300", names: ["fresh"]))),
            ],
            streams: [
                .failure(KubernetesError.resourceVersionExpired(status: nil)),
                .linesThenHoldOpen([]),
            ]
        )
        let watcher = watcher(transport: transport)

        var latest: ResourceSnapshot<GenericResource>?
        for await snapshot in await watcher.snapshots() {
            latest = snapshot
            if snapshot.objects.map(\.name) == ["fresh"] { break }
        }

        let snapshot = try #require(latest)
        // The object from before the expiry must be gone, not merged with the new
        // list: it may have been deleted while we were not watching.
        #expect(snapshot.objects.map(\.name) == ["fresh"])
        #expect(snapshot.resourceVersion == "300")

        let listRequests = await transport.sentRequests.filter {
            !$0.queryItems.contains(URLQueryItem(name: "watch", value: "1"))
        }
        #expect(listRequests.count == 2, "relisted exactly once after the expiry")
    }

    // MARK: - 4. Duplicate and out-of-order events

    @Test("Duplicate and contradictory events leave the collection correct")
    func toleratesDuplicateEvents() async throws {
        let transport = StubTransport(
            replies: [.response(.ok(json: Fixtures.podList(resourceVersion: "100", names: [])))],
            streams: [.linesThenHoldOpen([
                Fixtures.added(name: "a", resourceVersion: "101"),
                // The same ADDED again: a reconnect can replay events.
                Fixtures.added(name: "a", resourceVersion: "101"),
                Fixtures.modified(name: "a", resourceVersion: "102"),
                // ADDED after MODIFIED, which the API does emit on re-sync.
                Fixtures.added(name: "a", resourceVersion: "103"),
                // A DELETED for something never seen must not create a row.
                Fixtures.deleted(name: "ghost", resourceVersion: "104"),
                Fixtures.added(name: "b", resourceVersion: "105"),
            ])]
        )
        let watcher = watcher(transport: transport)

        var latest: ResourceSnapshot<GenericResource>?
        for await snapshot in await watcher.snapshots() {
            latest = snapshot
            if snapshot.objects.count == 2 { break }
        }

        let snapshot = try #require(latest)
        #expect(snapshot.objects.map(\.name) == ["a", "b"], "no duplicate and no phantom row")
        #expect(snapshot.objects.filter { $0.name == "a" }.count == 1)
        // The latest version of the duplicated object wins.
        #expect(snapshot.objects.first { $0.name == "a" }?.metadata.resourceVersion == "103")
    }

    @Test("Deleting an object removes exactly that object")
    func removesDeletedObject() async throws {
        let transport = StubTransport(
            replies: [
                .response(.ok(json: Fixtures.podList(resourceVersion: "100", names: ["a", "b"]))),
            ],
            streams: [.linesThenHoldOpen([Fixtures.deleted(name: "a", resourceVersion: "101")])]
        )
        let watcher = watcher(transport: transport)

        var latest: ResourceSnapshot<GenericResource>?
        for await snapshot in await watcher.snapshots() {
            latest = snapshot
            if snapshot.objects.count == 1 { break }
        }
        #expect(try #require(latest).objects.map(\.name) == ["b"])
    }

    // MARK: - 2. A drop never empties the list

    @Test("A dropped watch keeps the last known objects and marks them stale")
    func dropKeepsObjects() async throws {
        let transport = StubTransport(
            replies: [
                .response(.ok(json: Fixtures.podList(resourceVersion: "100", names: ["a", "b"]))),
            ],
            streams: [
                .failure(KubernetesError.networkUnreachable(underlying: "offline")),
                .failure(KubernetesError.networkUnreachable(underlying: "offline")),
                .failure(KubernetesError.networkUnreachable(underlying: "offline")),
            ]
        )
        let watcher = watcher(transport: transport, reconnectsBeforeStale: 1)

        var sawStaleWithObjects = false
        for await snapshot in await watcher.snapshots() {
            if case .stale = snapshot.freshness, snapshot.objects.count == 2 {
                sawStaleWithObjects = true
                break
            }
        }
        // PRD §12: a drop must never be rendered as "this namespace is empty".
        #expect(sawStaleWithObjects)
    }

    @Test("A permission denial is carried on the snapshot, never shown as empty")
    func denialIsCarriedNotEmptied() async throws {
        let transport = StubTransport(
            replies: [
                .response(.failure(
                    statusCode: 403, reason: "Forbidden",
                    message: "pods is forbidden: User cannot list resource \\\"pods\\\""
                )),
            ],
            streams: []
        )
        let watcher = watcher(transport: transport)

        var failure: KubernetesError?
        for await snapshot in await watcher.snapshots() {
            if let carried = snapshot.failure { failure = carried; break }
        }
        guard case .permissionDenied = try #require(failure) else {
            Issue.record("a 403 must surface as a denial the UI can name")
            return
        }
    }

    // MARK: - 5. Rapid navigation leaves nothing running

    @Test("Opening and abandoning many watches closes every request")
    func rapidNavigationLeavesNothingBehind() async throws {
        // The case that catches an asynchronous teardown window: a user flicking
        // through kinds opens and abandons a watch per tap, and every one of them
        // must close its socket.
        let rounds = 50
        for _ in 0..<rounds {
            let transport = StubTransport(
                replies: [
                    .response(.ok(json: Fixtures.podList(resourceVersion: "1", names: ["a"]))),
                ],
                streams: [.linesThenHoldOpen([])]
            )
            let watcher = watcher(transport: transport)

            // Consume past the list snapshot so the watch request is actually open;
            // breaking on the first one would abandon the watcher before it ever
            // reached the stream, which proves nothing about closing it.
            for await snapshot in await watcher.snapshots() where snapshot.isLive { break }

            await watcher.stop()
            #expect(await watcher.isRunning == false, "no loop left running")
            // At most one stream was ever opened, and nothing is still holding it.
            #expect(await transport.terminatedStreams <= 1)
        }
    }

    @Test("Stopping a watch twice is harmless")
    func stopIsIdempotent() async throws {
        let transport = StubTransport(
            replies: [.response(.ok(json: Fixtures.podList(resourceVersion: "1", names: [])))],
            streams: [.linesThenHoldOpen([])]
        )
        let watcher = watcher(transport: transport)
        for await _ in await watcher.snapshots() { break }
        await watcher.stop()
        await watcher.stop()
        #expect(await watcher.isRunning == false)
    }

    // MARK: - 6. Paging and bounded growth

    @Test("A large collection pages predictably and publishes once")
    func pagesLargeCollections() async throws {
        // 10 pages of 500, the §18 large case in miniature.
        let pageCount = 10
        var replies: [StubTransport.Reply] = []
        for page in 0..<pageCount {
            let names = (0..<500).map { "pod-\(page)-\($0)" }
            replies.append(.response(.ok(json: Fixtures.podList(
                resourceVersion: "100",
                names: names,
                continueToken: page == pageCount - 1 ? nil : "page-\(page + 1)"
            ))))
        }
        let transport = StubTransport(replies: replies, streams: [.linesThenHoldOpen([])])
        let watcher = watcher(transport: transport)

        // The watcher opens with an empty `.disconnected` snapshot before it has
        // listed anything, so count only what it publishes once the list is in.
        var publishedWithObjects = 0
        var total = 0
        for await snapshot in await watcher.snapshots() {
            if !snapshot.objects.isEmpty { publishedWithObjects += 1 }
            if snapshot.isLive {
                total = snapshot.objects.count
                break
            }
        }

        #expect(total == pageCount * 500)
        // One publication for the whole paged list, not one per page: a list that
        // redrew ten times on the way in would be ten redraws of 5,000 rows.
        #expect(publishedWithObjects == 1)
        let listRequests = await transport.sentRequests.filter {
            !$0.queryItems.contains(URLQueryItem(name: "watch", value: "1"))
        }
        #expect(listRequests.count == pageCount)
    }
}

private actor RecordedSleeper {
    private(set) var delays: [TimeInterval] = []
    func record(_ delay: TimeInterval) { delays.append(delay) }
}

private enum Fixtures {
    static func podList(
        resourceVersion: String, names: [String], continueToken: String? = nil
    ) -> String {
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

    static func event(_ type: String, name: String, resourceVersion: String) -> Data {
        Data("""
        {"type":"\(type)","object":{"apiVersion":"v1","kind":"Pod","metadata":{"name":"\(name)",\
        "namespace":"prod","uid":"uid-\(name)","resourceVersion":"\(resourceVersion)"}}}
        """.utf8)
    }

    static func added(name: String, resourceVersion: String) -> Data {
        event("ADDED", name: name, resourceVersion: resourceVersion)
    }
    static func modified(name: String, resourceVersion: String) -> Data {
        event("MODIFIED", name: name, resourceVersion: resourceVersion)
    }
    static func deleted(name: String, resourceVersion: String) -> Data {
        event("DELETED", name: name, resourceVersion: resourceVersion)
    }
}
