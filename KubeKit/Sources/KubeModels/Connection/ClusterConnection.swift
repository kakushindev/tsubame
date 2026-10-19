import Foundation

/// A cluster the user has added, as the app stores it.
///
/// Credential material is never part of this type. `credentialReference` names an
/// entry in protected storage; the value itself is read only when a request is built.
public struct ClusterConnection: Hashable, Sendable, Identifiable, Codable {
    public let id: UUID
    public var displayName: String
    public var serverURL: URL
    public var contextName: String
    public var defaultNamespace: String
    public var authenticationMethod: AuthenticationMethod
    public var credentialReference: CredentialReference
    public var tls: TLSConfiguration

    public init(
        id: UUID = UUID(),
        displayName: String,
        serverURL: URL,
        contextName: String,
        defaultNamespace: String = ClusterConnection.defaultNamespaceName,
        authenticationMethod: AuthenticationMethod,
        credentialReference: CredentialReference,
        tls: TLSConfiguration
    ) {
        self.id = id
        self.displayName = displayName
        self.serverURL = serverURL
        self.contextName = contextName
        self.defaultNamespace = defaultNamespace
        self.authenticationMethod = authenticationMethod
        self.credentialReference = credentialReference
        self.tls = tls
    }

    /// PRD §9.1: a newly selected context starts in `default`.
    public static let defaultNamespaceName = "default"
}

/// How the app authenticates to a cluster. Availability differs by platform; see
/// `isSupported(on:)` rather than assuming every case works everywhere.
public enum AuthenticationMethod: Hashable, Sendable, Codable {
    case bearerToken
    case clientCertificate
    case oidc(issuer: URL, clientID: String, scopes: [String])
    /// A kubeconfig `exec` credential plugin. macOS only, and only after the user
    /// approves the specific command.
    case execPlugin(command: String, arguments: [String])

    public func isSupported(on platform: HostPlatform) -> Bool {
        switch self {
        case .bearerToken, .oidc:
            return true
        case .clientCertificate:
            return platform == .macOS
        case .execPlugin:
            return platform == .macOS
        }
    }
}

public enum HostPlatform: Hashable, Sendable {
    case macOS
    case iOS

    public static var current: HostPlatform {
        #if os(macOS)
        .macOS
        #else
        .iOS
        #endif
    }
}

/// A stable name for a credential held in protected storage.
public struct CredentialReference: Hashable, Sendable, Codable {
    public let account: String

    public init(account: String) {
        self.account = account
    }
}

/// Trust settings for a cluster endpoint. The default verifies the system trust
/// store; a custom authority or a disabled check is always an explicit choice.
public struct TLSConfiguration: Hashable, Sendable, Codable {
    public var certificateAuthorityData: Data?
    public var serverName: String?
    public var allowsInsecureConnections: Bool

    public init(
        certificateAuthorityData: Data? = nil,
        serverName: String? = nil,
        allowsInsecureConnections: Bool = false
    ) {
        self.certificateAuthorityData = certificateAuthorityData
        self.serverName = serverName
        self.allowsInsecureConnections = allowsInsecureConnections
    }

    public static let systemDefault = TLSConfiguration()
}
