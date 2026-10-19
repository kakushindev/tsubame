import Foundation
import KubeModels

public struct PodLogTarget: Hashable, Sendable {
    public let namespace: String
    public let pod: String
    public let container: String

    public init(namespace: String, pod: String, container: String) {
        self.namespace = namespace
        self.pod = pod
        self.container = container
    }
}

public struct PodLogOptions: Hashable, Sendable {
    public var previous: Bool
    public var follow: Bool
    public var tailLines: Int
    public var sinceTime: String?

    public init(previous: Bool = false, follow: Bool = true, tailLines: Int = 500, sinceTime: String? = nil) {
        self.previous = previous
        self.follow = follow && !previous
        self.tailLines = max(1, min(tailLines, 10_000))
        self.sinceTime = sinceTime
    }

    func request(for target: PodLogTarget, resumingFrom timestamp: String?) -> APIRequest {
        let pods = GroupVersionResource(groupVersion: .core, resource: "pods", isNamespaced: true)
        var query = [
            URLQueryItem(name: "container", value: target.container),
            URLQueryItem(name: "timestamps", value: "true"),
            URLQueryItem(name: "follow", value: follow && !previous ? "true" : "false"),
            URLQueryItem(name: "previous", value: previous ? "true" : "false"),
        ]
        if let timestamp = timestamp ?? sinceTime {
            query.append(URLQueryItem(name: "sinceTime", value: timestamp))
        } else {
            query.append(URLQueryItem(name: "tailLines", value: String(tailLines)))
        }
        return APIRequest(
            method: .get,
            path: pods.subresourcePath(namespace: target.namespace, name: target.pod, subresource: "log"),
            queryItems: query, timeout: nil, maximumLineLength: APIRequest.logMaximumLineLength
        )
    }
}
