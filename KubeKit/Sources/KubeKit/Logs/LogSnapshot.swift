import Foundation
import KubeModels

/// Content stays in memory. Neither this type nor its snapshot is a diagnostic payload.
public struct LogLine: Hashable, Sendable, Identifiable {
    public let id: UInt64
    public let timestamp: String?
    public let text: String
}

public struct LogSnapshot: Sendable {
    public enum State: Hashable, Sendable {
        case connecting, streaming, interrupted, stopped, ended
    }

    public let lines: [LogLine]
    public let droppedLineCount: Int
    public let freshness: DataFreshness
    public let state: State
    public let failure: KubernetesError?
}

/// A ring limits both row count and total UTF-8 bytes, including timestamp overhead.
struct LogBuffer: Sendable {
    private var storage: [LogLine?]
    private var head = 0
    private var count = 0
    private var bytes = 0
    private var nextID: UInt64 = 0
    private let maximumBytes: Int
    private(set) var droppedLineCount = 0

    init(maximumLines: Int, maximumBytes: Int) {
        storage = Array(repeating: nil, count: max(1, maximumLines))
        self.maximumBytes = max(1, maximumBytes)
    }

    var lines: [LogLine] {
        (0..<count).compactMap { storage[(head + $0) % storage.count] }
    }

    mutating func append(timestamp: String?, text: String) {
        let cost = text.utf8.count + (timestamp?.utf8.count ?? 0)
        // A line too large for the whole buffer cannot evict useful history.
        guard cost <= maximumBytes else { droppedLineCount += 1; return }
        while count == storage.count || bytes + cost > maximumBytes { removeFirst() }
        storage[(head + count) % storage.count] = LogLine(id: nextID, timestamp: timestamp, text: text)
        nextID += 1
        count += 1
        bytes += cost
    }

    private mutating func removeFirst() {
        if let line = storage[head] { bytes -= line.text.utf8.count + (line.timestamp?.utf8.count ?? 0) }
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        droppedLineCount += 1
    }
}
