import Foundation
import KubeModels

/// The `URLSession` implementation of `KubernetesTransport`.
///
/// One instance serves one cluster: the server URL, TLS settings, and client
/// identity are fixed at init, because they come from the same kubeconfig entry and
/// a change to any of them is a different connection.
public final class URLSessionTransport: NSObject, KubernetesTransport, @unchecked Sendable {
    private let serverURL: URL
    private let credentialProvider: any CredentialProvider
    private let trustEvaluator: ServerTrustEvaluator
    private let errorMapper: KubernetesErrorMapper
    private let redactor: CredentialRedactor
    private let proxy: ProxyConfiguration?
    /// Set when a proxy was configured that this platform cannot apply. Every
    /// request then fails with it, because the alternative — connecting directly —
    /// quietly ignores something the user asked for.
    private let proxyFailure: KubernetesError?
    private lazy var session: URLSession = {
        let configuration = Self.baseConfiguration()
        configuration.connectionProxyDictionary = proxyDictionary()
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// A second session for watches and log follows.
    ///
    /// `timeoutIntervalForRequest` is an *inter-packet* timeout, not a total one, so
    /// the 60-second default kills a watch on a namespace that simply has nothing to
    /// report — and the client then reports a permanent reconnect loop that reads as
    /// a server fault. A stream's liveness is governed by `ListOptions.timeoutSeconds`
    /// and watch bookmarks instead, so both timeouts are effectively disabled here.
    private lazy var streamingSession: URLSession = {
        let configuration = Self.baseConfiguration()
        configuration.connectionProxyDictionary = proxyDictionary()
        configuration.timeoutIntervalForRequest = Self.streamingTimeout
        configuration.timeoutIntervalForResource = Self.streamingTimeout
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private static func baseConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return configuration
    }

    /// A week. Long enough that no healthy stream reaches it, finite so a wedged
    /// one is eventually reclaimed.
    private static let streamingTimeout: TimeInterval = 7 * 24 * 60 * 60

    public init(
        serverURL: URL,
        credentialProvider: any CredentialProvider,
        tls: TLSConfiguration,
        proxy: ProxyConfiguration? = nil,
        platform: HostPlatform = .current,
        errorMapper: KubernetesErrorMapper = KubernetesErrorMapper(),
        redactor: CredentialRedactor = CredentialRedactor()
    ) {
        self.serverURL = serverURL
        self.credentialProvider = credentialProvider
        self.trustEvaluator = ServerTrustEvaluator(configuration: tls)
        self.errorMapper = errorMapper
        self.redactor = redactor
        self.proxy = proxy
        if let proxy, !proxy.isSupported(on: platform) {
            self.proxyFailure = .invalidConfiguration(
                reason: "This cluster is configured to use the proxy \(proxy.displayName), "
                    + "which \(platform == .macOS ? "macOS" : "iOS and iPadOS") cannot apply. "
                    + "Connecting without it would ignore a setting you asked for, so the "
                    + "connection is refused instead."
            )
        } else {
            self.proxyFailure = nil
        }
    }

    /// Proxy settings for a `URLSessionConfiguration`.
    ///
    /// String keys rather than the `kCFNetworkProxies…` constants, because the SOCKS
    /// ones do not exist on iOS — the values are the same either way.
    private func proxyDictionary() -> [AnyHashable: Any]? {
        guard let proxy, let host = proxy.host else { return nil }
        switch proxy.kind {
        case .http:
            return ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": proxy.port]
        case .https:
            return ["HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": proxy.port]
        case .socks5:
            return ["SOCKSEnable": 1, "SOCKSProxy": host, "SOCKSPort": proxy.port]
        }
    }

    public func send(_ request: APIRequest) async throws -> APIResponse {
        if let proxyFailure { throw proxyFailure }
        let urlRequest = try await urlRequest(for: request)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw KubernetesError.decodingFailure(reason: "The response was not an HTTP response.")
            }
            return APIResponse(
                statusCode: http.statusCode,
                headers: Self.headerFields(of: http),
                body: data
            )
        } catch let error as KubernetesError {
            throw error
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            throw mapped(error)
        }
    }

    public func lines(for request: APIRequest) async throws -> AsyncThrowingStream<Data, any Error> {
        do {
            return try await openLines(for: request)
        } catch let error as KubernetesError {
            throw error
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            throw mapped(error)
        }
    }

    private func openLines(for request: APIRequest) async throws -> AsyncThrowingStream<Data, any Error> {
        if let proxyFailure { throw proxyFailure }
        var streaming = request
        streaming.timeout = nil
        let urlRequest = try await urlRequest(for: streaming)

        let (byteStream, response) = try await streamingSession.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            byteStream.task.cancel()
            throw KubernetesError.decodingFailure(reason: "The response was not an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            defer { byteStream.task.cancel() }
            // A failed stream still carries a Status body; read it before giving up.
            var body = Data()
            for try await byte in byteStream {
                body.append(byte)
                if body.count >= APIRequest.defaultMaximumLineLength { break }
            }
            throw errorMapper.error(
                statusCode: http.statusCode,
                headers: Self.headerFields(of: http),
                body: body
            )
        }

        let limit = request.maximumLineLength
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let task = Task {
                defer { byteStream.task.cancel() }
                var chunker = LineChunker(maximumLineLength: limit)
                do {
                    for try await byte in byteStream {
                        try Task.checkCancellation()
                        if let line = chunker.consume(byte),
                           case .dropped = continuation.yield(line) {
                            // Never silently skip watch events or log output. The
                            // caller resumes from its last consumed version/time.
                            continuation.finish(throwing: KubernetesError.streamInterrupted(
                                underlying: "The stream exceeded the consumer's buffer; reconnecting."
                            ))
                            return
                        }
                    }
                    // A stream may end mid-line; that partial line is still data the
                    // caller asked for.
                    if let trailing = chunker.flush(), case .dropped = continuation.yield(trailing) {
                        continuation.finish(throwing: KubernetesError.streamInterrupted(
                            underlying: "The stream exceeded the consumer's buffer; reconnecting."
                        ))
                        return
                    }
                    continuation.finish()
                } catch {
                    // A cancelled stream is a closed view, not a failure: finish
                    // quietly rather than handing the consumer an error to render.
                    guard !Self.isCancellation(error) else {
                        continuation.finish()
                        return
                    }
                    continuation.finish(throwing: self.mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel(); byteStream.task.cancel() }
        }
    }

    private func urlRequest(for request: APIRequest) async throws -> URLRequest {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw KubernetesError.invalidConfiguration(reason: "The server URL could not be read.")
        }
        components.path = request.path
        components.queryItems = request.queryItems.isEmpty ? nil : request.queryItems
        guard let url = components.url else {
            throw KubernetesError.invalidConfiguration(reason: "The request path could not be built.")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        if let timeout = request.timeout {
            urlRequest.timeoutInterval = timeout
        }
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        for (field, value) in try await credentialProvider.authenticationHeaders() {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        return urlRequest
    }

    /// Whether a failure is this task being cancelled rather than anything the
    /// cluster did. `URLSession` reports cancellation as a `URLError`, so without
    /// this a closed view would surface as a network failure and be rendered as one.
    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func mapped(_ error: any Error) -> KubernetesError {
        let message = redactor.redact((error as NSError).localizedDescription)
        guard let urlError = error as? URLError else {
            return .networkUnreachable(underlying: message)
        }
        switch urlError.code {
        case .clientCertificateRejected, .clientCertificateRequired:
            // The server's certificate is not the problem here: the cluster asked
            // this app for a certificate it could not present. Reporting it as a
            // trust failure sends the user to check the wrong end of the handshake.
            return .invalidConfiguration(
                reason: "This cluster requires a client certificate that could not be "
                    + "presented. Import the context again, or check that its "
                    + "certificate and key are still in the kubeconfig. (\(message))"
            )
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .secureConnectionFailed:
            return .tlsTrustFailure(underlying: message)
        case .networkConnectionLost, .timedOut:
            return .streamInterrupted(underlying: message)
        default:
            return .networkUnreachable(underlying: message)
        }
    }

    private static func headerFields(of response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [:]) { result, entry in
            guard let field = entry.key as? String, let value = entry.value as? String else { return }
            result[field] = value
        }
    }
}

extension URLSessionTransport: URLSessionTaskDelegate {
    /// Task-level challenges, which is where `bytes(for:)` delivers them.
    ///
    /// Without this, watches and log streams fell back to default handling and
    /// rejected every cluster using a private certificate authority — while plain
    /// requests, which arrive at the session-level method below, succeeded. One
    /// transport answering two different ways depending on the call was the whole
    /// bug; both now resolve to the same evaluator.
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await urlSession(session, didReceive: challenge)
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            return trustEvaluator.evaluate(challenge)
        case NSURLAuthenticationMethodClientCertificate:
            guard let credential = credentialProvider.clientCertificateCredential() else {
                return (.performDefaultHandling, nil)
            }
            return (.useCredential, credential)
        default:
            return (.performDefaultHandling, nil)
        }
    }
}
