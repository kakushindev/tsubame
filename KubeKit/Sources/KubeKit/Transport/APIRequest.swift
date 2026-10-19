import Foundation
import KubeModels

/// A request against the Kubernetes API, described independently of `URLSession` so
/// the call sites above the transport stay testable.
public struct APIRequest: Hashable, Sendable {
    public enum Method: String, Hashable, Sendable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    /// The content type of a `patch` body. Server-Side Apply uses `apply`.
    public enum PatchKind: String, Hashable, Sendable {
        case apply = "application/apply-patch+yaml"
        case merge = "application/merge-patch+json"
        case strategicMerge = "application/strategic-merge-patch+json"
        case json = "application/json-patch+json"
    }

    public var method: Method
    /// Server-relative path, e.g. `/apis/apps/v1/namespaces/default/deployments`.
    public var path: String
    public var queryItems: [URLQueryItem]
    public var headers: [String: String]
    public var body: Data?
    /// `nil` for a stream; a stream must not be subject to a response timeout.
    public var timeout: TimeInterval?
    /// The longest line a streaming response may buffer before it is cut.
    ///
    /// The bound has to live here, below the log and watch layers, because a line
    /// that grows without a terminator grows in the transport's buffer. A limit set
    /// only above this point would describe memory it does not control.
    public var maximumLineLength: Int

    public init(
        method: Method,
        path: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval? = 30,
        maximumLineLength: Int = APIRequest.defaultMaximumLineLength
    ) {
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.maximumLineLength = maximumLineLength
    }

    /// Generous, because a watch event is one JSON object per line and a large
    /// object is legitimate.
    public static let defaultMaximumLineLength = 1 << 20
    /// Tighter, because a log line past this is already past anything a person
    /// reads, and the buffer bound matters more than the tail of the line.
    public static let logMaximumLineLength = 8 * 1024

    /// Marks the request as a server-side dry run.
    ///
    /// PRD §9.4: every write is dry-run first, and the live request that follows must
    /// be the same request without this flag.
    public func dryRun() -> APIRequest {
        var copy = self
        copy.queryItems.append(URLQueryItem(name: "dryRun", value: "All"))
        return copy
    }
}

public struct APIResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}
