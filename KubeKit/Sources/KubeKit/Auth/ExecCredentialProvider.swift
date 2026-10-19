import Foundation
import KubeModels

/// Runs an exec credential plugin. Implemented outside KubeKit, because spawning a
/// process is a platform capability and one iOS does not have at all.
public protocol ExecPluginRunning: Sendable {
    func run(_ invocation: ExecPluginInvocation) async throws -> ExecCredentialStatus
}

public struct ExecPluginInvocation: Hashable, Sendable {
    /// Absolute, and resolved once at import time. `PATH` is never consulted again
    /// when the plugin runs, so the binary the user approved is the binary that
    /// executes.
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    /// `KUBERNETES_EXEC_INFO`, when the plugin asked for cluster information.
    public let standardInput: Data?
    /// A hung plugin must not hang the view that triggered it.
    public let timeout: TimeInterval

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        standardInput: Data? = nil,
        timeout: TimeInterval = 30
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.standardInput = standardInput
        self.timeout = timeout
    }
}

/// What a plugin printed, in the `ExecCredential` shape the API defines.
public struct ExecCredentialStatus: Hashable, Sendable, Codable {
    public var token: String?
    public var clientCertificateData: String?
    public var clientKeyData: String?
    public var expirationTimestamp: Date?

    public init(
        token: String? = nil,
        clientCertificateData: String? = nil,
        clientKeyData: String? = nil,
        expirationTimestamp: Date? = nil
    ) {
        self.token = token
        self.clientCertificateData = clientCertificateData
        self.clientKeyData = clientKeyData
        self.expirationTimestamp = expirationTimestamp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.nestedContainer(keyedBy: StatusKeys.self, forKey: .status)
        token = try status.decodeIfPresent(String.self, forKey: .token)
        clientCertificateData = try status.decodeIfPresent(
            String.self, forKey: .clientCertificateData)
        clientKeyData = try status.decodeIfPresent(String.self, forKey: .clientKeyData)
        expirationTimestamp = try status.decodeIfPresent(String.self, forKey: .expirationTimestamp)
            .flatMap(RFC3339.date(from:))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var status = container.nestedContainer(keyedBy: StatusKeys.self, forKey: .status)
        try status.encodeIfPresent(token, forKey: .token)
        try status.encodeIfPresent(clientCertificateData, forKey: .clientCertificateData)
        try status.encodeIfPresent(clientKeyData, forKey: .clientKeyData)
    }

    private enum CodingKeys: String, CodingKey { case status }
    private enum StatusKeys: String, CodingKey {
        case token, clientCertificateData, clientKeyData, expirationTimestamp
    }
}

/// Asks the user whether a plugin may run. The app presents this; KubeKit only
/// states that it must happen (PRD §9.1).
public protocol ExecApprovalGranting: Sendable {
    func decision(for request: ExecApprovalRequest) async -> ExecApprovalDecision
}

public enum ExecApprovalDecision: Hashable, Sendable {
    case denied
    case allowOnce
    /// Remembered against the command's fingerprint, so pointing the kubeconfig at
    /// a different binary asks again.
    case allowUntilCommandChanges
}

/// Refuses every plugin. Used on iOS and iPadOS, where there is no process to run
/// and the UI must not imply otherwise.
public struct DecliningExecApproval: ExecApprovalGranting {
    public init() {}
    public func decision(for request: ExecApprovalRequest) async -> ExecApprovalDecision { .denied }
}

/// Obtains a credential by running an approved kubeconfig exec plugin.
///
/// The credential is held only in memory and only until it expires: a plugin exists
/// precisely because the credential is short-lived, so writing it to storage would
/// keep a stale copy of something designed to rotate.
public actor ExecCredentialProvider: CredentialProvider {
    private let request: ExecApprovalRequest
    private let runner: any ExecPluginRunning
    private let approvals: any ExecApprovalGranting
    private let environment: [String: String]
    private let now: @Sendable () -> Date

    private var cached: ExecCredentialStatus?
    private var approvedFingerprint: String?

    public init(
        request: ExecApprovalRequest,
        runner: any ExecPluginRunning,
        approvals: any ExecApprovalGranting,
        environment: [String: String] = [:],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.request = request
        self.runner = runner
        self.approvals = approvals
        self.environment = environment
        self.now = now
    }

    public func authenticationHeaders() async throws -> [String: String] {
        if let cached, !isExpired(cached), let token = cached.token {
            return ["Authorization": "Bearer \(token)"]
        }

        guard let executable = request.resolvedExecutableURL else {
            throw KubernetesError.invalidConfiguration(
                reason: "\(request.command) is not installed, so this cluster's credential "
                    + "plugin cannot run."
                    + (request.installHint.map { " \($0)" } ?? "")
            )
        }

        if approvedFingerprint != request.fingerprint {
            switch await approvals.decision(for: request) {
            case .denied:
                throw KubernetesError.unsupportedAuthentication(
                    method: "Exec credential plugin (not approved)",
                    platform: .current
                )
            case .allowOnce:
                break
            case .allowUntilCommandChanges:
                approvedFingerprint = request.fingerprint
            }
        }

        let status = try await runner.run(
            ExecPluginInvocation(
                executableURL: executable,
                arguments: request.arguments,
                environment: environment
            )
        )
        guard let token = status.token else {
            throw KubernetesError.unsupportedAuthentication(
                method: "Exec credential plugin returning a client certificate",
                platform: .current
            )
        }
        cached = status
        return ["Authorization": "Bearer \(token)"]
    }

    public func invalidate() async {
        // The next request re-runs the plugin, which is the behaviour a rejected
        // credential calls for.
        cached = nil
    }

    private func isExpired(_ status: ExecCredentialStatus) -> Bool {
        guard let expiry = status.expirationTimestamp else { return false }
        // Refresh a minute early, so a credential cannot expire mid-flight.
        return now().addingTimeInterval(60) >= expiry
    }
}
