import Foundation
import Observation
import KubeKit
import KubeExec
import KubeKeychain
import KubeModels

/// The app's composition root.
///
/// It owns the long-lived collaborators and builds a `KubernetesClient` per cluster
/// on demand. Nothing below it constructs a transport or a credential store, so the
/// Keychain and the network stay swappable in tests and previews.
@MainActor
@Observable
final class AppEnvironment {
    let credentialStore: any CredentialStore
    let kubeconfigParser: any KubeconfigParsing
    let kubeconfigDiscovery: any KubeconfigDiscovery
    let clientIdentities: (any ClientIdentityProviding)?
    let execRunner: (any ExecPluginRunning)?
    let execApprovals: any ExecApprovalGranting
    let platform: HostPlatform

    init(
        credentialStore: any CredentialStore,
        kubeconfigParser: any KubeconfigParsing,
        kubeconfigDiscovery: any KubeconfigDiscovery = AppEnvironment.platformKubeconfigDiscovery,
        clientIdentities: (any ClientIdentityProviding)? = AppEnvironment.platformClientIdentities,
        execRunner: (any ExecPluginRunning)? = AppEnvironment.platformExecRunner,
        execApprovals: any ExecApprovalGranting = DecliningExecApproval(),
        platform: HostPlatform = .current
    ) {
        self.credentialStore = credentialStore
        self.kubeconfigParser = kubeconfigParser
        self.kubeconfigDiscovery = kubeconfigDiscovery
        self.clientIdentities = clientIdentities
        self.execRunner = execRunner
        self.execApprovals = execApprovals
        self.platform = platform
    }

    /// The only place the app branches on platform for kubeconfig discovery.
    static var platformKubeconfigDiscovery: any KubeconfigDiscovery {
        #if os(macOS)
        KubeconfigLocator()
        #else
        NoKubeconfigDiscovery()
        #endif
    }

    /// Client certificates need the keychain-backed identity store, which is macOS
    /// only in this release (PRD §9.1).
    static var platformClientIdentities: (any ClientIdentityProviding)? {
        #if os(macOS)
        ClientIdentityStore()
        #else
        nil
        #endif
    }

    /// iOS and iPadOS have no process to run, so there is nothing to return and the
    /// UI must not imply otherwise.
    static var platformExecRunner: (any ExecPluginRunning)? {
        #if os(macOS)
        ProcessExecPluginRunner()
        #else
        nil
        #endif
    }

    static func live() -> AppEnvironment {
        AppEnvironment(
            credentialStore: KeychainCredentialStore(),
            kubeconfigParser: KubeconfigParser()
        )
    }

    /// In-memory storage and no network, for previews and tests.
    static func inMemory() -> AppEnvironment {
        AppEnvironment(
            credentialStore: EphemeralCredentialStore(),
            kubeconfigParser: KubeconfigParser(),
            kubeconfigDiscovery: NoKubeconfigDiscovery(),
            clientIdentities: nil,
            execRunner: nil
        )
    }

    /// Builds the client for a connection, choosing the credential provider that
    /// matches the stored authentication method.
    func makeClient(for connection: ClusterConnection) -> KubernetesClient {
        KubernetesClient(
            transport: URLSessionTransport(
                serverURL: connection.serverURL,
                credentialProvider: makeCredentialProvider(for: connection),
                tls: connection.tls,
                proxy: connection.proxy,
                platform: platform
            )
        )
    }

    private func makeCredentialProvider(for connection: ClusterConnection) -> any CredentialProvider {
        guard connection.authenticationMethod.isSupported(on: platform) else {
            return UnsupportedCredentialProvider(
                method: connection.authenticationMethod.displayName,
                platform: platform
            )
        }
        switch connection.authenticationMethod {
        case .bearerToken:
            return BearerTokenCredentialProvider(
                reference: connection.credentialReference,
                store: credentialStore
            )
        case .tokenFile(let path):
            // Re-read per request, so a rotated service-account token keeps working.
            return TokenFileCredentialProvider(path: path)
        case .clientCertificate:
            guard let clientIdentities else {
                return UnsupportedCredentialProvider(
                    method: connection.authenticationMethod.displayName,
                    platform: platform
                )
            }
            return ClientCertificateCredentialProvider(
                reference: connection.credentialReference,
                identities: clientIdentities
            )
        case .oidc, .execPlugin:
            // Both need something the composition root cannot supply on its own:
            // OIDC a sign-in presenter, exec an approved and resolved command. They
            // are built where that context exists, and until then the connection
            // fails precisely rather than sending unauthenticated requests.
            return UnsupportedCredentialProvider(
                method: connection.authenticationMethod.displayName,
                platform: platform
            )
        }
    }
}

extension AuthenticationMethod {
    var displayName: String {
        switch self {
        case .bearerToken: return "Bearer token"
        case .tokenFile: return "Token file"
        case .clientCertificate: return "Client certificate"
        case .oidc: return "OIDC"
        case .execPlugin: return "Exec credential plugin"
        }
    }
}
