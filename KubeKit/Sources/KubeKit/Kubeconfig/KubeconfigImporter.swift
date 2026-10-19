import CryptoKit
import Foundation
import KubeModels

/// Turns a chosen kubeconfig context into a saved cluster plus a stored credential.
///
/// Split deliberately in two. `plan` works out what importing would do — it reads
/// files, but stores nothing and sends nothing, so a user can be shown the
/// consequences first (PRD §9.1: connection testing never writes, and the active
/// context never changes by itself). `import` is the only method that touches
/// protected storage.
public struct KubeconfigImporter: Sendable {
    /// Finds an exec plugin's executable. Injected because searching `PATH` is a
    /// platform capability, and because tests must not depend on what is installed.
    public typealias ExecutableLocating = @Sendable (String) -> URL?

    private let store: any CredentialStore
    private let fileReader: any KubeconfigFileReading
    private let platform: HostPlatform
    private let locateExecutable: ExecutableLocating

    public init(
        store: any CredentialStore,
        fileReader: any KubeconfigFileReading = LocalKubeconfigFileReader(),
        platform: HostPlatform = .current,
        locateExecutable: @escaping ExecutableLocating = KubeconfigImporter.searchPath
    ) {
        self.store = store
        self.fileReader = fileReader
        self.platform = platform
        self.locateExecutable = locateExecutable
    }

    // MARK: - Planning

    public func plan(
        contextNamed name: String,
        in kubeconfig: Kubeconfig,
        sourceDirectory: URL? = nil
    ) throws -> KubeconfigImportPlan {
        guard let context = kubeconfig.context(named: name) else {
            throw KubernetesError.invalidConfiguration(
                reason: "This kubeconfig has no context named \"\(name)\"."
            )
        }
        guard let cluster = kubeconfig.cluster(named: context.cluster) else {
            throw KubernetesError.invalidConfiguration(
                reason: "The context \"\(name)\" names the cluster \"\(context.cluster)\", "
                    + "which this kubeconfig does not define."
            )
        }
        guard let serverURL = URL(string: cluster.server), serverURL.host != nil else {
            throw KubernetesError.invalidConfiguration(
                reason: "The cluster \"\(context.cluster)\" has no usable server URL."
            )
        }

        var warnings: [KubeconfigImportPlan.Warning] = []
        var resolvedFiles: [URL] = []

        let tls = resolveTLS(
            cluster: cluster,
            sourceDirectory: sourceDirectory,
            warnings: &warnings,
            resolvedFiles: &resolvedFiles
        )

        var proxy: ProxyConfiguration?
        if let proxyURL = cluster.proxyURL, let url = URL(string: proxyURL) {
            proxy = ProxyConfiguration(url: url)
            if let proxy, !proxy.isSupported(on: platform) {
                warnings.append(.proxyUnsupportedOnPlatform(
                    proxy: proxy.displayName, platform: platform
                ))
            }
        }

        let user = kubeconfig.user(named: context.user)
        let resolved = resolveAuthentication(
            user: user,
            userName: context.user,
            contextName: name,
            sourceDirectory: sourceDirectory,
            warnings: &warnings,
            resolvedFiles: &resolvedFiles
        )

        return KubeconfigImportPlan(
            contextName: name,
            displayName: context.cluster,
            serverURL: serverURL,
            namespace: context.namespace ?? ClusterConnection.defaultNamespaceName,
            tls: tls,
            proxy: proxy,
            authenticationMethod: resolved.method,
            support: resolved.support,
            credentialUser: context.user,
            resolvedFiles: resolvedFiles,
            warnings: warnings
        )
    }

