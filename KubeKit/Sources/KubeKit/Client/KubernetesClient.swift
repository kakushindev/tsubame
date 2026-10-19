import Foundation
import KubeModels

/// The read path against one cluster: send a request, map failures, decode.
///
/// Write operations live in their own type so that a view that only browses cannot
/// reach an apply or a delete by accident.
public final class KubernetesClient: Sendable {
    private let transport: any KubernetesTransport
    private let errorMapper: KubernetesErrorMapper
    private let coder: KubernetesCoder
    private let retryPolicy: RetryPolicy

    public init(
        transport: any KubernetesTransport,
        errorMapper: KubernetesErrorMapper = KubernetesErrorMapper(),
        coder: KubernetesCoder = KubernetesCoder(),
        retryPolicy: RetryPolicy = .singleRequest
    ) {
        self.transport = transport
        self.errorMapper = errorMapper
        self.coder = coder
        self.retryPolicy = retryPolicy
    }

    /// Sends a request, retrying only what the cluster said to retry.
    ///
    /// A `429` or `503` carries `Retry-After` and is honored exactly; everything
    /// else surfaces to the caller, because a repeated 403 or 409 needs the user.
    public func send(_ request: APIRequest) async throws -> Data {
        try await perform(request).body
    }

    /// The full response, including headers.
    ///
    /// A dry-run's `Warning:` headers are part of what the user is asked to review,
    /// so the write path needs the response rather than just the body.
    public func perform(_ request: APIRequest) async throws -> APIResponse {
        var attempt = 0
        while true {
            let response = try await transport.send(request)
            if response.isSuccess { return response }

            let error = errorMapper.error(
                statusCode: response.statusCode,
                headers: response.headers,
                body: response.body
            )
            guard case .throttled(let retryAfter, _) = error,
                  retryPolicy.shouldRetry(attempt: attempt)
            else {
                throw error
            }
            attempt += 1
            // Cancellation during the wait is cancellation, not a cluster failure:
            // `CancellationError` propagates untouched.
            try await Task.sleep(for: .seconds(retryAfter))
        }
    }

    /// A line stream carrying the client's error mapping.
    ///
    /// Pod logs go through this rather than the transport directly, so a 403 on a
    /// log request becomes `.permissionDenied` exactly as it does for a list.
    public func stream(_ request: APIRequest) async throws -> AsyncThrowingStream<Data, any Error> {
        try await transport.lines(for: request)
    }

    public func get<Object: ResourceObject & Codable>(
        _ resource: GroupVersionResource,
        namespace: String?,
        name: String,
        as type: Object.Type = Object.self
    ) async throws -> Object {
        let data = try await send(
            APIRequest(method: .get, path: resource.objectPath(namespace: namespace, name: name))
        )
        return try decode(Object.self, from: data)
    }

    /// Fetches one page. The returned `continueToken` drives the next call, and the
    /// returned `resourceVersion` is where a watch should start.
    public func list<Object: ResourceObject & Codable>(
        _ resource: GroupVersionResource,
        namespace: String?,
        options: ListOptions = ListOptions(),
        as type: Object.Type = Object.self
    ) async throws -> ResourceList<Object> {
        let data = try await send(
            APIRequest(
                method: .get,
                path: resource.collectionPath(namespace: namespace),
                queryItems: options.queryItems(watching: false)
            )
        )
        return try decode(ResourceList<Object>.self, from: data)
    }

    /// Opens a watch and yields one event per line.
    ///
    /// The stream reports `.resourceVersionExpired` rather than throwing, because a
    /// `410 Gone` is a normal instruction to relist, not a failure. Cancelling the
    /// consuming task closes the connection.
    public func watch<Object: ResourceObject & Codable>(
        _ resource: GroupVersionResource,
        namespace: String?,
        options: ListOptions,
        as type: Object.Type = Object.self
    ) async throws -> AsyncThrowingStream<WatchEvent<Object>, any Error> {
        let lines = try await transport.lines(
            for: APIRequest(
                method: .get,
                path: resource.collectionPath(namespace: namespace),
                queryItems: options.queryItems(watching: true),
                timeout: nil
            )
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines where !line.isEmpty {
                        continuation.yield(try self.decodeWatchEvent(line, as: Object.self))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func decodeWatchEvent<Object: ResourceObject & Codable>(
        _ line: Data,
        as type: Object.Type
    ) throws -> WatchEvent<Object> {
        let envelope = try decode(WatchEventEnvelope.self, from: line)
        switch envelope.type {
        case "ERROR":
            let status = try? coder.decoder.decode(KubernetesStatus.self, from: envelope.objectData)
            if status?.code == 410 || status?.reason == "Expired" {
                return .resourceVersionExpired
            }
            throw errorMapper.error(
                statusCode: status?.code ?? 500,
                headers: [:],
                body: envelope.objectData
            )
        case "BOOKMARK":
            let object = try decode(GenericResource.self, from: envelope.objectData)
            guard let resourceVersion = object.metadata.resourceVersion else {
                throw KubernetesError.decodingFailure(reason: "A bookmark event carried no resourceVersion.")
            }
            return .bookmark(resourceVersion: resourceVersion)
        case "ADDED":
            return .added(try decode(Object.self, from: envelope.objectData))
        case "MODIFIED":
            return .modified(try decode(Object.self, from: envelope.objectData))
        case "DELETED":
            return .deleted(try decode(Object.self, from: envelope.objectData))
        default:
            throw KubernetesError.decodingFailure(reason: "Unknown watch event type '\(envelope.type)'.")
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try coder.decoder.decode(type, from: data)
        } catch {
            throw KubernetesError.decodingFailure(reason: String(describing: error))
        }
    }
}

/// The `{type:, object:}` wrapper on every watch line. The object is kept as raw
/// bytes so it can be decoded as the caller's type, or as a `Status` on an error.
private struct WatchEventEnvelope: Decodable {
    let type: String
    let objectData: Data

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        let object = try container.decode(JSONValue.self, forKey: .object)
        objectData = try JSONEncoder().encode(object)
    }

    private enum CodingKeys: String, CodingKey {
        case type, object
    }
}
