import Foundation
import KubeModels

/// Every failure KubeKit surfaces.
///
/// Cases are the distinctions the UI has to act on, not a transcription of HTTP
/// status codes: a view decides what to show from the case, and shows
/// `errorDescription` only as supporting detail.
public enum KubernetesError: Error, Hashable, Sendable {
    /// The kubeconfig or connection settings could not produce a usable request.
    case invalidConfiguration(reason: String)
    /// DNS, connectivity, or timeout before a response arrived.
    case networkUnreachable(underlying: String)
    /// The server certificate was not trusted.
    case tlsTrustFailure(underlying: String)
    /// 401: no credential, or the credential is expired or malformed.
    case unauthenticated(status: KubernetesStatus?)
    /// 403: authenticated, but RBAC denies this verb on this resource.
    /// Must be shown as a denial, never as an empty result.
    case permissionDenied(status: KubernetesStatus?)
    /// 404 on a specific object or endpoint.
    case notFound(status: KubernetesStatus?)
    /// 409: the object changed, or a Server-Side Apply field-ownership conflict.
    case conflict(status: KubernetesStatus?)
    /// 410: the `resourceVersion` is too old. The caller must relist.
    case resourceVersionExpired(status: KubernetesStatus?)
    /// 422 and other server-side validation failures.
    case invalidRequest(status: KubernetesStatus?)
    /// 429 or 503 with a `Retry-After` the client must honor.
    case throttled(retryAfter: TimeInterval, status: KubernetesStatus?)
    /// Any other non-success response.
    case serverError(code: Int, status: KubernetesStatus?)
    /// The response body did not match the expected shape.
    case decodingFailure(reason: String)
    /// The credential type exists in kubeconfig but this platform cannot use it.
    case unsupportedAuthentication(method: String, platform: HostPlatform)
    /// The watch stream ended without the client cancelling it.
    case streamInterrupted(underlying: String)

    /// Whether retrying the identical request could succeed without user action.
    public var isTransient: Bool {
        switch self {
        case .networkUnreachable, .throttled, .streamInterrupted:
            return true
        case .serverError(let code, _):
            return code >= 500
        default:
            return false
        }
    }
}

extension KubernetesError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            return "The cluster configuration is not usable: \(reason)"
        case .networkUnreachable(let underlying):
            return "Could not reach the cluster: \(underlying)"
        case .tlsTrustFailure(let underlying):
            return "The cluster's certificate was not trusted: \(underlying)"
        case .unauthenticated:
            return "The credential for this cluster was rejected. It may have expired."
        case .permissionDenied(let status):
            return status?.message ?? "Your Kubernetes permissions do not allow this action."
        case .notFound(let status):
            return status?.message ?? "The requested resource no longer exists."
        case .conflict(let status):
            return status?.message ?? "The object changed on the server. Review the change again."
        case .resourceVersionExpired:
            return "The cluster's change history moved on. Reloading the list."
        case .invalidRequest(let status):
            return status?.message ?? "The cluster rejected the request as invalid."
        case .throttled(let retryAfter, _):
            return "The cluster asked to slow down. Retrying in \(Int(retryAfter))s."
        case .serverError(let code, let status):
            return status?.message ?? "The cluster returned an error (HTTP \(code))."
        case .decodingFailure(let reason):
            return "The cluster's response could not be read: \(reason)"
        case .unsupportedAuthentication(let method, let platform):
            return "\(method) authentication is not supported on \(platform == .macOS ? "macOS" : "iOS and iPadOS")."
        case .streamInterrupted(let underlying):
            return "The live connection was interrupted: \(underlying)"
        }
    }
}

/// Builds `KubernetesError` values from HTTP responses.
///
/// Mapping lives here rather than in the transport so it can be tested without a
/// network, and so one table defines the behavior for every call site.
public struct KubernetesErrorMapper: Sendable {
    private let decoder: JSONDecoder

    public init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    public func error(
        statusCode: Int,
        headers: [String: String],
        body: Data
    ) -> KubernetesError {
        let status = try? decoder.decode(KubernetesStatus.self, from: body)
        switch statusCode {
        case 401:
            return .unauthenticated(status: status)
        case 403:
            return .permissionDenied(status: status)
        case 404:
            return .notFound(status: status)
        case 409:
            return .conflict(status: status)
        case 410:
            return .resourceVersionExpired(status: status)
        case 422:
            return .invalidRequest(status: status)
        case 429, 503:
            return .throttled(retryAfter: retryAfter(in: headers, status: status), status: status)
        default:
            return .serverError(code: statusCode, status: status)
        }
    }

    /// `Retry-After` is authoritative when present; the fallbacks keep a missing or
    /// unparsable header from turning into an unbounded retry loop.
    private func retryAfter(in headers: [String: String], status: KubernetesStatus?) -> TimeInterval {
        let header = headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }?.value
        if let header, let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)) {
            return max(0, seconds)
        }
        if let seconds = status?.details?.retryAfterSeconds {
            return TimeInterval(seconds)
        }
        return 1
    }
}
