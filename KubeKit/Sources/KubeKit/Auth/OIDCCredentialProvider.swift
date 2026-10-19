import CryptoKit
import Foundation
import KubeModels

/// What a cluster's OIDC sign-in needs. A redirect URI is part of it because the
/// kubeconfig cannot supply one: it belongs to the app, not the cluster.
public struct OIDCConfiguration: Hashable, Sendable, Codable {
    public var issuer: URL
    public var clientID: String
    /// Public clients omit this. PKCE is used either way.
    public var clientSecret: String?
    public var scopes: [String]
    public var redirectURI: URL

    public init(
        issuer: URL,
        clientID: String,
        clientSecret: String? = nil,
        scopes: [String] = ["openid", "profile", "email", "offline_access"],
        redirectURI: URL
    ) {
        self.issuer = issuer
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.redirectURI = redirectURI
    }
}

/// The browser half of an authorization-code flow.
///
/// A protocol because presenting a sign-in window is the app's job:
/// `ASWebAuthenticationSession` lives in the app target, and KubeKit imports no UI
/// framework.
public protocol OIDCAuthorizing: Sendable {
    func authorize(_ request: OIDCAuthorizationRequest) async throws -> String
}

public struct OIDCAuthorizationRequest: Hashable, Sendable {
    public let authorizationURL: URL
    public let redirectURI: URL

    public init(authorizationURL: URL, redirectURI: URL) {
        self.authorizationURL = authorizationURL
        self.redirectURI = redirectURI
    }
}

/// What the issuer publishes at `/.well-known/openid-configuration`.
public struct OIDCProviderMetadata: Hashable, Sendable, Codable {
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL

    private enum CodingKeys: String, CodingKey {
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
    }
}

/// The tokens an issuer returns. Held only in protected storage.
struct OIDCTokens: Hashable, Sendable, Codable {
    /// Kubernetes authenticates the **ID token**, not the access token. Sending the
    /// access token is the most common way an otherwise correct OIDC setup fails.
    var idToken: String
    var refreshToken: String?
    var expiresAt: Date?
}

