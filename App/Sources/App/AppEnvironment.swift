import Foundation
import Observation
import KubeKit
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
    let platform: HostPlatform

    init(
        credentialStore: any CredentialStore,
        kubeconfigParser: any KubeconfigParsing,
        kubeconfigDiscovery: any KubeconfigDiscovery = AppEnvironment.platformKubeconfigDiscovery,
        platform: HostPlatform = .current
    ) {
        self.credentialStore = credentialStore
        self.kubeconfigParser = kubeconfigParser
        self.kubeconfigDiscovery = kubeconfigDiscovery
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
            kubeconfigDiscovery: NoKubeconfigDiscovery()
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
        case .clientCertificate, .oidc, .execPlugin:
            // Tracked in docs/IMPLEMENTATION_CHECKLIST.md. Until each provider
            // exists, the connection fails with a precise error rather than
            // silently sending unauthenticated requests.
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
