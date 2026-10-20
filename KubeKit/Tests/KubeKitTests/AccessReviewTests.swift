import Foundation
import Testing
import KubeModels
import KubeTestSupport
@testable import KubeKit

@Suite("Access review")
struct AccessReviewTests {
    private let pods = ResourceAttributes(
        namespace: "default", verb: "delete", version: "v1", resource: "pods"
    )

    private func review(_ json: String) -> StubTransport.Reply { .response(.ok(json: json)) }

    private func answered(allowed: Bool, denied: Bool? = nil,
                          reason: String? = nil, evaluationError: String? = nil) -> String {
        var status = ["\"allowed\":\(allowed)"]
        if let denied { status.append("\"denied\":\(denied)") }
        if let reason { status.append("\"reason\":\"\(reason)\"") }
        if let evaluationError { status.append("\"evaluationError\":\"\(evaluationError)\"") }
        return """
        {"apiVersion":"authorization.k8s.io/v1","kind":"SelfSubjectAccessReview",
         "spec":{"resourceAttributes":{"verb":"delete","resource":"pods"}},
         "status":{\(status.joined(separator: ","))}}
        """
    }

    private let served = StubTransport.Reply.response(.ok(json: """
    {"kind":"APIVersions","versions":["v1"]}
    """))

    /// Discovery that reports the authorization API as present.
    private func reviewer(
        _ replies: [StubTransport.Reply],
        catalog: APIResourceCatalog = APIResourceCatalog(
            groupVersions: [GroupVersion(group: "authorization.k8s.io", version: "v1")],
            resources: []
        )
    ) -> SelfSubjectAccessReviewer {
        let transport = StubTransport(replies: replies)
        return SelfSubjectAccessReviewer(
            client: KubernetesClient(transport: transport),
            discovery: StubDiscovery(catalog: catalog)
        )
    }

    // MARK: - Mapping

    @Test("An allowed review is allowed, a refused one is denied")
    func mapsTheOrdinaryAnswers() async {
        #expect(await reviewer([review(answered(allowed: true))]).decision(for: pods).isAllowed)
        #expect(await reviewer([review(answered(allowed: false, reason: "no policy"))])
            .decision(for: pods).isDenied)
    }

    @Test("An explicit denial wins over allowed")
    func deniedOutranksAllowed() async {
        let decision = await reviewer([review(answered(allowed: true, denied: true))])
            .decision(for: pods)
        #expect(decision.isDenied)
    }

    @Test("Allowed alongside an evaluation error is not allowed")
    func evaluationErrorIsNotAnAnswer() async {
        // A webhook authorizer that errored may have failed open, so the honest
        // answer is that nobody knows — PRD §9.7 forbids promising success here.
        let decision = await reviewer([
            review(answered(allowed: true, evaluationError: "webhook timed out")),
        ]).decision(for: pods)

        #expect(!decision.isAllowed)
        #expect(!decision.isDenied)
        guard case .undetermined(.evaluationError) = decision else {
            Issue.record("expected an evaluation error to be undetermined"); return
        }
    }

    @Test("A cluster that does not serve the API says so, without asking it")
    func unavailableAPIIsNotADenial() async {
        let subject = reviewer([], catalog: APIResourceCatalog(groupVersions: [.core], resources: []))
        let decision = await subject.decision(for: pods)
        guard case .undetermined(.reviewUnavailable) = decision else {
            Issue.record("expected unavailable"); return
        }
        // Undetermined still lets the user try; the cluster refuses it if they
        // may not, and disabling would hide an action they probably have.
        #expect(decision.permitsAttempt)
    }

    @Test("Being refused the question is not being refused the action")
    func forbiddenReviewIsUndetermined() async {
        let subject = reviewer([
            .response(.failure(statusCode: 403, reason: "Forbidden", message: "cannot create reviews")),
        ])
        let decision = await subject.decision(for: pods)
        guard case .undetermined(.reviewForbidden) = decision else {
            Issue.record("expected the refused review to be undetermined, not denied"); return
        }
        #expect(!decision.isDenied)
    }

    @Test("A network failure is undetermined, not a denial")
    func failureIsUndetermined() async {
        let subject = reviewer([.failure(KubernetesError.networkUnreachable(underlying: "offline"))])
        guard case .undetermined(.requestFailed) = await subject.decision(for: pods) else {
            Issue.record("expected a failed request to be undetermined"); return
        }
    }

    // MARK: - Behaviour

    @Test("Only a denial disables an action")
    func onlyDenialBlocks() {
        #expect(AccessDecision.allowed(reason: nil).permitsAttempt)
        #expect(AccessDecision.undetermined(.reviewUnavailable).permitsAttempt)
        #expect(!AccessDecision.denied(reason: nil).permitsAttempt)
    }

    @Test("Answers are cached, so a screen asking twice asks the cluster once")
    func cachesAnswers() async throws {
        let transport = StubTransport(replies: [review(answered(allowed: true))])
        let subject = SelfSubjectAccessReviewer(
            client: KubernetesClient(transport: transport),
            discovery: StubDiscovery(catalog: APIResourceCatalog(
                groupVersions: [GroupVersion(group: "authorization.k8s.io", version: "v1")],
                resources: []
            ))
        )
        #expect(await subject.decision(for: pods).isAllowed)
        #expect(await subject.decision(for: pods).isAllowed)
        // One review POST; the second answer came from the cache.
        #expect(await transport.sentRequests.count == 1)
    }

    @Test("Several permissions are answered together")
    func answersABatch() async {
        let subject = reviewer([
            review(answered(allowed: true)),
            review(answered(allowed: false)),
            review(answered(allowed: true)),
        ])
        let asked = [
            pods,
            ResourceAttributes(namespace: "default", verb: "create", version: "v1", resource: "pods"),
            ResourceAttributes(namespace: "default", verb: "get", version: "v1", resource: "pods",
                               subresource: "log"),
        ]
        let decisions = await subject.decisions(for: asked)
        #expect(decisions.count == 3)
        #expect(asked.allSatisfy { decisions[$0] != nil })
    }

    @Test("An attribute reads as the permission it asks for")
    func describesItself() {
        #expect(pods.displayName == "delete pods")
        #expect(ResourceAttributes(verb: "get", version: "v1", resource: "pods", subresource: "log")
            .displayName == "get pods/log")
        #expect(ResourceAttributes(verb: "patch", group: "apps", version: "v1", resource: "deployments")
            .displayName == "patch deployments.apps")
    }
}

/// Discovery that answers from a fixed catalog.
private struct StubDiscovery: APIDiscovering {
    let catalog: APIResourceCatalog
    func catalog() async throws -> APIResourceCatalog { catalog }
    func refresh() async throws -> APIResourceCatalog { catalog }
    func resource(forKind kind: String, inGroup group: String?) async throws -> DiscoveredResource {
        guard let match = catalog.resource(forKind: kind, inGroup: group) else {
            throw KubernetesError.notFound(status: nil)
        }
        return match
    }
}