    private func resolveTLS(
        cluster: KubeconfigCluster,
        sourceDirectory: URL?,
        warnings: inout [KubeconfigImportPlan.Warning],
        resolvedFiles: inout [URL]
    ) -> TLSConfiguration {
        var authorityData: Data?

        // Inline data wins over a file reference, matching client-go. When both are
        // present and differ, say so rather than silently picking one.
        let inline = cluster.certificateAuthorityData.flatMap { Data(base64Encoded: $0) }
        var fileData: Data?
        if let path = cluster.certificateAuthority {
            do {
                fileData = try fileReader.contents(ofPath: path, relativeTo: sourceDirectory)
                if let url = try? LocalKubeconfigFileReader.resolve(
                    path: path, relativeTo: sourceDirectory
                ) {
                    resolvedFiles.append(url)
                }
            } catch {
                warnings.append(.certificateAuthorityFileUnreadable(
                    path: path, reason: error.localizedDescription
                ))
            }
        }

        if let inline, let fileData, inline != fileData {
            warnings.append(.inlineAndFileCertificateAuthorityDisagree)
        }
        authorityData = inline ?? fileData

        let insecure = cluster.insecureSkipTLSVerify ?? false
        if insecure { warnings.append(.insecureSkipTLSVerify) }

        return TLSConfiguration(
            certificateAuthorityData: authorityData,
            serverName: cluster.tlsServerName,
            allowsInsecureConnections: insecure
        )
    }

    private func resolveAuthentication(
        user: KubeconfigUser?,
        userName: String,
        contextName: String,
        sourceDirectory: URL?,
        warnings: inout [KubeconfigImportPlan.Warning],
        resolvedFiles: inout [URL]
    ) -> (method: AuthenticationMethod, support: KubeconfigImportPlan.Support) {
        guard let user else {
            return (.bearerToken, .unsupported(
                method: "None",
                platform: platform,
                reason: "The context names the user \"\(userName)\", which this kubeconfig "
                    + "does not define, so there is no credential to use."
            ))
        }

        if user.username != nil || user.password != nil {
            warnings.append(.basicAuthenticationIgnored)
        }

        // Order matters: exec and auth-provider describe how to *obtain* a
        // credential, so they take precedence over a stale inline one.
        if let exec = user.exec {
            let request = approvalRequest(for: exec, contextName: contextName)
            let method = AuthenticationMethod.execPlugin(
                command: exec.command, arguments: exec.args
            )
            guard method.isSupported(on: platform) else {
                return (method, .unsupported(
                    method: "Exec credential plugin",
                    platform: platform,
                    reason: "Running a credential plugin needs a local executable, which "
                        + "iOS and iPadOS do not provide. Use a bearer token or OIDC instead."
                ))
            }
            return (method, .requiresApproval(request))
        }

        if let provider = user.authProvider {
            warnings.append(.deprecatedAuthProvider(name: provider.name))
            if let method = oidcMethod(from: provider) {
                return (method, .needsSetup(
                    reason: "This context signs in through \(provider.name). Confirm the "
                        + "issuer, client ID and redirect URI before connecting."
                ))
            }
            return (.bearerToken, .unsupported(
                method: "auth-provider \"\(provider.name)\"",
                platform: platform,
                reason: "Tsubame does not support this auth-provider. Use a bearer token, "
                    + "a client certificate, or a supported OIDC issuer."
            ))
        }

        if user.clientCertificateData != nil || user.clientCertificate != nil {
            let method = AuthenticationMethod.clientCertificate
            guard method.isSupported(on: platform) else {
                return (method, .unsupported(
                    method: "Client certificate",
                    platform: platform,
                    reason: "Client-certificate authentication is macOS-only in this release. "
                        + "Use a bearer token or OIDC on iOS and iPadOS."
                ))
            }
            if let path = user.clientCertificate,
               let url = try? LocalKubeconfigFileReader.resolve(
                   path: path, relativeTo: sourceDirectory
               ) {
                resolvedFiles.append(url)
            }
            if let path = user.clientKey,
               let url = try? LocalKubeconfigFileReader.resolve(
                   path: path, relativeTo: sourceDirectory
               ) {
                resolvedFiles.append(url)
            }
            return (method, .supported)
        }

        if user.token != nil {
            return (.bearerToken, .supported)
        }

        if let path = user.tokenFile {
            if let url = try? LocalKubeconfigFileReader.resolve(
                path: path, relativeTo: sourceDirectory
            ) {
                resolvedFiles.append(url)
            }
            let rereading = AuthenticationMethod.tokenFile(path: path)
            if rereading.isSupported(on: platform) {
                // macOS can re-read the file, so rotation stays invisible and there
                // is nothing to warn about.
                return (rereading, .supported)
            }
            // iOS has no such file. Copy the current value and say plainly that it
            // will expire, rather than letting it fail later as an unexplained 401.
            warnings.append(.tokenFileIsASnapshot(path: path))
            return (.bearerToken, .supported)
        }

        return (.bearerToken, .unsupported(
            method: "None",
            platform: platform,
            reason: "The user \"\(userName)\" carries no credential this app can use."
        ))
    }

