import Foundation
import KubeKit

/// A transport that replays scripted responses.
///
/// Every layer above `KubernetesTransport` is tested through this, so error mapping,
/// paging, discovery, and watch handling are exercised without a cluster.
public actor StubTransport: KubernetesTransport {
    public enum Reply: Sendable {
        case response(APIResponse)
        case failure(any Error)
    }

    /// What one `lines(for:)` call does. The distinction matters to anything that
    /// reconnects: a stream that closes looks like a server-side watch timeout,
    /// while a held-open stream only ends when the consumer cancels.
    public enum StreamReply: Sendable {
        /// Yields the lines, then closes.
        case lines([Data])
        /// Yields the lines, then stays open until the consumer goes away.
        case linesThenHoldOpen([Data])
        /// Fails before any line is delivered, as a non-2xx watch response does.
        case failure(any Error)
    }

    private var replies: [Reply]
    private var streams: [StreamReply]
    private(set) public var sentRequests: [APIRequest] = []
    /// How many streams ended because the consumer terminated them. Proves that
    /// cancelling a watch closes the underlying request.
    private(set) public var terminatedStreams = 0

    public init(replies: [Reply] = [], streamLines: [[Data]] = []) {
        self.replies = replies
        self.streams = streamLines.map { .lines($0) }
    }

    public init(replies: [Reply] = [], streams: [StreamReply]) {
        self.replies = replies
        self.streams = streams
    }

    public func send(_ request: APIRequest) async throws -> APIResponse {
        sentRequests.append(request)
        guard !replies.isEmpty else {
            throw KubernetesError.networkUnreachable(underlying: "StubTransport ran out of replies.")
        }
        switch replies.removeFirst() {
        case .response(let response): return response
        case .failure(let error): throw error
        }
    }

    public func lines(for request: APIRequest) async throws -> AsyncThrowingStream<Data, any Error> {
        sentRequests.append(request)
        let reply = streams.isEmpty ? StreamReply.lines([]) : streams.removeFirst()
        if case .failure(let error) = reply { throw error }

        let lines: [Data]
        let holdsOpen: Bool
        switch reply {
        case .lines(let scripted):
            lines = scripted
            holdsOpen = false
        case .linesThenHoldOpen(let scripted):
            lines = scripted
            holdsOpen = true
        case .failure:
            lines = []
            holdsOpen = false
        }

        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in
                Task { await self.noteStreamTermination() }
            }
            for line in lines { continuation.yield(line) }
            if !holdsOpen { continuation.finish() }
        }
    }

    private func noteStreamTermination() {
        terminatedStreams += 1
    }
}

extension APIResponse {
    /// A 200 carrying a JSON body, the common case in tests.
    public static func ok(json: String) -> APIResponse {
        APIResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(json.utf8)
        )
    }

    /// A failure carrying a `Status` body, the shape the API server actually sends.
    public static func failure(statusCode: Int, reason: String, message: String) -> APIResponse {
        APIResponse(
            statusCode: statusCode,
            headers: [:],
            body: Data(
                """
                {"kind":"Status","apiVersion":"v1","status":"Failure",\
                "code":\(statusCode),"reason":"\(reason)","message":"\(message)"}
                """.utf8
            )
        )
    }
}
