import Foundation
import Testing
import KubeModels
import KubeTestSupport
@testable import KubeKit

@Suite("Pod logs")
struct PodLogSessionTests {
    private let target = PodLogTarget(namespace: "default", pod: "api-123", container: "web")

    @Test func boundedRingPreservesIdentityAndReportsEviction() {
        var buffer = LogBuffer(maximumLines: 2, maximumBytes: 8)
        buffer.append(timestamp: nil, text: "one")
        buffer.append(timestamp: nil, text: "two")
        buffer.append(timestamp: nil, text: "three")
        #expect(buffer.lines.map(\.text) == ["two", "three"])
        #expect(buffer.lines.map(\.id) == [1, 2])
        #expect(buffer.droppedLineCount == 1)
        buffer.append(timestamp: nil, text: "sixsix")
        #expect(buffer.lines.map(\.text) == ["sixsix"])
        #expect(buffer.droppedLineCount == 3)
        buffer.append(timestamp: nil, text: String(repeating: "x", count: 20))
        #expect(buffer.lines.map(\.text) == ["sixsix"])
        #expect(buffer.droppedLineCount == 4)
    }

    @Test func optionsKeepTimestampsAndBoundInitialWindow() {
        let request = PodLogOptions(previous: true, tailLines: 99_999).request(for: target, resumingFrom: nil)
        #expect(request.path == "/api/v1/namespaces/default/pods/api-123/log")
        #expect(request.queryItems.contains(URLQueryItem(name: "container", value: "web")))
        #expect(request.queryItems.contains(URLQueryItem(name: "follow", value: "false")))
        #expect(request.queryItems.contains(URLQueryItem(name: "previous", value: "true")))
        #expect(request.queryItems.contains(URLQueryItem(name: "tailLines", value: "10000")))
        #expect(request.queryItems.contains(URLQueryItem(name: "timestamps", value: "true")))
        #expect(request.maximumLineLength == 8192)
        #expect(request.timeout == nil)
    }

    @Test func completedReadPreservesCarriageReturnsAndUnmaskedText() async throws {
        let transport = StubTransport(streamLines: [[Data("2026-10-19T01:02:03.123456789Z secret=hello\rprogress".utf8)]])
        let session = PodLogSession(client: KubernetesClient(transport: transport), target: target, options: .init(follow: false))
        var last: LogSnapshot?
        for await snapshot in await session.snapshots() { last = snapshot }
        let snapshot = try #require(last)
        #expect(snapshot.state == .ended)
        #expect(snapshot.lines.first?.text == "secret=hello\rprogress")
        #expect(!snapshot.freshness.isLive)
        #expect(await session.isRunning == false)
    }

    @Test func reconnectUsesTimestampAndOnlySuppressesReplayedOccurrences() async throws {
        let stamp = "2026-10-19T01:02:03.123456789Z"
        let repeated = Data("\(stamp) repeated".utf8)
        let earlier = Data("2026-10-19T01:02:03.000000001Z earlier-in-second".utf8)
        let transport = StubTransport(streams: [
            .lines([earlier, repeated, repeated]),
            .linesThenHoldOpen([earlier, repeated, repeated, repeated, Data("2026-10-19T01:02:04Z new".utf8)]),
        ])
        let session = PodLogSession(client: KubernetesClient(transport: transport), target: target, sleep: { _ in })
        var last: LogSnapshot?
        for await snapshot in await session.snapshots() {
            last = snapshot
            if snapshot.lines.last?.text == "new" { break }
        }
        await session.stop()
        #expect(try #require(last).lines.map(\.text) == ["earlier-in-second", "repeated", "repeated", "repeated", "new"])
        let requests = await transport.sentRequests
        #expect(requests.count == 2)
        #expect(requests[1].queryItems.contains(URLQueryItem(name: "sinceTime", value: stamp)))
        #expect(!requests[1].queryItems.contains { $0.name == "tailLines" })
    }

    @Test func denialIsTerminalAndExplicit() async throws {
        let transport = StubTransport(streams: [.failure(KubernetesError.permissionDenied(status: nil))])
        let session = PodLogSession(client: KubernetesClient(transport: transport), target: target)
        var last: LogSnapshot?
        for await snapshot in await session.snapshots() { last = snapshot }
        #expect(try #require(last).failure == .permissionDenied(status: nil))
        #expect(last?.state == .interrupted)
        #expect(await transport.sentRequests.count == 1)
    }

    @Test func replacementCannotBeStoppedByOldConsumer() async {
        let transport = StubTransport(streams: [.linesThenHoldOpen([]), .linesThenHoldOpen([])])
        let session = PodLogSession(client: KubernetesClient(transport: transport), target: target)
        let old = await session.snapshots()
        let next = await session.snapshots()
        for await _ in old { }
        for _ in 0..<20 { await Task.yield() }
        #expect(await session.isRunning)
        await session.stop()
        for await _ in next { }
        #expect(await session.isRunning == false)
    }

    @Test func cancellationAtConnectionOrBackoffFinishesTheConsumer() async throws {
        for error: any Error in [CancellationError(), KubernetesError.networkUnreachable(underlying: "offline")] {
            let transport = StubTransport(streams: [.failure(error)])
            let session = PodLogSession(client: KubernetesClient(transport: transport), target: target,
                                        sleep: { _ in throw CancellationError() })
            var last: LogSnapshot?
            for await snapshot in await session.snapshots() { last = snapshot }
            #expect(last?.state == .stopped)
            #expect(last?.failure == nil)
            #expect(await session.isRunning == false)
        }
    }
}