    private func oidcMethod(from provider: KubeconfigAuthProvider) -> AuthenticationMethod? {
        guard provider.name == "oidc",
              let issuer = provider.config["idp-issuer-url"],
              let issuerURL = URL(string: issuer),
              let clientID = provider.config["client-id"]
        else { return nil }
        let scopes = provider.config["extra-scopes"]?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? []
        return .oidc(
            issuer: issuerURL,
            clientID: clientID,
            scopes: ["openid"] + scopes
        )
    }

    private func approvalRequest(
        for exec: KubeconfigExecConfig,
        contextName: String
    ) -> ExecApprovalRequest {
        let arguments = exec.args
        let resolved = locateExecutable(exec.command)
        // The fingerprint covers the resolved path as well as the command, so a
        // kubeconfig edited to point at a different binary does not inherit an
        // approval the user gave to the original.
        var hasher = SHA256()
        hasher.update(data: Data(exec.command.utf8))
        for argument in arguments {
            hasher.update(data: Data([0]))
            hasher.update(data: Data(argument.utf8))
        }
        hasher.update(data: Data([0]))
        hasher.update(data: Data((resolved?.path ?? "<not installed>").utf8))
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        return ExecApprovalRequest(
            contextName: contextName,
            command: exec.command,
            arguments: arguments,
            environmentNames: exec.env.map(\.name),
            installHint: exec.installHint,
            resolvedExecutableURL: resolved,
            fingerprint: fingerprint
        )
    }

    /// Looks a command up in `PATH`, as a shell would.
    public static let searchPath: ExecutableLocating = { command in
        if command.contains("/") {
            let url = URL(fileURLWithPath: NSString(string: command).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - Importing

    /// Writes the credential to protected storage and returns the saved cluster.
    ///
    /// The credential is read from the document here, not carried on the plan, so it
    /// exists only for the duration of this call.
    @discardableResult
    public func `import`(
        _ plan: KubeconfigImportPlan,
        from kubeconfig: Kubeconfig,
        sourceDirectory: URL? = nil
    ) async throws -> ClusterConnection {
        if case .unsupported(let method, let platform, let reason) = plan.support {
            throw KubernetesError.unsupportedAuthentication(method: "\(method) — \(reason)", platform: platform)
        }

        let connectionID = UUID()
        let reference = CredentialReference(account: connectionID.uuidString)

        if let credential = try credentialMaterial(
            for: plan, in: kubeconfig, sourceDirectory: sourceDirectory
        ) {
            try await store.store(credential, for: reference)
        }

        return ClusterConnection(
            id: connectionID,
            displayName: plan.displayName,
            serverURL: plan.serverURL,
            contextName: plan.contextName,
            defaultNamespace: plan.namespace,
            authenticationMethod: plan.authenticationMethod,
            credentialReference: reference,
            tls: plan.tls,
            proxy: plan.proxy
        )
    }

    private func credentialMaterial(
        for plan: KubeconfigImportPlan,
        in kubeconfig: Kubeconfig,
        sourceDirectory: URL?
    ) throws -> Data? {
        guard let user = kubeconfig.user(named: plan.credentialUser) else { return nil }
        switch plan.authenticationMethod {
        case .tokenFile:
            // Nothing is stored: the provider reads the file on each request, so a
            // copy here would be a second, staler source of truth.
            return nil
        case .bearerToken:
            if let token = user.token { return Data(token.utf8) }
            if let path = user.tokenFile {
                let data = try fileReader.contents(ofPath: path, relativeTo: sourceDirectory)
                // A token file ends with a newline more often than not, and a
                // trailing newline in an Authorization header is a 401.
                let text = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Data(text.utf8)
            }
            return nil
        case .clientCertificate, .oidc, .execPlugin:
            // These providers land in M2 and own their own storage formats. Nothing
            // is written now, so no half-formed credential is left behind.
            return nil
        }
    }
}