/// Signs in through an OIDC issuer and keeps the ID token current.
public actor OIDCCredentialProvider: CredentialProvider {
    private let configuration: OIDCConfiguration
    private let reference: CredentialReference
    private let store: any CredentialStore
    private let authorizer: any OIDCAuthorizing
    private let transport: any KubernetesTransport
    private let now: @Sendable () -> Date

    private var metadata: OIDCProviderMetadata?
    private var tokens: OIDCTokens?
    /// In-flight refresh, shared by every caller that arrives during it. Without
    /// this, a list and three watches resuming together would each spend the
    /// refresh token, and all but one would be rejected.
    private var refreshInFlight: Task<OIDCTokens, any Error>?

    public init(
        configuration: OIDCConfiguration,
        reference: CredentialReference,
        store: any CredentialStore,
        authorizer: any OIDCAuthorizing,
        transport: any KubernetesTransport,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.reference = reference
        self.store = store
        self.authorizer = authorizer
        self.transport = transport
        self.now = now
    }

    public func authenticationHeaders() async throws -> [String: String] {
        let tokens = try await currentTokens()
        return ["Authorization": "Bearer \(tokens.idToken)"]
    }

    public func invalidate() async {
        tokens = nil
    }

    /// Drops the refresh token too, so the next use signs in afresh. Used when a
    /// cluster is removed and when a refresh is rejected.
    public func signOut() async {
        tokens = nil
        refreshInFlight?.cancel()
        refreshInFlight = nil
        try? await store.removeCredential(for: reference)
    }

    // MARK: - Tokens

    private func currentTokens() async throws -> OIDCTokens {
        if tokens == nil { tokens = try await loadStoredTokens() }

        if let held = tokens, !isExpiring(held) { return held }

        if let existing = refreshInFlight {
            return try await existing.value
        }
        if let held = tokens, let refreshToken = held.refreshToken {
            let task = Task { try await refresh(using: refreshToken) }
            refreshInFlight = task
            defer { refreshInFlight = nil }
            do {
                let refreshed = try await task.value
                tokens = refreshed
                try await persist(refreshed)
                return refreshed
            } catch {
                // A refresh token the issuer will not accept is not retryable, and
                // retrying it in a loop is how an app wedges on a 401. Drop both
                // tokens so the user is asked to sign in instead.
                await signOut()
                throw KubernetesError.unauthenticated(status: nil)
            }
        }

        let fresh = try await signIn()
        tokens = fresh
        try await persist(fresh)
        return fresh
    }

    private func isExpiring(_ tokens: OIDCTokens) -> Bool {
        guard let expiresAt = tokens.expiresAt else { return false }
        // A minute of headroom, so a token cannot expire between the check and the
        // request that uses it.
        return now().addingTimeInterval(60) >= expiresAt
    }

    private func loadStoredTokens() async throws -> OIDCTokens? {
        guard let data = try await store.credential(for: reference) else { return nil }
        return try? JSONDecoder().decode(OIDCTokens.self, from: data)
    }

    private func persist(_ tokens: OIDCTokens) async throws {
        try await store.store(JSONEncoder().encode(tokens), for: reference)
    }

    // MARK: - Flows

    private func signIn() async throws -> OIDCTokens {
        let metadata = try await providerMetadata()
        let verifier = Self.randomCodeVerifier()

        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: Self.randomCodeVerifier()),
            // PKCE regardless of whether the client has a secret: the redirect can
            // be observed on both platforms.
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ])
        components?.queryItems = items
        guard let authorizationURL = components?.url else {
            throw KubernetesError.invalidConfiguration(
                reason: "The issuer's authorization endpoint could not be used."
            )
        }

        let code = try await authorizer.authorize(
            OIDCAuthorizationRequest(
                authorizationURL: authorizationURL,
                redirectURI: configuration.redirectURI
            )
        )
        return try await exchange(parameters: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": configuration.redirectURI.absoluteString,
            "code_verifier": verifier,
        ])
    }

    private func refresh(using refreshToken: String) async throws -> OIDCTokens {
        try await exchange(parameters: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
    }

    private func exchange(parameters: [String: String]) async throws -> OIDCTokens {
        let metadata = try await providerMetadata()
        var fields = parameters
        fields["client_id"] = configuration.clientID
        if let secret = configuration.clientSecret { fields["client_secret"] = secret }

        var body = URLComponents()
        body.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        let encoded = body.percentEncodedQuery ?? ""

        let response = try await transport.send(
            APIRequest(
                method: .post,
                path: metadata.tokenEndpoint.path,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: Data(encoded.utf8)
            )
        )
        guard response.isSuccess else {
            throw KubernetesError.unauthenticated(status: nil)
        }

        struct TokenResponse: Decodable {
            let idToken: String
            let refreshToken: String?
            let expiresIn: Int?

            private enum CodingKeys: String, CodingKey {
                case idToken = "id_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }
        let decoded: TokenResponse
        do {
            decoded = try JSONDecoder().decode(TokenResponse.self, from: response.body)
        } catch {
            throw KubernetesError.decodingFailure(
                reason: "The issuer's response did not contain an ID token."
            )
        }
        return OIDCTokens(
            idToken: decoded.idToken,
            // An issuer may decline to rotate the refresh token, in which case the
            // existing one stays valid.
            refreshToken: decoded.refreshToken ?? tokens?.refreshToken,
            expiresAt: decoded.expiresIn.map { now().addingTimeInterval(TimeInterval($0)) }
        )
    }

    private func providerMetadata() async throws -> OIDCProviderMetadata {
        if let metadata { return metadata }
        let response = try await transport.send(
            APIRequest(method: .get, path: "/.well-known/openid-configuration")
        )
        guard response.isSuccess else {
            throw KubernetesError.invalidConfiguration(
                reason: "The issuer at \(configuration.issuer.absoluteString) did not publish "
                    + "an OpenID configuration."
            )
        }
        let decoded = try JSONDecoder().decode(OIDCProviderMetadata.self, from: response.body)
        metadata = decoded
        return decoded
    }

    // MARK: - PKCE

    static func randomCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

extension Data {
    /// base64url, as RFC 7636 requires for PKCE: a standard base64 challenge is
    /// rejected by a conforming issuer.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
