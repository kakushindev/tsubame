import Foundation
import Testing
import KubeModels
@testable import KubeKit

/// Serves file references from memory, so tests never touch the filesystem.
private struct StubFileReader: KubeconfigFileReading {
    var files: [String: Data] = [:]

    func contents(ofPath path: String, relativeTo directory: URL?) throws -> Data {
        guard let data = files[path] else {
            throw KubernetesError.invalidConfiguration(reason: "no such file \(path)")
        }
        return data
    }
}

@Suite("KubeconfigImporter")
struct KubeconfigImporterTests {
    private func kubeconfig(
        cluster: KubeconfigCluster = KubeconfigCluster(server: "https://cluster.example:6443"),
        user: KubeconfigUser = KubeconfigUser(token: "s3cret-token"),
        namespace: String? = nil
    ) -> Kubeconfig {
        Kubeconfig(
            currentContext: "prod-admin",
            clusters: [NamedEntry(name: "prod", value: cluster)],
            contexts: [NamedEntry(
                name: "prod-admin",
                value: KubeconfigContext(cluster: "prod", user: "admin", namespace: namespace)
            )],
            users: [NamedEntry(name: "admin", value: user)]
        )
    }

    private func importer(
        store: any CredentialStore = EphemeralCredentialStore(),
        files: [String: Data] = [:],
        platform: HostPlatform = .macOS,
        executable: @escaping KubeconfigImporter.ExecutableLocating = { _ in nil }
    ) -> KubeconfigImporter {
        KubeconfigImporter(
            store: store,
            fileReader: StubFileReader(files: files),
            platform: platform,
            locateExecutable: executable
        )
    }

    // MARK: - Planning

    @Test("Planning reads the context without storing or sending anything")
    func planIsInert() async throws {
        let store = EphemeralCredentialStore()
        let plan = try importer(store: store).plan(
            contextNamed: "prod-admin", in: kubeconfig()
        )

        #expect(plan.serverURL == URL(string: "https://cluster.example:6443")!)
        #expect(plan.contextName == "prod-admin")
        #expect(plan.support.isUsableNow)
        // Nothing was written: the credential only moves in `import`.
        #expect(try await store.credential(for: CredentialReference(account: "prod-admin")) == nil)
    }

    @Test("A context without its own namespace starts in default")
    func defaultsNamespace() throws {
        let plan = try importer().plan(contextNamed: "prod-admin", in: kubeconfig())
        #expect(plan.namespace == "default")

        let explicit = try importer().plan(
            contextNamed: "prod-admin", in: kubeconfig(namespace: "payments")
        )
        #expect(explicit.namespace == "payments")
    }

    @Test("The plan carries no credential material")
    func planHoldsNoSecret() throws {
        let plan = try importer().plan(
            contextNamed: "prod-admin",
            in: kubeconfig(user: KubeconfigUser(token: "s3cret-token"))
        )
        // The plan flows through UI state, so a token in it is a token in a log.
        #expect(!String(describing: plan).contains("s3cret-token"))
    }

    @Test("Skipping TLS verification is always surfaced as a warning")
    func warnsOnInsecureTLS() throws {
        let plan = try importer().plan(
            contextNamed: "prod-admin",
            in: kubeconfig(cluster: KubeconfigCluster(
                server: "https://cluster.example:6443", insecureSkipTLSVerify: true
            ))
        )
        #expect(plan.tls.allowsInsecureConnections)
        #expect(plan.warnings.contains(.insecureSkipTLSVerify))
    }

    @Test("Inline certificate authority data wins over a file, and disagreement is reported")
    func prefersInlineAuthority() throws {
        let inline = Data("INLINE-CA".utf8)
        let plan = try importer(files: ["/etc/ca.crt": Data("FILE-CA".utf8)]).plan(
            contextNamed: "prod-admin",
            in: kubeconfig(cluster: KubeconfigCluster(
                server: "https://cluster.example:6443",
                certificateAuthority: "/etc/ca.crt",
                certificateAuthorityData: inline.base64EncodedString()
            ))
        )
        #expect(plan.tls.certificateAuthorityData == inline)
        #expect(plan.warnings.contains(.inlineAndFileCertificateAuthorityDisagree))
    }

    @Test("An unreadable certificate authority warns rather than failing the import")
    func warnsOnUnreadableAuthority() throws {
        let plan = try importer().plan(
            contextNamed: "prod-admin",
            in: kubeconfig(cluster: KubeconfigCluster(
                server: "https://cluster.example:6443", certificateAuthority: "/missing/ca.crt"
            ))
        )
        #expect(plan.tls.certificateAuthorityData == nil)
        #expect(plan.warnings.contains { if case .certificateAuthorityFileUnreadable = $0 { return true }; return false })
    }

