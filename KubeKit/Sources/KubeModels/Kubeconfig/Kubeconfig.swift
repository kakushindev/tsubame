import Foundation

/// A parsed kubeconfig document.
///
/// This mirrors the on-disk shape. It is a transport format, not app state:
/// importing a context produces a `ClusterConnection` plus a credential written to
/// protected storage, and the document itself is not persisted.
public struct Kubeconfig: Hashable, Sendable, Codable {
    public var currentContext: String?
    public var clusters: [NamedEntry<KubeconfigCluster>]
    public var contexts: [NamedEntry<KubeconfigContext>]
    public var users: [NamedEntry<KubeconfigUser>]

    public init(
        currentContext: String? = nil,
        clusters: [NamedEntry<KubeconfigCluster>] = [],
        contexts: [NamedEntry<KubeconfigContext>] = [],
        users: [NamedEntry<KubeconfigUser>] = []
    ) {
        self.currentContext = currentContext
        self.clusters = clusters
        self.contexts = contexts
        self.users = users
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentContext = try container.decodeIfPresent(String.self, forKey: .currentContext)
        clusters = try container.decodeIfPresent([NamedEntry<KubeconfigCluster>].self, forKey: .clusters) ?? []
        contexts = try container.decodeIfPresent([NamedEntry<KubeconfigContext>].self, forKey: .contexts) ?? []
        users = try container.decodeIfPresent([NamedEntry<KubeconfigUser>].self, forKey: .users) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case currentContext = "current-context"
        case clusters
        case contexts
        case users
    }

    public func cluster(named name: String) -> KubeconfigCluster? {
        clusters.first { $0.name == name }?.value
    }

    public func context(named name: String) -> KubeconfigContext? {
        contexts.first { $0.name == name }?.value
    }

    public func user(named name: String) -> KubeconfigUser? {
        users.first { $0.name == name }?.value
    }
}

/// The key a kubeconfig entry's payload appears under, e.g. `cluster` in
/// `{name: dev, cluster: {...}}`.
public protocol KubeconfigEntryValue: Hashable, Sendable, Codable {
    static var kubeconfigKey: String { get }
}

/// kubeconfig's repeated `{name:, <kind>:}` wrapper.
public struct NamedEntry<Value: KubeconfigEntryValue>: Hashable, Sendable, Codable {
    public let name: String
    public let value: Value

    public init(name: String, value: Value) {
        self.name = name
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: EntryKey.self)
        name = try container.decode(String.self, forKey: EntryKey("name"))
        value = try container.decode(Value.self, forKey: EntryKey(Value.kubeconfigKey))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: EntryKey.self)
        try container.encode(name, forKey: EntryKey("name"))
        try container.encode(value, forKey: EntryKey(Value.kubeconfigKey))
    }

    struct EntryKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

public struct KubeconfigCluster: KubeconfigEntryValue {
    public static let kubeconfigKey = "cluster"

    public var server: String
    public var certificateAuthority: String?
    public var certificateAuthorityData: String?
    public var insecureSkipTLSVerify: Bool?
    public var tlsServerName: String?
    public var proxyURL: String?

    public init(
        server: String,
        certificateAuthority: String? = nil,
        certificateAuthorityData: String? = nil,
        insecureSkipTLSVerify: Bool? = nil,
        tlsServerName: String? = nil,
        proxyURL: String? = nil
    ) {
        self.server = server
        self.certificateAuthority = certificateAuthority
        self.certificateAuthorityData = certificateAuthorityData
        self.insecureSkipTLSVerify = insecureSkipTLSVerify
        self.tlsServerName = tlsServerName
        self.proxyURL = proxyURL
    }

    private enum CodingKeys: String, CodingKey {
        case server
        case certificateAuthority = "certificate-authority"
        case certificateAuthorityData = "certificate-authority-data"
        case insecureSkipTLSVerify = "insecure-skip-tls-verify"
        case tlsServerName = "tls-server-name"
        case proxyURL = "proxy-url"
    }
}

public struct KubeconfigContext: KubeconfigEntryValue {
    public static let kubeconfigKey = "context"

    public var cluster: String
    public var user: String
    public var namespace: String?

