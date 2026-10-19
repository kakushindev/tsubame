import Foundation
import Testing
import KubeModels
@testable import KubeKit

@Suite("CompositeResourceWatcher")
struct CompositeResourceWatcherTests {
    private func snapshot(
        _ names: [String], freshness: DataFreshness = .live(since: .now),
        failure: KubernetesError? = nil, undecodable: Int = 0
    ) -> ErasedResourceSnapshot {
        ErasedResourceSnapshot(
            rows: names.map {
                ErasedResourceSnapshot.Row(
                    id: $0,
                    object: AnyResourceObject(GenericResource(
                        groupVersionKind: GroupVersionKind(apiVersion: "v1", kind: "Pod"),
                        metadata: ObjectMeta(name: $0), raw: .object([:])
                    )),
                    summary: ResourceRowSummary(headline: "Running")
                )
            },
            resourceVersion: "1", freshness: freshness,
            failure: failure, undecodableItemCount: undecodable
        )
    }

    @Test("Rows from every namespace appear together")
    func mergesRows() async throws {
        let composite = CompositeResourceWatcher(children: [
            FixedWatcher(snapshot(["a", "b"])),
            FixedWatcher(snapshot(["c"])),
        ])
        var seen: Set<String> = []
        for await merged in await composite.snapshots() {
            seen.formUnion(merged.rows.map(\.id))
            if seen.count == 3 { break }
        }
        #expect(seen == ["a", "b", "c"])
        await composite.stop()
    }

    @Test("The merged collection is only as live as its least live part")
    func freshnessIsTheWeakestGuarantee() {
        // One namespace reconnecting means the table is not live, and saying it is
        // would present rows that may already be wrong as current.
        #expect(CompositeResourceWatcher.leastLive([
            .live(since: .now), .reconnecting(since: .now, attempt: 1),
        ]).isLive == false)

        #expect(CompositeResourceWatcher.leastLive([
            .live(since: .now), .live(since: .now),
        ]).isLive)

        // Stale outranks reconnecting; disconnected outranks everything.
        if case .stale = CompositeResourceWatcher.leastLive([
            .reconnecting(since: .now, attempt: 2), .stale(lastUpdated: .now),
        ]) {} else {
            Issue.record("stale is the weaker guarantee")
        }
        if case .disconnected = CompositeResourceWatcher.leastLive([
            .stale(lastUpdated: .now), .disconnected(since: .now),
        ]) {} else {
            Issue.record("disconnected is the weakest")
        }
        // Polling is not live, but it is better than a dropped watch.
        if case .polling = CompositeResourceWatcher.leastLive([
            .live(since: .now), .polling(lastUpdated: .now, interval: 15),
        ]) {} else {
            Issue.record("polling outranks live")
        }
    }

    @Test("A denial in one namespace is carried, not hidden by the others")
    func carriesFailures() async throws {
        let composite = CompositeResourceWatcher(children: [
            FixedWatcher(snapshot(["a"])),
            FixedWatcher(snapshot([], failure: .permissionDenied(status: nil), undecodable: 2)),
        ])
        var carried: KubernetesError?
        var undecodable = 0
        for await merged in await composite.snapshots() {
            if let failure = merged.failure { carried = failure; undecodable = merged.undecodableItemCount; break }
        }
        guard case .permissionDenied = try #require(carried) else {
            Issue.record("expected the denial to survive the merge"); return
        }
        #expect(undecodable == 2)
        await composite.stop()
    }

    @Test("Stopping the composite stops every child")
    func stopsChildren() async throws {
        let children = [FixedWatcher(snapshot(["a"])), FixedWatcher(snapshot(["b"]))]
        let composite = CompositeResourceWatcher(children: children)
        for await _ in await composite.snapshots() { break }
        await composite.stop()
        for child in children { #expect(await child.stopped) }
    }
}

/// Publishes one snapshot and holds the stream open, like a quiet watch.
private actor FixedWatcher: ResourceWatching {
    private let value: ErasedResourceSnapshot
    private(set) var stopped = false
    init(_ value: ErasedResourceSnapshot) { self.value = value }

    func snapshots() async -> AsyncStream<ErasedResourceSnapshot> {
        let value = self.value
        return AsyncStream { continuation in
            continuation.yield(value)
        }
    }

    func stop() async { stopped = true }
}
