import Foundation
import KubeModels

/// What importing one kubeconfig context would do, worked out before anything is
/// stored and before any request is sent.
///
/// This value deliberately carries **no credential material**. It is `Hashable` and
/// flows through UI state, where a token in it would be a token one `print` away
/// from a log — which PRD §12 forbids. The credential is re-read from the kubeconfig
/// document at the moment it is written to protected storage, and nowhere else.
public struct KubeconfigImportPlan: Hashable, Sendable {
    /// Whether this context can be used on this platform, and what it needs first.
    public enum Support: Hashable, Sendable {
        case supported
        /// macOS exec plugin: the user must approve the specific command first.
        case requiresApproval(ExecApprovalRequest)
        /// OIDC that the document cannot fully describe — a redirect URI, usually.
        case needsSetup(reason: String)
        case unsupported(method: String, platform: HostPlatform, reason: String)

        public var isUsableNow: Bool {
            if case .supported = self { return true }
            return false
        }
    }

    /// Something the user should be told before they import.
    ///
    /// These are not failures. Each one is a place where the import is doing
    /// something the user would want to know about.
    public enum Warning: Hashable, Sendable {
        /// TLS verification is off for this cluster. PRD §12 requires a trust
        /// exception to be deliberate and explained, so it is never silent.
        case insecureSkipTLSVerify
        /// A `tokenFile` was read once and copied. Service-account tokens rotate,
        /// so the copy will eventually stop working.
        case tokenFileIsASnapshot(path: String)
        case certificateAuthorityFileUnreadable(path: String, reason: String)
        /// Both inline and file CA data were present and differ. Inline wins.
        case inlineAndFileCertificateAuthorityDisagree
        case deprecatedAuthProvider(name: String)
        case proxyUnsupportedOnPlatform(proxy: String, platform: HostPlatform)
        /// Basic auth: removed from Kubernetes and not supported here.
        case basicAuthenticationIgnored

        public var message: String {
            switch self {
            case .insecureSkipTLSVerify:
                return "This cluster is set to skip TLS verification. Traffic can be "
                    + "intercepted, and the server's identity is not checked."
            case .tokenFileIsASnapshot(let path):
                return "The token was copied from \(path). Service-account tokens are "
                    + "rotated, so this copy will stop working and have to be re-imported."
            case .certificateAuthorityFileUnreadable(let path, let reason):
                return "The certificate authority at \(path) could not be read (\(reason)). "
                    + "The system trust store will be used instead, which may not trust "
                    + "this cluster."
            case .inlineAndFileCertificateAuthorityDisagree:
                return "This cluster lists both an inline certificate authority and a file, "
                    + "and they differ. The inline data is used."
            case .deprecatedAuthProvider(let name):
                return "This cluster uses the deprecated auth-provider \"\(name)\"."
            case .proxyUnsupportedOnPlatform(let proxy, let platform):
                return "This cluster is reached through \(proxy), which "
                    + "\(platform == .macOS ? "macOS" : "iOS and iPadOS") cannot apply."
            case .basicAuthenticationIgnored:
                return "This cluster uses a username and password. Kubernetes removed basic "
                    + "authentication, and Tsubame does not support it."
            }
        }
    }

    public let contextName: String
    public let displayName: String
    public let serverURL: URL
    /// The kubeconfig's namespace for this context, or `default` (PRD §9.1).
    public let namespace: String
    public let tls: TLSConfiguration
    public let proxy: ProxyConfiguration?
    public let authenticationMethod: AuthenticationMethod
    public let support: Support
    /// The kubeconfig user entry the credential comes from. A name, not a secret.
    public let credentialUser: String
    /// Files this plan read, so the UI can say what it touched.
    public let resolvedFiles: [URL]
    public let warnings: [Warning]

    public init(
        contextName: String,
        displayName: String,
        serverURL: URL,
        namespace: String,
        tls: TLSConfiguration,
        proxy: ProxyConfiguration?,
        authenticationMethod: AuthenticationMethod,
        support: Support,
        credentialUser: String,
        resolvedFiles: [URL] = [],
        warnings: [Warning] = []
    ) {
        self.contextName = contextName
        self.displayName = displayName
        self.serverURL = serverURL
        self.namespace = namespace
        self.tls = tls
        self.proxy = proxy
        self.authenticationMethod = authenticationMethod
        self.support = support
        self.credentialUser = credentialUser
        self.resolvedFiles = resolvedFiles
        self.warnings = warnings
    }
}

/// An exec credential plugin the user is being asked to approve.
///
/// Carries variable **names** only. Their values may themselves be credentials, so
/// they are never part of this type (PRD §12).
public struct ExecApprovalRequest: Hashable, Sendable {
    public let contextName: String
    public let command: String
    public let arguments: [String]
    public let environmentNames: [String]
    public let installHint: String?
    /// The absolute path the command resolved to, or `nil` when it is not installed.
    /// Resolution happens once, here, and this path is what runs — `PATH` is never
    /// consulted again at execution time.
    public let resolvedExecutableURL: URL?
    /// Binds an approval to this exact command. Editing the kubeconfig to point
    /// somewhere else changes the fingerprint and re-prompts, because the risk is an
    /// imported file naming a binary the user did not choose.
    public let fingerprint: String

    public init(
        contextName: String,
        command: String,
        arguments: [String],
        environmentNames: [String],
        installHint: String?,
        resolvedExecutableURL: URL?,
        fingerprint: String
    ) {
        self.contextName = contextName
        self.command = command
        self.arguments = arguments
        self.environmentNames = environmentNames
        self.installHint = installHint
        self.resolvedExecutableURL = resolvedExecutableURL
        self.fingerprint = fingerprint
    }

    public var isInstalled: Bool { resolvedExecutableURL != nil }
}
