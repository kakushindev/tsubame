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
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public init(
        serverURL: URL,
        credentialProvider: any CredentialProvider,
        tls: TLSConfiguration,
        errorMapper: KubernetesErrorMapper = KubernetesErrorMapper(),
        redactor: CredentialRedactor = CredentialRedactor()
    ) {
        self.serverURL = serverURL
        self.credentialProvider = credentialProvider
        self.trustEvaluator = ServerTrustEvaluator(configuration: tls)
        self.errorMapper = errorMapper
        self.redactor = redactor
    }

    public func send(_ request: APIRequest) async throws -> APIResponse {
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
            throw mapped(error)
        }
    }

    public func lines(for request: APIRequest) async throws -> AsyncThrowingStream<Data, any Error> {
        var streaming = request
        streaming.timeout = nil
        let urlRequest = try await urlRequest(for: streaming)

        let (byteStream, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw KubernetesError.decodingFailure(reason: "The response was not an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            // A failed stream still carries a Status body; read it before giving up.
            var body = Data()
            for try await byte in byteStream { body.append(byte) }
            throw errorMapper.error(
                statusCode: http.statusCode,
                headers: Self.headerFields(of: http),
                body: body
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in byteStream.lines {
                        continuation.yield(Data(line.utf8))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: self.mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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

    private func mapped(_ error: any Error) -> KubernetesError {
        let message = redactor.redact((error as NSError).localizedDescription)
        guard let urlError = error as? URLError else {
            return .networkUnreachable(underlying: message)
        }
        switch urlError.code {
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .secureConnectionFailed,
             .clientCertificateRejected,
             .clientCertificateRequired:
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
