import Foundation
import Testing
import KubeModels
import KubeTestSupport
@testable import KubeKit

@Suite("Deliberate writes")
struct ResourceWriterTests {
    private let resource = DiscoveredResource(
        groupVersionResource: .init(groupVersion: .init(group: "apps", version: "v1"), resource: "deployments", isNamespaced: true),
        kind: "Deployment", singularName: "deployment", verbs: ["patch", "delete"], subresources: ["scale"]
    )
    private var target: WriteTarget { WriteTarget(resource: resource, namespace: "default", name: "api") }
    private let manifest = """
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: api
      namespace: default
    spec:
      replicas: 2
      arbitraryNumber: 1.0
    """
    private func proposal(replicas: Int = 2, version: String = "1") -> APIResponse {
        .ok(json: """
        {"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"api","namespace":"default","resourceVersion":"\(version)"},"spec":{"replicas":\(replicas)}}
        """)
    }

    @Test func liveRequestDiffersOnlyByDryRunFlagAndPreservesSourceBytes() async throws {
        let transport = StubTransport(replies: [.response(proposal()), .response(proposal(version: "2")), .response(proposal(version: "3"))])
        let writer = ResourceWriter(client: KubernetesClient(transport: transport))
        let plan = try writer.plan(.apply(manifest: manifest), target: target)
        let rehearsal = try await writer.rehearse(plan)
        #expect(await transport.sentRequests.count == 1, "Review itself never writes live")
        _ = try await writer.commit(rehearsal)
        let requests = await transport.sentRequests
        #expect(requests.count == 3)
        #expect(requests[0] == requests[2].dryRun())
        #expect(requests[1] == requests[0])
        #expect(requests[2].body == Data(manifest.utf8))
        #expect(requests[2].headers["Content-Type"] == "application/apply-patch+yaml")
        #expect(requests[2].queryItems == [URLQueryItem(name: "fieldManager", value: "tsubame")])
        #expect(requests.allSatisfy { !$0.queryItems.contains { $0.name == "force" } })
    }

    @Test func changedProposalRequiresAnotherReviewWithoutLiveWrite() async throws {
        let transport = StubTransport(replies: [.response(proposal()), .response(proposal(replicas: 5))])
        let writer = ResourceWriter(client: KubernetesClient(transport: transport))
        let reviewed = try await writer.rehearse(writer.plan(.apply(manifest: manifest), target: target))
        do {
            _ = try await writer.commit(reviewed)
            Issue.record("A changed result must return to review")
        } catch WriteError.changedSinceRehearsal(let next) {
            #expect(next.proposed["spec", "replicas"]?.integerValue == 5)
        }
        #expect(await transport.sentRequests.count == 2)
    }

    @Test func conflictNeverBecomesAnEmptyConflictList() async throws {
        let transport = StubTransport(replies: [.response(.failure(statusCode: 409, reason: "Conflict", message: "unknown server wording"))])
        let writer = ResourceWriter(client: KubernetesClient(transport: transport))
        do {
            _ = try await writer.rehearse(writer.plan(.apply(manifest: manifest), target: target))
            Issue.record("Conflict must block review")
        } catch WriteError.fieldOwnershipConflict(let conflicts) {
            #expect(conflicts.count == 1)
            #expect(conflicts[0].rawMessage == "unknown server wording")
        }
    }

    @Test func rejectsWrongTargetWithoutNetwork() throws {
        let writer = ResourceWriter(client: KubernetesClient(transport: StubTransport()))
        #expect(throws: (any Error).self) { try writer.plan(.apply(manifest: manifest.replacingOccurrences(of: "name: api", with: "name: other")), target: target) }
        #expect(throws: (any Error).self) { try writer.plan(.scale(replicas: -1, resourceVersion: "1"), target: target) }
        #expect(throws: (any Error).self) { try writer.plan(.delete(uid: "", resourceVersion: "1"), target: target) }
    }

    @Test func rehearsalCannotCrossClusterBoundary() async throws {
        let transport = StubTransport(replies: [.response(proposal())])
        let first = ResourceWriter(client: KubernetesClient(transport: transport))
        let other = ResourceWriter(client: KubernetesClient(transport: transport))
        let rehearsal = try await first.rehearse(first.plan(.apply(manifest: manifest), target: target))
        await #expect(throws: (any Error).self) { try await other.commit(rehearsal) }
        #expect(await transport.sentRequests.count == 1)
    }

