import Foundation
import KubeModels

/// Presents several namespace watches as one collection.
///
/// The Kubernetes API lists one namespace or every namespace; there is no call for
/// "these three". Watching each one and merging is what lets a user hold a few
/// namespaces in view without needing permission to read the whole cluster, which
/// is usually the permission they do not have.
///
/// Merged freshness is the least live of the parts: if one namespace is
/// reconnecting then the collection as a whole is not live, and saying otherwise
/// would present stale rows as current (PRD §9.3).
public actor CompositeResourceWatcher: ResourceWatching {
    private let children: [any ResourceWatching]
    private var runTask: Task<Void, Never>?
    private var continuation: AsyncStream<ErasedResourceSnapshot>.Continuation?
    private var latest: [Int: ErasedResourceSnapshot] = [:]

    public init(children: [any ResourceWatching]) {
        self.children = children
    }

    public func snapshots() async -> AsyncStream<ErasedResourceSnapshot> {
        let (stream, continuation) = AsyncStream<ErasedResourceSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }

        runTask = Task { [children] in
            await withTaskGroup(of: Void.self) { group in
                for (index, child) in children.enumerated() {
                    group.addTask {
                        for await snapshot in await child.snapshots() {
                            await self.merge(snapshot, from: index)
                        }
                    }
                }
            }
            await self.finish()
        }
        return stream
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
        continuation?.finish()
        continuation = nil
        for child in children { await child.stop() }
    }

    private func finish() {
        continuation?.finish()
        continuation = nil
    }

    private func merge(_ snapshot: ErasedResourceSnapshot, from index: Int) {
        latest[index] = snapshot
        let parts = latest.keys.sorted().compactMap { latest[$0] }
        guard !parts.isEmpty else { return }

        continuation?.yield(
            ErasedResourceSnapshot(
                // Rows carry the object's own uid, so concatenating cannot collide
                // across namespaces.
                rows: parts.flatMap(\.rows),
                // A merged collection has no single resource version to resume
                // from; each child keeps its own.
                resourceVersion: nil,
                freshness: Self.leastLive(parts.map(\.freshness)),
                failure: parts.compactMap(\.failure).first,
                undecodableItemCount: parts.reduce(0) { $0 + $1.undecodableItemCount }
            )
        )
    }

    /// The weakest guarantee any part can make.
    static func leastLive(_ values: [DataFreshness]) -> DataFreshness {
        guard let first = values.first else { return .disconnected(since: Date()) }
        return values.dropFirst().reduce(first) { worst, next in
            rank(next) > rank(worst) ? next : worst
        }
    }

    private static func rank(_ freshness: DataFreshness) -> Int {
        switch freshness {
        case .live: 0
        case .polling: 1
        case .reconnecting: 2
        case .stale: 3
        case .disconnected: 4
        }
    }
}
