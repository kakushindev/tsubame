#if DEBUG
import Foundation
import SwiftUI
import KubeKit
import KubeModels

/// Opt-in, synthetic launch fixtures for simulator layout checks. No network or
/// protected storage is reachable from these screens; release builds omit them.
struct WorkflowPreview: View {
    let mode: String
    @State private var drafts = EditorDraftStore()

    var body: some View {
        let client = KubernetesClient(transport: PreviewTransport())
        let writer = ResourceWriter(client: client)
        let resource = DiscoveredResource(
            groupVersionResource: .init(groupVersion: .init(group: "apps", version: "v1"), resource: "deployments", isNamespaced: true),
            kind: "Deployment", singularName: "deployment", verbs: ["patch", "delete"], subresources: ["scale"]
        )
        let target = WriteTarget(resource: resource, namespace: "default", name: "example-api")
        let raw = try! ManifestParser().parse(Self.manifest)
        switch mode {
        case "--preview-connections": WorkspacePreview(connected: false)
        case "--preview-workspace": WorkspacePreview(connected: true)
        case "--preview-logs":
            LogsView(model: LogsModel(cluster: "Preview · synthetic cluster", pod: Self.pod, client: client))
        case "--preview-actions":
            ResourceActionView(model: ResourceActionModel(action: .scale, cluster: "Preview · synthetic cluster", target: target,
                                                         original: try! KubernetesCoder().decoder.decode(GenericResource.self, from: JSONEncoder().encode(raw)), writer: writer))
        default:
            YAMLEditorView(model: YAMLEditorModel(cluster: "Preview · synthetic cluster", key: .init(connectionID: UUID(), target: target),
                                                 original: raw, writer: writer, drafts: drafts))
        }
    }

    private static let manifest = """
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: example-api
      namespace: default
    spec:
      replicas: 2
      selector:
        matchLabels:
          app: example-api
      template:
        metadata:
          labels:
            app: example-api
        spec:
          containers:
            - name: web
              image: nginx:1.27
              ports:
                - containerPort: 80
    """

    private static var pod: GenericResource {
        try! KubernetesCoder().decoder.decode(GenericResource.self, from: Data("""
        {"apiVersion":"v1","kind":"Pod","metadata":{"name":"example-api-7c9f","namespace":"default"},
        "spec":{"containers":[{"name":"web"},{"name":"sidecar"}]},
        "status":{"containerStatuses":[{"name":"web","lastState":{"terminated":{"exitCode":1}}}]}}
        """.utf8))
    }

    private actor PreviewTransport: KubernetesTransport {
        func send(_ request: APIRequest) async throws -> APIResponse {
            let raw = try ManifestParser().parse(String(decoding: request.body ?? Data(), as: UTF8.self))
            return APIResponse(statusCode: 200, headers: [:], body: try JSONEncoder().encode(raw))
        }
        func lines(for request: APIRequest) async throws -> AsyncThrowingStream<Data, any Error> {
            AsyncThrowingStream { output in
                let lines = ["Starting example API", "Listening on port 8080", "GET /health 200 2ms", "GET /api/resources 200 14ms"]
                for (index, line) in lines.enumerated() {
                    output.yield(Data("2026-10-19T10:00:0\(index)Z \(line)".utf8))
                }
                // The synthetic live stream stays open until the screen closes.
            }
        }
    }
}
#endif