    @Test func actionRequestsUseTheCorrectSubresourceAndPreconditions() async throws {
        let transport = StubTransport(replies: Array(repeating: .response(proposal()), count: 3))
        let writer = ResourceWriter(client: KubernetesClient(transport: transport))
        _ = try await writer.rehearse(writer.plan(.delete(uid: "uid-123", resourceVersion: "7"), target: target))
        _ = try await writer.rehearse(writer.plan(.restart(at: Date(timeIntervalSince1970: 0)), target: target))
        _ = try await writer.rehearse(writer.plan(.scale(replicas: 4, resourceVersion: "7"), target: target))
        let requests = await transport.sentRequests
        let delete = try JSONDecoder().decode(JSONValue.self, from: #require(requests[0].body))
        #expect(delete["preconditions", "uid"]?.stringValue == "uid-123")
        let restart = try JSONDecoder().decode(JSONValue.self, from: #require(requests[1].body))
        #expect(restart["spec", "template", "metadata", "annotations", "kubectl.kubernetes.io/restartedAt"] != nil)
        #expect(requests[2].path.hasSuffix("/deployments/api/scale"))
        #expect(requests[2].headers["Content-Type"] == "application/merge-patch+json")
    }

    @Test func warningsAreIncludedInReview() async throws {
        let response = APIResponse(statusCode: 200, headers: ["warning": "299 admission warning"], body: proposal().body)
        let transport = StubTransport(replies: [.response(response)])
        let writer = ResourceWriter(client: KubernetesClient(transport: transport))
        let rehearsal = try await writer.rehearse(writer.plan(.apply(manifest: manifest), target: target))
        #expect(rehearsal.warnings == ["299 admission warning"])
    }
}

@Suite("Manifest parsing and diffs")
struct ManifestParserTests {
    @Test func numericAndUnknownFieldsArePreserved() throws {
        let parser = ManifestParser()
        let parsed = try parser.parse("{spec: {number: 1.0, exponent: 1e3, large: 9223372036854775807, text: 'true'}, data: {password: unmasked}}")
        #expect(parsed["spec", "number"] == .number(1.0))
        #expect(parsed["spec", "exponent"] == .number(1000))
        #expect(parsed["spec", "large"] == .integer(Int.max))
        #expect(parsed["spec", "text"] == .string("true"))
        #expect(try parser.parse(parser.yaml(from: parsed)) == parsed)
    }

    @Test(arguments: ["a: 1\na: 2", "a: [", "a: 1\n---\nb: 2", "- array", "a: .inf"])
    func invalidManifestsFailWithoutEchoingContent(_ text: String) {
        #expect(throws: ManifestError.self) { try ManifestParser().parse(text) }
    }

    @Test func stableOutputAndVisibleUnmaskedDiff() throws {
        let parser = ManifestParser()
        let before = try parser.parse("kind: Secret\napiVersion: v1\nmetadata: {name: example}\ndata: {password: abc}")
        let after = try parser.parse("apiVersion: v1\nkind: Secret\nmetadata: {name: example}\ndata: {password: xyz}")
        let yaml = try parser.yaml(from: before)
        #expect(yaml.hasPrefix("apiVersion:"))
        let diff = try ResourceDiff.between(before, after)
        #expect(diff.contains { $0.change == .removed && $0.text.contains("abc") })
        #expect(diff.contains { $0.change == .added && $0.text.contains("xyz") })
    }

    @Test func reviewIgnoresOnlyServerOwnedRootFields() throws {
        let parser = ManifestParser()
        let before = try parser.parse("metadata: {name: x, resourceVersion: '1'}\nstatus: {ready: true}\nspec: {status: a}")
        let after = try parser.parse("metadata: {name: x, resourceVersion: '2'}\nstatus: {ready: false}\nspec: {status: a}")
        #expect(ResourceDiff.reviewValue(before) == ResourceDiff.reviewValue(after))
        let changed = try parser.parse("metadata: {name: x}\nspec: {status: b}")
        #expect(ResourceDiff.reviewValue(before) != ResourceDiff.reviewValue(changed))
    }
}
