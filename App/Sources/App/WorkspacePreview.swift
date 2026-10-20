#if DEBUG
import Foundation
import SwiftUI
import KubeKit
import KubeModels

/// Synthetic, opt-in fixtures for the actual connections and workspace views.
struct WorkspacePreview: View {
    let connected: Bool
    private let environment: AppEnvironment
    @State private var clusters: ClusterListModel

    init(connected: Bool) {
        self.connected = connected
        let environment = AppEnvironment(
            credentialStore: EphemeralCredentialStore(), kubeconfigParser: KubeconfigParser(),
            kubeconfigDiscovery: NoKubeconfigDiscovery(), clientIdentities: nil, execRunner: nil,
            clientFactory: { _ in KubernetesClient(transport: WorkspacePreviewTransport()) }
        )
        self.environment = environment
        let model = ClusterListModel(environment: environment)
        model.importKubeconfig(text: Self.configuration)
        _clusters = State(initialValue: model)
    }

    var body: some View {
        WorkspaceView(clusters: clusters, environment: environment, previewAutoConnect: connected, isInterfacePreview: true)
    }

    private static let configuration = """
    apiVersion: v1
    kind: Config
    current-context: kind-local
    clusters:
      - name: Local development
        cluster: {server: 'https://127.0.0.1:6443'}
      - name: Staging US
        cluster: {server: 'https://staging.example.invalid:6443'}
      - name: Production EU
        cluster: {server: 'https://production.example.invalid:6443'}
    contexts:
      - name: kind-local
        context: {cluster: Local development, user: local-developer, namespace: development}
      - name: staging-us
        context: {cluster: Staging US, user: platform-team, namespace: staging}
      - name: production-eu
        context: {cluster: Production EU, user: read-only, namespace: production}
    users:
      - name: local-developer
        user: {token: synthetic-preview-token}
      - name: platform-team
        user: {token: synthetic-preview-token}
      - name: read-only
        user: {token: synthetic-preview-token}
    """
}

private actor WorkspacePreviewTransport: KubernetesTransport {
    private static let kinds: [(String, String, String, Bool)] = [
        ("", "pods", "Pod", true), ("", "services", "Service", true), ("", "configmaps", "ConfigMap", true),
        ("", "secrets", "Secret", true), ("", "namespaces", "Namespace", false), ("", "events", "Event", true),
        ("apps", "deployments", "Deployment", true), ("apps", "statefulsets", "StatefulSet", true), ("apps", "daemonsets", "DaemonSet", true),
        ("batch", "jobs", "Job", true), ("batch", "cronjobs", "CronJob", true),
    ]

    func send(_ request: APIRequest) async throws -> APIResponse {
        let result: JSONValue
        switch request.path {
        case "/api": result = .object(["versions": .array([.string("v1")])])
        case "/apis":
            result = .object(["groups": .array(["apps", "batch"].map { group in
                .object(["name": .string(group), "versions": .array([.object(["groupVersion": .string(group + "/v1"), "version": .string("v1")])]),
                         "preferredVersion": .object(["groupVersion": .string(group + "/v1"), "version": .string("v1")])])
            })])
        case "/api/v1", "/apis/apps/v1", "/apis/batch/v1":
            let group = request.path == "/api/v1" ? "" : String(request.path.split(separator: "/")[1])
            var resources: [JSONValue] = Self.kinds.filter { $0.0 == group }.map { _, name, kind, namespaced in
                .object(["name": .string(name), "singularName": .string(kind.lowercased()), "kind": .string(kind),
                         "namespaced": .bool(namespaced), "verbs": .array(["get", "list", "watch", "patch", "delete"].map(JSONValue.string))])
            }
            if group.isEmpty {
                resources.append(.object(["name": .string("pods/log"), "kind": .string("Pod"), "namespaced": .bool(true), "verbs": .array([.string("get")])]))
            }
            result = .object(["groupVersion": .string(group.isEmpty ? "v1" : group + "/v1"), "resources": .array(resources)])
        default:
            if let body = request.body, let value = try? ManifestParser().parse(String(decoding: body, as: UTF8.self)) {
                result = value
            } else if request.path == "/api/v1/namespaces" {
                let names = ["default", "development", "kube-system", "staging"]
                    + (1...40).map { String(format: "team-%02d", $0) }
                result = .object(["apiVersion": .string("v1"), "kind": .string("NamespaceList"),
                                  "metadata": .object(["resourceVersion": .string("42")]),
                                  "items": .array(names.map { .object(["metadata": .object(["name": .string($0)])]) })])
            } else if request.path.hasSuffix("/pods") {
                result = .object(["apiVersion": .string("v1"), "kind": .string("PodList"),
                                  "metadata": .object(["resourceVersion": .string("42")]), "items": .array(Self.pods)])
            } else if let pod = Self.pods.first(where: { request.path.hasSuffix("/" + ($0["metadata", "name"]?.stringValue ?? "")) }) {
                result = pod
            } else {
                let name = request.path.split(separator: "/").last.map(String.init) ?? ""
                let kind = Self.kinds.first { $0.1 == name }?.2 ?? "Resource"
                result = .object(["apiVersion": .string("v1"), "kind": .string(kind + "List"),
                                  "metadata": .object(["resourceVersion": .string("42")]), "items": .array([])])
            }
        }
        return APIResponse(statusCode: 200, headers: [:], body: try JSONEncoder().encode(result))
    }

    func lines(for request: APIRequest) async throws -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { output in
            if request.path.hasSuffix("/log") {
                for text in ["Starting API server", "Listening on port 8080", "GET /health 200 2ms"] {
                    output.yield(Data("2026-10-19T10:00:00Z \(text)".utf8))
                }
            }
        }
    }

    private static var pods: [JSONValue] {
        let names = ["api-server-7d8f9b6c4-k2x9p", "api-server-7d8f9b6c4-n7q4m", "web-frontend-64f89bc5d-h8s2t",
                     "web-frontend-64f89bc5d-w3j6r", "worker-queue-59c6d8b7f-m4v9x", "worker-queue-59c6d8b7f-p8a2k",
                     "redis-cache-0", "postgres-primary-0", "metrics-agent-4n6xp", "image-processor-6b8d9f4c2-q7w3z"]
        return names.enumerated().map { index, name in
            let waiting = index == 9
            let phase = index == 5 ? "Pending" : "Running"
            return .object([
                "apiVersion": .string("v1"), "kind": .string("Pod"),
                "metadata": .object(["name": .string(name), "namespace": .string("development"), "uid": .string("preview-\(index)"),
                                     "resourceVersion": .string("42"), "creationTimestamp": .string(Date().addingTimeInterval(-Double(7200 + index * 1400)).ISO8601Format()),
                                     "labels": .object(["app": .string(name.components(separatedBy: "-").first ?? name), "environment": .string("development")])]),
                "spec": .object(["nodeName": .string(index < 5 ? "kind-worker" : "kind-worker2"),
                                 "containers": .array([.object(["name": .string("app"), "image": .string("example/api:latest")])])]),
                "status": .object(["phase": .string(phase), "containerStatuses": .array([
                    .object(["name": .string("app"), "ready": .bool(!waiting && phase == "Running"), "restartCount": .integer(waiting ? 5 : 0),
                             "state": waiting ? .object(["waiting": .object(["reason": .string("ImagePullBackOff")])]) : .object(["running": .object([:])])])
                ])]),
            ])
        }
    }
}
#endif
