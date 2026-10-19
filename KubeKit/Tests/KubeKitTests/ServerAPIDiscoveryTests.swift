import Foundation
import Testing
import KubeModels
import KubeTestSupport
@testable import KubeKit

@Suite("ServerAPIDiscovery")
struct ServerAPIDiscoveryTests {
    @Test("Invalidating a context cancels its in-flight discovery request")
    func invalidationCancelsDiscovery() async throws {
        let transport = HoldingDiscoveryTransport()
        let discovery = ServerAPIDiscovery(client: KubernetesClient(transport: transport))
        let load = Task { try await discovery.catalog() }
        while await transport.requestCount == 0 { await Task.yield() }
        await discovery.invalidate()
        await #expect(throws: CancellationError.self) { try await load.value }
    }
    @Test("Maps groups, versions, resources, and subresources from the server")
    func mapsDiscoveryPayloads() async throws {
        let discovery = ServerAPIDiscovery(client: KubernetesClient(transport: Fixtures.transport()))

        let catalog = try await discovery.catalog()

        #expect(catalog.groupNames == ["", "apps", "stable.example.com"])
        #expect(catalog.versions(ofGroup: "stable.example.com") == ["v1", "v1beta1"])
        #expect(catalog.isServed(GroupVersion(group: "apps", version: "v1")))

        let pods = try #require(catalog.resource(forKind: "Pod"))
        #expect(pods.resourceName == "pods")
        #expect(pods.isNamespaced)
        #expect(pods.singularName == "pod")
        #expect(pods.shortNames == ["po"])
        #expect(pods.isWatchable)
        #expect(pods.isDeletable)
        // `pods/log` is a subresource of pods, not a kind of its own.
        #expect(pods.subresources == ["log", "status"])
        #expect(catalog.resource(forKind: "PodLog") == nil)

        let namespaces = try #require(catalog.resource(forName: "ns"))
        #expect(namespaces.kind == "Namespace")
        #expect(namespaces.isNamespaced == false)

        let deployments = try #require(catalog.resource(forKind: "Deployment"))
        #expect(deployments.groupVersion == GroupVersion(group: "apps", version: "v1"))
        #expect(deployments.subresources.contains("scale"))

        #expect(catalog.kinds.map(\.kind) == ["Deployment", "Namespace", "Pod", "Widget", "Widget"])
    }

    @Test("A kind served by two versions resolves to the server's preferred version")
    func prefersThePreferredVersion() async throws {
        let discovery = ServerAPIDiscovery(client: KubernetesClient(transport: Fixtures.transport()))

        let widget = try #require(await discovery.catalog().resource(forKind: "Widget"))

        #expect(widget.groupVersion == GroupVersion(group: "stable.example.com", version: "v1"))
        #expect(widget.isPreferredVersion)
    }

    @Test("The result is cached per cluster and re-read only on an explicit refresh")
    func cachesUntilRefreshed() async throws {
        let transport = Fixtures.transport(repeatedPasses: 2)
        let discovery = ServerAPIDiscovery(client: KubernetesClient(transport: transport))

        _ = try await discovery.catalog()
        let afterFirst = await transport.sentRequests.count
        _ = try await discovery.catalog()
        #expect(await transport.sentRequests.count == afterFirst)

        _ = try await discovery.refresh()
        #expect(await transport.sentRequests.count == afterFirst * 2)
    }

    @Test("Concurrent callers share one discovery pass")
    func sharesOnePass() async throws {
        let transport = Fixtures.transport()
        let discovery = ServerAPIDiscovery(client: KubernetesClient(transport: transport))

        async let first = discovery.catalog()
        async let second = discovery.catalog()
        _ = try await (first, second)

        #expect(await transport.sentRequests.count == Fixtures.requestsPerPass)
    }

    @Test("A group the user may not read is a permission denial, not a missing kind")
    func deniedGroupIsADenial() async throws {
        let transport = Fixtures.transport(deniedGroupVersions: ["stable.example.com/v1", "stable.example.com/v1beta1"])
        let discovery = ServerAPIDiscovery(client: KubernetesClient(transport: transport))

        let catalog = try await discovery.catalog()
        // The group-version is still known to be served; only its contents are not.
        #expect(catalog.isServed(GroupVersion(group: "stable.example.com", version: "v1")))
        #expect(catalog.resource(forKind: "Widget") == nil)
        #expect(
            catalog.failures[GroupVersion(group: "stable.example.com", version: "v1")]
                == .permissionDenied(message: "widgets is forbidden")
        )

