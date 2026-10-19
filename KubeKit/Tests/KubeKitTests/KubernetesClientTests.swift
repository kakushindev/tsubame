import Foundation
import Testing
import KubeModels
import KubeTestSupport
@testable import KubeKit

@Suite("KubernetesClient")
struct KubernetesClientTests {
    private let pods = GroupVersionResource(groupVersion: .core, resource: "pods", isNamespaced: true)

    @Test("Decodes a list page with its continue token and resource version")
    func decodesListPage() async throws {
        let transport = StubTransport(replies: [
            .response(.ok(json: """
            {"apiVersion":"v1","kind":"PodList",
             "metadata":{"resourceVersion":"120","continue":"next-page"},
             "items":[{"apiVersion":"v1","kind":"Pod","metadata":{"name":"api-0","namespace":"prod"}}]}
            """))
        ])
        let client = KubernetesClient(transport: transport)

        let page: ResourceList<GenericResource> = try await client.list(pods, namespace: "prod")

        #expect(page.items.count == 1)
        #expect(page.items[0].name == "api-0")
        #expect(page.resourceVersion == "120")
        #expect(page.continueToken == "next-page")

        let request = try #require(await transport.sentRequests.first)
        #expect(request.path == "/api/v1/namespaces/prod/pods")
        #expect(request.queryItems.contains(URLQueryItem(name: "limit", value: "500")))
    }

    @Test("Surfaces a permission denial instead of an empty list")
    func surfacesPermissionDenial() async throws {
        let transport = StubTransport(replies: [
            .response(APIResponse(
                statusCode: 403,
                headers: [:],
                body: Data(#"{"kind":"Status","code":403,"reason":"Forbidden","message":"denied"}"#.utf8)
            ))
        ])
        let client = KubernetesClient(transport: transport)

        await #expect(throws: KubernetesError.self) {
            let _: ResourceList<GenericResource> = try await client.list(self.pods, namespace: "prod")
        }
    }

    @Test("Turns watch lines into events and reports an expired version")
    func decodesWatchStream() async throws {
        let lines = [
            #"{"type":"ADDED","object":{"apiVersion":"v1","kind":"Pod","metadata":{"name":"api-0","resourceVersion":"1"}}}"#,
            #"{"type":"BOOKMARK","object":{"apiVersion":"v1","kind":"Pod","metadata":{"name":"","resourceVersion":"9"}}}"#,
            #"{"type":"DELETED","object":{"apiVersion":"v1","kind":"Pod","metadata":{"name":"api-0","resourceVersion":"10"}}}"#,
            #"{"type":"ERROR","object":{"kind":"Status","code":410,"reason":"Expired","message":"too old"}}"#,
        ].map { Data($0.utf8) }

        let transport = StubTransport(streamLines: [lines])
        let client = KubernetesClient(transport: transport)

        var received: [WatchEvent<GenericResource>] = []
        let stream = try await client.watch(pods, namespace: "prod", options: ListOptions(), as: GenericResource.self)
        for try await event in stream { received.append(event) }

        #expect(received.count == 4)
        guard case .added(let added) = received[0] else {
            Issue.record("Expected added, got \(received[0])")
            return
        }
        #expect(added.name == "api-0")
        #expect(received[1] == .bookmark(resourceVersion: "9"))
        #expect(received[2].object?.name == "api-0")
        guard case .resourceVersionExpired = received[3] else {
            Issue.record("Expected resourceVersionExpired, got \(received[3])")
            return
        }

        let request = try #require(await transport.sentRequests.first)
        #expect(request.queryItems.contains(URLQueryItem(name: "watch", value: "1")))
        #expect(request.queryItems.contains(URLQueryItem(name: "allowWatchBookmarks", value: "true")))
        #expect(request.timeout == nil)
    }

    @Test("A dry run adds dryRun=All and leaves the original request untouched")
    func dryRunIsSeparateFromLiveRequest() {
        let live = APIRequest(method: .patch, path: "/apis/apps/v1/namespaces/prod/deployments/api")
        let dry = live.dryRun()

        #expect(dry.queryItems.contains(URLQueryItem(name: "dryRun", value: "All")))
        #expect(live.queryItems.isEmpty)
        #expect(dry.path == live.path)
        #expect(dry.method == live.method)
    }
}
