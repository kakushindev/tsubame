import Foundation
import Testing
import KubeKit
import KubeModels
@testable import Tsubame

@Suite("Cluster discovery deadline") @MainActor
struct ClusterSessionTests {
    private func session(_ transport: DiscoveryDeadlineTransport) -> ClusterSession {
        ClusterSession(
            connection: ClusterConnection(
                displayName: "test", serverURL: URL(string: "https://cluster.example")!,
                contextName: "test", authenticationMethod: .bearerToken,
                credentialReference: .init(account: "test"), tls: .systemDefault
            ),
            client: KubernetesClient(transport: transport), discoveryTimeout: 0.05
        )
    }

    @Test("The deadline cancels the shared request and leaves a retryable failure")
    func timeoutCancelsRequest() async {
        let transport = DiscoveryDeadlineTransport()
        let subject = session(transport)
        await subject.discover()
        #expect(await transport.cancelled)
        #expect(subject.state == .failed)
        #expect(subject.failure?.contains("did not respond") == true)
        #expect(subject.catalog == nil)

        await subject.retry()
        #expect(subject.state == .ready)
        #expect(subject.failure == nil)
    }

    @Test("Switching away cancels discovery without reporting a connection failure")
    func cancellationIsNotFailure() async {
        let transport = DiscoveryDeadlineTransport()
        let subject = session(transport)
        let task = Task { await subject.discover() }
        while await transport.requests == 0 { await Task.yield() }
        task.cancel()
        await task.value
        #expect(await transport.cancelled)
        #expect(subject.failure == nil)
        #expect(subject.catalog == nil)
    }

    @Test("A request cancelled by the network is reported instead of leaving a spinner")
    func unexpectedCancellationIsFailure() async {
        let subject = ClusterSession(
            connection: ClusterConnection(
                displayName: "test", serverURL: URL(string: "https://cluster.example")!,
                contextName: "test", authenticationMethod: .bearerToken,
                credentialReference: .init(account: "test"), tls: .systemDefault
            ),
            client: KubernetesClient(transport: UnexpectedCancellationTransport())
        )
        await subject.discover()
        #expect(subject.state == .failed)
        #expect(subject.failure?.contains("ended before API discovery") == true)
    }
}

private struct UnexpectedCancellationTransport: KubernetesTransport {
    func send(_ request: APIRequest) async throws -> APIResponse { throw CancellationError() }
    func lines(for request: APIRequest) async throws -> AsyncThrowingStream<Data, any Error> { throw CancellationError() }
}

private actor DiscoveryDeadlineTransport: KubernetesTransport {
    private(set) var requests = 0
    private(set) var cancelled = false

    func send(_ request: APIRequest) async throws -> APIResponse {
        requests += 1
        if requests == 1 {
            do { try await Task.sleep(for: .seconds(2)) }
            catch { cancelled = true; throw error }
            throw KubernetesError.networkUnreachable(underlying: "Uncancelled test request")
        }
        let json = request.path == "/api" ? #"{"versions":[]}"# : #"{"groups":[]}"#
        return APIResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }

    func lines(for request: APIRequest) async throws -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