        await #expect(throws: KubernetesError.self) {
            _ = try await discovery.resource(forKind: "Widget", inGroup: "stable.example.com")
        }

        do {
            _ = try await discovery.resource(forKind: "Widget", inGroup: "stable.example.com")
            Issue.record("Expected a permission denial.")
        } catch let error as KubernetesError {
            guard case .permissionDenied(let status) = error else {
                Issue.record("Expected permissionDenied, got \(error).")
                return
            }
            #expect(status?.message == "widgets is forbidden")
        }
    }

    @Test("A kind the cluster genuinely does not serve is reported as not found")
    func unservedKindIsNotFound() async throws {
        let discovery = ServerAPIDiscovery(client: KubernetesClient(transport: Fixtures.transport()))

        do {
            _ = try await discovery.resource(forKind: "Sprocket")
            Issue.record("Expected a not-found error.")
        } catch let error as KubernetesError {
            guard case .notFound = error else {
                Issue.record("Expected notFound, got \(error).")
                return
            }
        }
    }

    @Test("One unreachable aggregated group does not blank out the rest of the cluster")
    func oneUnavailableGroupIsRecorded() async throws {
        let transport = Fixtures.transport(unavailableGroupVersions: ["stable.example.com/v1"])
        let discovery = ServerAPIDiscovery(client: KubernetesClient(transport: transport))

        let catalog = try await discovery.catalog()

        #expect(catalog.resource(forKind: "Pod") != nil)
        let failure = try #require(catalog.failures[GroupVersion(group: "stable.example.com", version: "v1")])
        guard case .unavailable = failure else {
            Issue.record("Expected an availability failure, got \(failure).")
            return
        }
        // An outage is not a denial, so a missing kind stays a missing kind.
        #expect(catalog.denial(forKind: "Widget", inGroup: "stable.example.com") == nil)
    }
}

/// The payloads a small cluster returns from `/api`, `/apis`, and each group.
private enum Fixtures {
    /// `/api`, `/api/v1`, `/apis`, and one list per group-version.
    static let requestsPerPass = 6

    static func transport(
        deniedGroupVersions: Set<String> = [],
        unavailableGroupVersions: Set<String> = [],
        repeatedPasses: Int = 1
    ) -> StubTransport {
        var replies: [StubTransport.Reply] = []
        for _ in 0..<repeatedPasses {
            replies.append(.response(.ok(json: apiVersions)))
            replies.append(.response(.ok(json: coreResources)))
            replies.append(.response(.ok(json: groupList)))
            replies.append(.response(.ok(json: appsResources)))
            for version in ["v1", "v1beta1"] {
                let groupVersion = "stable.example.com/\(version)"
                if deniedGroupVersions.contains(groupVersion) {
                    replies.append(.response(.failure(
                        statusCode: 403,
                        reason: "Forbidden",
                        message: "widgets is forbidden"
                    )))
                } else if unavailableGroupVersions.contains(groupVersion) {
                    replies.append(.response(.failure(
                        statusCode: 404,
                        reason: "NotFound",
                        message: "the server could not find the requested resource"
                    )))
                } else {
                    replies.append(.response(.ok(json: widgetResources(version: version))))
                }
            }
        }
        return StubTransport(replies: replies)
    }

    static let apiVersions = #"{"kind":"APIVersions","versions":["v1"]}"#

    static let coreResources = """
    {"kind":"APIResourceList","groupVersion":"v1","resources":[
      {"name":"pods","singularName":"pod","namespaced":true,"kind":"Pod",
       "verbs":["get","list","watch","delete"],"shortNames":["po"]},
      {"name":"pods/log","singularName":"","namespaced":true,"kind":"Pod","verbs":["get"]},
      {"name":"pods/status","singularName":"","namespaced":true,"kind":"Pod","verbs":["get","patch"]},
      {"name":"namespaces","singularName":"namespace","namespaced":false,"kind":"Namespace",
       "verbs":["get","list","watch"],"shortNames":["ns"]}]}
    """

    static let groupList = """
    {"kind":"APIGroupList","groups":[
      {"name":"apps",
       "versions":[{"groupVersion":"apps/v1","version":"v1"}],
       "preferredVersion":{"groupVersion":"apps/v1","version":"v1"}},
      {"name":"stable.example.com",
       "versions":[{"groupVersion":"stable.example.com/v1","version":"v1"},
                   {"groupVersion":"stable.example.com/v1beta1","version":"v1beta1"}],
       "preferredVersion":{"groupVersion":"stable.example.com/v1","version":"v1"}}]}
    """

    static let appsResources = """
    {"kind":"APIResourceList","groupVersion":"apps/v1","resources":[
      {"name":"deployments","singularName":"deployment","namespaced":true,"kind":"Deployment",
       "verbs":["get","list","watch","patch","delete"],"shortNames":["deploy"]},
      {"name":"deployments/scale","singularName":"","namespaced":true,"kind":"Scale",
       "verbs":["get","patch"]}]}
    """

    static func widgetResources(version: String) -> String {
        """
        {"kind":"APIResourceList","groupVersion":"stable.example.com/\(version)","resources":[
          {"name":"widgets","singularName":"widget","namespaced":true,"kind":"Widget",
           "verbs":["get","list","watch"]}]}
        """
    }
}

private actor HoldingDiscoveryTransport: KubernetesTransport {
    private(set) var requestCount = 0
    func send(_ request: APIRequest) async throws -> APIResponse {
        requestCount += 1
        try await Task.sleep(for: .seconds(30))
        throw KubernetesError.networkUnreachable(underlying: "Test transport unexpectedly resumed.")
    }
    func lines(for request: APIRequest) async throws -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
