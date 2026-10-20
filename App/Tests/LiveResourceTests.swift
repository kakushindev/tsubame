import Foundation
import Testing
import KubeKit
import KubeModels
@testable import Tsubame

@Suite("Live resource views", .timeLimit(.minutes(1))) @MainActor
struct LiveResourceTests {
    private let resource = DiscoveredResource(
        groupVersionResource: .init(groupVersion: .core, resource: "configmaps", isNamespaced: true),
        kind: "ConfigMap", singularName: "configmap", verbs: ["get", "list", "watch"]
    )

    private func detail(_ transport: LiveViewTransport) -> ResourceDetailModel {
        ResourceDetailModel(client: KubernetesClient(transport: transport),
                            target: WriteTarget(resource: resource, namespace: "default", name: "a"))
    }

    @Test("An open object's metadata and raw YAML follow watch modifications")
    func detailFollowsChanges() async throws {
        let transport = LiveViewTransport(names: ["a", "b"])
        let model = detail(transport)
        let task = Task { await model.run() }
        defer { task.cancel() }
        try await waitUntil { await transport.hasWatch }
        try await transport.emit("MODIFIED", name: "a", version: "2", value: "changed")
        try await waitUntil { model.object?.resourceVersion == "2" }
        #expect(model.yaml.contains("changed"))
        #expect(model.freshness.isLive)
        #expect(model.failure == nil)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.queryItems.contains(URLQueryItem(name: "fieldSelector", value: "metadata.name=a")) })
        #expect(requests.last?.queryItems.contains(URLQueryItem(name: "resourceVersion", value: "1")) == true)
        task.cancel()
        await task.value
        try await waitUntil { await transport.terminated > 0 }
    }

    @Test("A deleted object loses its action payload and a recreation appears live")
    func deleteAndRecreate() async throws {
        let transport = LiveViewTransport(names: ["a"])
        let model = detail(transport)
        let task = Task { await model.run() }
        defer { task.cancel() }
        try await waitUntil { let watching = await transport.hasWatch; return model.object != nil && watching }
        try await transport.emit("DELETED", name: "a", version: "2")
        try await waitUntil { model.object == nil && model.failure != nil }
        #expect(model.failure == "This object no longer exists.")
        try await transport.emit("ADDED", name: "a", version: "3", value: "recreated")
        try await waitUntil { model.object?.resourceVersion == "3" }
        #expect(model.failure == nil)
        #expect(model.yaml.contains("recreated"))
        task.cancel()
        await task.value
    }

    @Test("A watch denial keeps the last object and explicitly stops claiming Live")
    func denialIsVisible() async {
        let transport = LiveViewTransport(names: ["a"], watchFailure: .permissionDenied(status: nil))
        let model = detail(transport)
        await model.run()
        #expect(model.object?.name == "a")
        #expect(model.failure == KubernetesError.permissionDenied(status: nil).localizedDescription)
        #expect(!model.freshness.isLive)
    }

    @Test("Foreground resume relists and does not leave the old watch running")
    func pauseAndResume() async throws {
        let transport = LiveViewTransport(names: ["a"])
        let model = detail(transport)
        let first = Task { await model.run() }
        defer { first.cancel() }
        try await waitUntil { let watching = await transport.hasWatch; return model.object != nil && watching }
        first.cancel()
        await first.value
        try await waitUntil { await transport.terminated > 0 }
        model.pause()
        #expect(!model.freshness.isLive)
        await transport.setVersion("9")
        let resumed = Task { await model.run() }
        defer { resumed.cancel() }
        try await waitUntil { model.object?.resourceVersion == "9" }
        #expect(model.freshness.isLive)
        #expect(await transport.requests.filter { !$0.queryItems.contains { $0.name == "watch" } }.count == 2)
        resumed.cancel()
        await resumed.value
    }

    @Test("Every object in an open list follows updates, additions and deletions")
    func allListObjectsUpdate() async throws {
        let transport = LiveViewTransport(names: ["a", "b"])
        let model = ResourceListModel(client: KubernetesClient(transport: transport), resource: resource, namespaces: ["default"])
        let task = Task { await model.run() }
        defer { task.cancel() }
        try await waitUntil { let watching = await transport.hasWatch; return model.rows.count == 2 && watching }
        for name in ["a", "b"] {
            try await transport.emit("MODIFIED", name: name, version: "2", value: "updated-\(name)")
            try await waitUntil { model.snapshot?.rows.first { $0.name == name }?.object.resourceVersion == "2" }
        }
        try await transport.emit("ADDED", name: "c", version: "3")
        try await waitUntil { model.rows.count == 3 }
        try await transport.emit("DELETED", name: "b", version: "4")
        try await waitUntil { model.rows.map(\.name) == ["a", "c"] }
        #expect(model.snapshot?.freshness.isLive == true)
        task.cancel()
        await task.value
        try await waitUntil { await transport.terminated > 0 }
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The live resource state did not arrive")
        throw WaitExpired()
    }
    private struct WaitExpired: Error {}
}

/// Synthetic payloads stay in memory; no real resource or credential is used.
private actor LiveViewTransport: KubernetesTransport {
    let names: [String]
    let watchFailure: KubernetesError?
    private var version = "1"
    private var output: AsyncThrowingStream<Data, any Error>.Continuation?
    private(set) var requests: [APIRequest] = []
    private(set) var terminated = 0
    var hasWatch: Bool { output != nil }

    init(names: [String], watchFailure: KubernetesError? = nil) {
        self.names = names
        self.watchFailure = watchFailure
    }

    func setVersion(_ value: String) { version = value }

    func send(_ request: APIRequest) async throws -> APIResponse {
        requests.append(request)
        let selector = request.queryItems.first { $0.name == "fieldSelector" }?.value
        let selected = names.filter { selector == nil || selector == "metadata.name=\($0)" }
        let list: JSONValue = .object([
            "apiVersion": .string("v1"), "kind": .string("ConfigMapList"),
            "metadata": .object(["resourceVersion": .string(version)]),
            "items": .array(selected.map { Self.object($0, version: version, value: "initial") }),
        ])
        return APIResponse(statusCode: 200, headers: [:], body: try JSONEncoder().encode(list))
    }

    func lines(for request: APIRequest) async throws -> AsyncThrowingStream<Data, any Error> {
        requests.append(request)
        if let watchFailure { throw watchFailure }
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        output = continuation
        continuation.onTermination = { _ in Task { await self.didTerminate() } }
        return stream
    }

    func emit(_ type: String, name: String, version: String, value: String = "value") throws {
        let event: JSONValue = .object(["type": .string(type), "object": Self.object(name, version: version, value: value)])
        output?.yield(try JSONEncoder().encode(event))
    }

    private func didTerminate() { terminated += 1; output = nil }

    private static func object(_ name: String, version: String, value: String) -> JSONValue {
        .object([
            "apiVersion": .string("v1"), "kind": .string("ConfigMap"),
            "metadata": .object(["name": .string(name), "namespace": .string("default"),
                                  "uid": .string("uid-\(name)"), "resourceVersion": .string(version)]),
            "data": .object(["value": .string(value)]),
        ])
    }
}