    @Test("A relative file path in pasted text is a named error, not a silent skip")
    func namesRelativePathProblem() throws {
        #expect(throws: KubernetesError.self) {
            _ = try LocalKubeconfigFileReader.resolve(path: "ca.crt", relativeTo: nil)
        }
        let resolved = try LocalKubeconfigFileReader.resolve(
            path: "ca.crt", relativeTo: URL(fileURLWithPath: "/home/user/.kube/")
        )
        #expect(resolved.path == "/home/user/.kube/ca.crt")
    }

    @Test("Exec plugins are unsupported on iOS and supported-after-approval on macOS")
    func handlesExecPerPlatform() throws {
        let exec = KubeconfigUser(exec: KubeconfigExecConfig(
            apiVersion: "client.authentication.k8s.io/v1",
            command: "aws",
            args: ["eks", "get-token"],
            env: [ExecEnvironmentVariable(name: "AWS_PROFILE", value: "secret-profile")],
            installHint: "Install the AWS CLI"
        ))

        let mobile = try importer(platform: .iOS).plan(
            contextNamed: "prod-admin", in: kubeconfig(user: exec)
        )
        guard case .unsupported = mobile.support else {
            Issue.record("iOS must refuse exec plugins outright"); return
        }

        let desktop = try importer(
            platform: .macOS,
            executable: { _ in URL(fileURLWithPath: "/usr/local/bin/aws") }
        ).plan(contextNamed: "prod-admin", in: kubeconfig(user: exec))

        guard case .requiresApproval(let request) = desktop.support else {
            Issue.record("macOS must ask before running a plugin"); return
        }
        #expect(request.resolvedExecutableURL?.path == "/usr/local/bin/aws")
        #expect(request.environmentNames == ["AWS_PROFILE"])
        // Variable values can themselves be credentials, so only names travel.
        #expect(!String(describing: request).contains("secret-profile"))
    }

    @Test("An approval fingerprint changes when the command resolves somewhere else")
    func fingerprintBindsToTheBinary() throws {
        let exec = KubeconfigUser(exec: KubeconfigExecConfig(
            apiVersion: "client.authentication.k8s.io/v1", command: "aws", args: ["eks"]
        ))
        func fingerprint(at path: String) throws -> String {
            let plan = try importer(executable: { _ in URL(fileURLWithPath: path) })
                .plan(contextNamed: "prod-admin", in: kubeconfig(user: exec))
            guard case .requiresApproval(let request) = plan.support else {
                throw KubernetesError.invalidConfiguration(reason: "expected approval")
            }
            return request.fingerprint
        }
        #expect(try fingerprint(at: "/usr/local/bin/aws") != fingerprint(at: "/tmp/evil/aws"))
    }

    @Test("A plugin that is not installed is reported as such, not as ready to run")
    func reportsMissingExecutable() throws {
        let exec = KubeconfigUser(exec: KubeconfigExecConfig(
            apiVersion: "client.authentication.k8s.io/v1", command: "gke-gcloud-auth-plugin"
        ))
        let plan = try importer(executable: { _ in nil })
            .plan(contextNamed: "prod-admin", in: kubeconfig(user: exec))
        guard case .requiresApproval(let request) = plan.support else {
            Issue.record("expected an approval request"); return
        }
        #expect(!request.isInstalled)
    }

    @Test("Client certificates are macOS-only in this release")
    func clientCertificateIsDesktopOnly() throws {
        let user = KubeconfigUser(clientCertificateData: "Y2VydA==", clientKeyData: "a2V5")
        #expect(try importer(platform: .macOS)
            .plan(contextNamed: "prod-admin", in: kubeconfig(user: user)).support.isUsableNow)

        let mobile = try importer(platform: .iOS)
            .plan(contextNamed: "prod-admin", in: kubeconfig(user: user))
        guard case .unsupported = mobile.support else {
            Issue.record("iOS does not support client certificates yet"); return
        }
    }

    @Test("A user with no usable credential is refused with a reason")
    func refusesCredentiallessUser() throws {
        let plan = try importer().plan(
            contextNamed: "prod-admin", in: kubeconfig(user: KubeconfigUser())
        )
        guard case .unsupported(_, _, let reason) = plan.support else {
            Issue.record("expected an unsupported plan"); return
        }
        #expect(!reason.isEmpty)
    }

    @Test("Basic auth is reported as ignored rather than silently dropped")
    func warnsOnBasicAuth() throws {
        let plan = try importer().plan(
            contextNamed: "prod-admin",
            in: kubeconfig(user: KubeconfigUser(token: "t", username: "admin", password: "hunter2"))
        )
        #expect(plan.warnings.contains(.basicAuthenticationIgnored))
    }

    @Test("A missing context or cluster names what is wrong")
    func reportsStructuralProblems() {
        #expect(throws: KubernetesError.self) {
            _ = try importer().plan(contextNamed: "nope", in: kubeconfig())
        }
    }

    // MARK: - Importing

    @Test("Importing stores the token and returns a connection that does not carry it")
    func importStoresCredential() async throws {
        let store = EphemeralCredentialStore()
        let config = kubeconfig(user: KubeconfigUser(token: "s3cret-token"))
        let importer = importer(store: store)
        let plan = try importer.plan(contextNamed: "prod-admin", in: config)

        let connection = try await importer.import(plan, from: config)

        let stored = try await store.credential(for: connection.credentialReference)
        #expect(stored == Data("s3cret-token".utf8))
        // PRD §12: the saved connection names the credential, never holds it.
        let encoded = try JSONEncoder().encode(connection)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("s3cret-token"))
    }

    @Test("macOS re-reads a tokenFile rather than copying it, so rotation keeps working")
    func rereadsTokenFileOnDesktop() async throws {
        let store = EphemeralCredentialStore()
        let path = "/var/run/secrets/token"
        let config = kubeconfig(user: KubeconfigUser(tokenFile: path))
        let importer = importer(store: store, files: [path: Data("file-token\n".utf8)], platform: .macOS)
        let plan = try importer.plan(contextNamed: "prod-admin", in: config)

        #expect(plan.authenticationMethod == .tokenFile(path: path))
        // Nothing expires, so there is nothing to warn about.
        #expect(plan.warnings.isEmpty)

        let connection = try await importer.import(plan, from: config)
        // Nothing is stored: a copy would be a second, staler source of truth.
        #expect(try await store.credential(for: connection.credentialReference) == nil)
    }

    @Test("iOS copies a tokenFile and says plainly that the copy will expire")
    func snapshotsTokenFileOnMobile() async throws {
        let store = EphemeralCredentialStore()
        let path = "/var/run/secrets/token"
        let config = kubeconfig(user: KubeconfigUser(tokenFile: path))
        let importer = importer(store: store, files: [path: Data("file-token\n".utf8)], platform: .iOS)
        let plan = try importer.plan(contextNamed: "prod-admin", in: config)

        #expect(plan.authenticationMethod == .bearerToken)
        #expect(plan.warnings.contains(.tokenFileIsASnapshot(path: path)))

        let connection = try await importer.import(plan, from: config)
        // A trailing newline in an Authorization header is a 401.
        #expect(try await store.credential(for: connection.credentialReference)
            == Data("file-token".utf8))
    }

    @Test("The token-file provider re-reads on every request and trims the value")
    func tokenFileProviderRereads() async throws {
        let box = TokenBox()
        let provider = TokenFileCredentialProvider(path: "/token") { _ in box.read() }

        box.value = "first-token\n"
        #expect(try await provider.authenticationHeaders() == ["Authorization": "Bearer first-token"])

        // Rotate the file underneath, as the kubelet does.
        box.value = "rotated-token\n"
        #expect(try await provider.authenticationHeaders() == ["Authorization": "Bearer rotated-token"])
        #expect(box.reads == 2)
    }

    @Test("A token file that is missing or empty fails with a reason, not a blank header")
    func tokenFileFailuresAreExplicit() async throws {
        let missing = TokenFileCredentialProvider(path: "/gone") { _ in
            throw KubernetesError.invalidConfiguration(reason: "no file")
        }
        await #expect(throws: KubernetesError.self) {
            _ = try await missing.authenticationHeaders()
        }

        let empty = TokenFileCredentialProvider(path: "/empty") { _ in Data("  \n".utf8) }
        await #expect(throws: KubernetesError.self) {
            _ = try await empty.authenticationHeaders()
        }
    }

    @Test("Importing an unsupported context refuses instead of saving a broken cluster")
    func refusesUnsupportedImport() async throws {
        let store = EphemeralCredentialStore()
        let config = kubeconfig(user: KubeconfigUser(clientCertificateData: "Y2VydA=="))
        let importer = importer(store: store, platform: .iOS)
        let plan = try importer.plan(contextNamed: "prod-admin", in: config)

        await #expect(throws: KubernetesError.self) {
            _ = try await importer.import(plan, from: config)
        }
    }

    @Test("The proxy travels from the kubeconfig onto the connection")
    func carriesProxy() async throws {
        let plan = try importer().plan(
            contextNamed: "prod-admin",
            in: kubeconfig(cluster: KubeconfigCluster(
                server: "https://cluster.example:6443", proxyURL: "http://proxy.internal:3128"
            ))
        )
        #expect(plan.proxy?.kind == .http)
        #expect(plan.proxy?.port == 3128)
    }
}

/// A mutable box for the token-file read closure, so a test can rotate the value
/// between requests without an actor hop inside a `@Sendable` closure.
private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ""
    private var _reads = 0

    var value: String {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
    var reads: Int { lock.withLock { _reads } }

    func read() -> Data {
        lock.withLock {
            _reads += 1
            return Data(_value.utf8)
        }
    }
}
