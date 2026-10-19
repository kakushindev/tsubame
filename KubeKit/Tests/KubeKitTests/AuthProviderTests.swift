import Foundation
import Testing
import KubeModels
import KubeTestSupport
@testable import KubeKit

@Suite("OIDC credential provider")
struct OIDCProviderTests {
    private let configuration = OIDCConfiguration(
        issuer: URL(string: "https://issuer.example")!,
        clientID: "tsubame",
        redirectURI: URL(string: "dev.kakushin.tsubame://callback")!
    )

    private func metadata() -> StubTransport.Reply {
        .response(.ok(json: """
        {"authorization_endpoint":"https://issuer.example/auth",
         "token_endpoint":"https://issuer.example/token"}
        """))
    }

    private func tokenResponse(
        idToken: String, refresh: String? = "refresh-1", expiresIn: Int? = 3600
    ) -> StubTransport.Reply {
        var fields = ["\"id_token\":\"\(idToken)\"", "\"access_token\":\"ACCESS-NOT-THIS-ONE\""]
        if let refresh { fields.append("\"refresh_token\":\"\(refresh)\"") }
        if let expiresIn { fields.append("\"expires_in\":\(expiresIn)") }
        return .response(.ok(json: "{\(fields.joined(separator: ","))}"))
    }

    private func provider(
        transport: StubTransport,
        store: any CredentialStore = EphemeralCredentialStore(),
        authorizer: any OIDCAuthorizing = StubAuthorizer(),
        now: @escaping @Sendable () -> Date = Date.init
    ) -> OIDCCredentialProvider {
        OIDCCredentialProvider(
            configuration: configuration,
            reference: CredentialReference(account: "cluster-1"),
            store: store,
            authorizer: authorizer,
            transport: transport,
            now: now
        )
    }

    @Test("The header carries the ID token, never the access token")
    func sendsIDToken() async throws {
        // Kubernetes authenticates the id_token. Sending access_token is the most
        // common way an otherwise correct OIDC setup fails.
        let transport = StubTransport(replies: [metadata(), tokenResponse(idToken: "ID-TOKEN")])
        let headers = try await provider(transport: transport).authenticationHeaders()
        #expect(headers["Authorization"] == "Bearer ID-TOKEN")
    }

    @Test("PKCE parameters are sent, and the challenge is base64url")
    func usesPKCE() async throws {
        let transport = StubTransport(replies: [metadata(), tokenResponse(idToken: "ID")])
        let authorizer = StubAuthorizer()
        _ = try await provider(transport: transport, authorizer: authorizer)
            .authenticationHeaders()

        let url = try #require(await authorizer.seenURL)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let challenge = try #require(items.first { $0.name == "code_challenge" }?.value)
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
        // A standard-base64 challenge is rejected by a conforming issuer.
        #expect(!challenge.contains("+") && !challenge.contains("/") && !challenge.contains("="))
    }

    @Test("A still-valid token is reused instead of signing in again")
    func reusesValidToken() async throws {
        let transport = StubTransport(replies: [metadata(), tokenResponse(idToken: "ID")])
        let subject = provider(transport: transport)
        _ = try await subject.authenticationHeaders()
        _ = try await subject.authenticationHeaders()
        // Metadata and one exchange: the second call hit neither.
        #expect(await transport.sentRequests.count == 2)
    }

    @Test("An expiring token refreshes, a minute before it actually expires")
    func refreshesEarly() async throws {
        let transport = StubTransport(replies: [
            metadata(),
            tokenResponse(idToken: "FIRST", expiresIn: 90),
            tokenResponse(idToken: "SECOND", expiresIn: 3600),
        ])
        // 40s later the token has 50s left — inside the one-minute headroom.
        let clock = MovableClock(start: Date(timeIntervalSince1970: 1_000_000))
        let subject = provider(transport: transport, now: { clock.now })

        #expect(try await subject.authenticationHeaders()["Authorization"] == "Bearer FIRST")
        clock.advance(by: 40)
        #expect(try await subject.authenticationHeaders()["Authorization"] == "Bearer SECOND")
    }

    @Test("Concurrent callers share one refresh rather than spending the token each")
    func refreshIsSingleFlight() async throws {
        // A list and several watches resuming together all need a token at once.
        // Without single-flight each would spend the refresh token and all but one
        // would be rejected.
        let transport = StubTransport(replies: [
            metadata(),
            tokenResponse(idToken: "FIRST", expiresIn: 0),
            tokenResponse(idToken: "SECOND", expiresIn: 3600),
        ])
        let subject = provider(transport: transport)
        _ = try await subject.authenticationHeaders()

        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { try await subject.authenticationHeaders()["Authorization"] ?? "" }
            }
            var all: [String] = []
            for try await value in group { all.append(value) }
            return all
        }

        #expect(results.allSatisfy { $0 == "Bearer SECOND" })
        // Metadata + initial exchange + exactly one refresh.
        #expect(await transport.sentRequests.count == 3)
    }

    @Test("A rejected refresh signs out instead of retrying forever")
    func failedRefreshSignsOut() async throws {
        let store = EphemeralCredentialStore()
        let transport = StubTransport(replies: [
            metadata(),
            tokenResponse(idToken: "FIRST", expiresIn: 0),
            .response(.failure(statusCode: 400, reason: "invalid_grant", message: "expired")),
        ])
        let subject = provider(transport: transport, store: store)
        _ = try await subject.authenticationHeaders()

        await #expect(throws: KubernetesError.self) {
            _ = try await subject.authenticationHeaders()
        }
        // Both tokens dropped, so the next use asks the user to sign in rather than
        // hammering the issuer with a token it has already refused.
        #expect(try await store.credential(for: CredentialReference(account: "cluster-1")) == nil)
    }

    @Test("An issuer with no OpenID configuration is reported clearly")
    func missingMetadataIsExplicit() async throws {
        let transport = StubTransport(replies: [
            .response(.failure(statusCode: 404, reason: "NotFound", message: "no such path")),
        ])
        await #expect(throws: KubernetesError.self) {
            _ = try await provider(transport: transport).authenticationHeaders()
        }
    }
}