    public init(cluster: String, user: String, namespace: String? = nil) {
        self.cluster = cluster
        self.user = user
        self.namespace = namespace
    }
}

/// The credential half of a kubeconfig entry.
///
/// Every field here is sensitive. Nothing in this type may be written to logs,
/// diagnostics, or error messages — see `CredentialRedactor` in KubeKit.
public struct KubeconfigUser: KubeconfigEntryValue {
    public static let kubeconfigKey = "user"

    public var token: String?
    public var tokenFile: String?
    public var username: String?
    public var password: String?
    public var clientCertificate: String?
    public var clientCertificateData: String?
    public var clientKey: String?
    public var clientKeyData: String?
    public var exec: KubeconfigExecConfig?
    public var authProvider: KubeconfigAuthProvider?

    public init(
        token: String? = nil,
        tokenFile: String? = nil,
        username: String? = nil,
        password: String? = nil,
        clientCertificate: String? = nil,
        clientCertificateData: String? = nil,
        clientKey: String? = nil,
        clientKeyData: String? = nil,
        exec: KubeconfigExecConfig? = nil,
        authProvider: KubeconfigAuthProvider? = nil
    ) {
        self.token = token
        self.tokenFile = tokenFile
        self.username = username
        self.password = password
        self.clientCertificate = clientCertificate
        self.clientCertificateData = clientCertificateData
        self.clientKey = clientKey
        self.clientKeyData = clientKeyData
        self.exec = exec
        self.authProvider = authProvider
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case tokenFile = "tokenFile"
        case username
        case password
        case clientCertificate = "client-certificate"
        case clientCertificateData = "client-certificate-data"
        case clientKey = "client-key"
        case clientKeyData = "client-key-data"
        case exec
        case authProvider = "auth-provider"
    }
}

public struct KubeconfigExecConfig: Hashable, Sendable, Codable {
    public var apiVersion: String
    public var command: String
    public var args: [String]
    public var env: [ExecEnvironmentVariable]
    public var installHint: String?
    public var interactiveMode: String?

    public init(
        apiVersion: String,
        command: String,
        args: [String] = [],
        env: [ExecEnvironmentVariable] = [],
        installHint: String? = nil,
        interactiveMode: String? = nil
    ) {
        self.apiVersion = apiVersion
        self.command = command
        self.args = args
        self.env = env
        self.installHint = installHint
        self.interactiveMode = interactiveMode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try container.decode(String.self, forKey: .apiVersion)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([ExecEnvironmentVariable].self, forKey: .env) ?? []
        installHint = try container.decodeIfPresent(String.self, forKey: .installHint)
        interactiveMode = try container.decodeIfPresent(String.self, forKey: .interactiveMode)
    }
}

public struct ExecEnvironmentVariable: Hashable, Sendable, Codable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct KubeconfigAuthProvider: Hashable, Sendable, Codable {
    public var name: String
    public var config: [String: String]

    public init(name: String, config: [String: String] = [:]) {
        self.name = name
        self.config = config
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        config = try container.decodeIfPresent([String: String].self, forKey: .config) ?? [:]
    }
}

extension Kubeconfig {
    /// One row per context, with the cluster and user details the picker needs to
    /// tell two similarly named contexts apart (PRD §9.1).
    public var contextSummaries: [KubeconfigContextSummary] {
        contexts.map { entry in
            KubeconfigContextSummary(
                contextName: entry.name,
                clusterName: entry.value.cluster,
                server: cluster(named: entry.value.cluster)?.server,
                userName: entry.value.user,
                namespace: entry.value.namespace ?? ClusterConnection.defaultNamespaceName,
                isCurrent: entry.name == currentContext
            )
        }
    }
}

public struct KubeconfigContextSummary: Hashable, Sendable, Identifiable {
    public let contextName: String
    public let clusterName: String
    public let server: String?
    public let userName: String
    public let namespace: String
    public let isCurrent: Bool

    public var id: String { contextName }

    public init(
        contextName: String,
        clusterName: String,
        server: String?,
        userName: String,
        namespace: String,
        isCurrent: Bool
    ) {
        self.contextName = contextName
        self.clusterName = clusterName
        self.server = server
        self.userName = userName
        self.namespace = namespace
        self.isCurrent = isCurrent
    }
}
