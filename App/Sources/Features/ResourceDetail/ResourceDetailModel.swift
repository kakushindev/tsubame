import Foundation
import Observation
import KubeKit
import KubeModels

@MainActor @Observable
final class ResourceDetailModel {
    private(set) var object: GenericResource?
    private(set) var failure: String?
    private(set) var loadedAt: Date?
    private let client: KubernetesClient
    let target: WriteTarget

    init(client: KubernetesClient, target: WriteTarget) {
        self.client = client
        self.target = target
    }

    func load() async {
        do {
            let object = try await client.get(target.resource.groupVersionResource, namespace: target.namespace, name: target.name, as: GenericResource.self)
            try Task.checkCancellation()
            self.object = object
            loadedAt = Date()
            failure = nil
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }

    var yaml: String { object.flatMap { try? ManifestParser().yaml(from: $0.raw) } ?? "" }
    var secret: Secret? {
        guard target.resource.groupVersion.group.isEmpty, target.resource.kind == "Secret",
              let raw = object?.raw, let data = try? JSONEncoder().encode(raw) else { return nil }
        return try? KubernetesCoder().decoder.decode(Secret.self, from: data)
    }
}