@Suite("Exec credential provider")
struct ExecProviderTests {
    private func request(installed: Bool = true) -> ExecApprovalRequest {
        ExecApprovalRequest(
            contextName: "prod",
            command: "aws",
            arguments: ["eks", "get-token"],
            environmentNames: ["AWS_PROFILE"],
            installHint: "Install the AWS CLI.",
            resolvedExecutableURL: installed ? URL(fileURLWithPath: "/usr/local/bin/aws") : nil,
            fingerprint: "fingerprint-1"
        )
    }

    @Test("A denied plugin never runs")
    func deniedPluginDoesNotRun() async throws {
        let runner = StubRunner(status: ExecCredentialStatus(token: "t"))
        let provider = ExecCredentialProvider(
            request: request(), runner: runner, approvals: DecliningExecApproval()
        )
        await #expect(throws: KubernetesError.self) {
            _ = try await provider.authenticationHeaders()
        }
        #expect(await runner.runCount == 0, "approval is required before execution, not after")
    }

    @Test("An approved plugin supplies a bearer token")
    func approvedPluginSuppliesToken() async throws {
        let provider = ExecCredentialProvider(
            request: request(),
            runner: StubRunner(status: ExecCredentialStatus(token: "plugin-token")),
            approvals: StubApprovals(decision: .allowOnce)
        )
        #expect(try await provider.authenticationHeaders()["Authorization"]
            == "Bearer plugin-token")
    }

    @Test("A remembered approval is not asked again; allow-once is")
    func rememberedApprovalSkipsThePrompt() async throws {
        let remembered = StubApprovals(decision: .allowUntilCommandChanges)
        let provider = ExecCredentialProvider(
            request: request(),
            runner: StubRunner(status: ExecCredentialStatus(token: "t", expirationTimestamp: .distantPast)),
            approvals: remembered
        )
        _ = try await provider.authenticationHeaders()
        _ = try await provider.authenticationHeaders()
        #expect(await remembered.askCount == 1)

        let once = StubApprovals(decision: .allowOnce)
        let asksEveryTime = ExecCredentialProvider(
            request: request(),
            runner: StubRunner(status: ExecCredentialStatus(token: "t", expirationTimestamp: .distantPast)),
            approvals: once
        )
        _ = try await asksEveryTime.authenticationHeaders()
        _ = try await asksEveryTime.authenticationHeaders()
        #expect(await once.askCount == 2)
    }

    @Test("A credential is reused until it is close to expiring")
    func cachesUntilExpiry() async throws {
        let runner = StubRunner(status: ExecCredentialStatus(
            token: "t", expirationTimestamp: Date(timeIntervalSince1970: 1_000_000 + 3600)
        ))
        let clock = MovableClock(start: Date(timeIntervalSince1970: 1_000_000))
        let provider = ExecCredentialProvider(
            request: request(),
            runner: runner,
            approvals: StubApprovals(decision: .allowUntilCommandChanges),
            now: { clock.now }
        )
        _ = try await provider.authenticationHeaders()
        _ = try await provider.authenticationHeaders()
        #expect(await runner.runCount == 1)

        clock.advance(by: 3600)
        _ = try await provider.authenticationHeaders()
        #expect(await runner.runCount == 2, "re-runs once the credential is nearly expired")
    }

    @Test("A plugin that is not installed says so, with the install hint")
    func missingExecutableIsExplicit() async throws {
        let provider = ExecCredentialProvider(
            request: request(installed: false),
            runner: StubRunner(status: ExecCredentialStatus(token: "t")),
            approvals: StubApprovals(decision: .allowOnce)
        )
        await #expect(throws: KubernetesError.self) {
            _ = try await provider.authenticationHeaders()
        }
    }

    @Test("Decoding the ExecCredential shape the API defines")
    func decodesExecCredential() throws {
        let json = """
        {"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential",
         "status":{"token":"abc","expirationTimestamp":"2026-10-19T09:00:00.500Z"}}
        """
        let status = try JSONDecoder().decode(ExecCredentialStatus.self, from: Data(json.utf8))
        #expect(status.token == "abc")
        // Fractional seconds again: plugins emit them.
        #expect(status.expirationTimestamp != nil)
    }
}

// MARK: - Doubles

private actor StubAuthorizer: OIDCAuthorizing {
    private(set) var seenURL: URL?
    func authorize(_ request: OIDCAuthorizationRequest) async throws -> String {
        seenURL = request.authorizationURL
        return "auth-code"
    }
}

private actor StubRunner: ExecPluginRunning {
    private let status: ExecCredentialStatus
    private(set) var runCount = 0
    init(status: ExecCredentialStatus) { self.status = status }
    func run(_ invocation: ExecPluginInvocation) async throws -> ExecCredentialStatus {
        runCount += 1
        return status
    }
}

private actor StubApprovals: ExecApprovalGranting {
    private let decision: ExecApprovalDecision
    private(set) var askCount = 0
    init(decision: ExecApprovalDecision) { self.decision = decision }
    func decision(for request: ExecApprovalRequest) async -> ExecApprovalDecision {
        askCount += 1
        return decision
    }
}

/// A clock a test can move, so expiry is exercised without waiting.
private final class MovableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}
