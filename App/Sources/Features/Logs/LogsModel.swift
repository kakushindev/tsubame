import Foundation
import Observation
import KubeKit
import KubeModels

@MainActor @Observable
final class LogsModel {
    struct Container: Identifiable, Hashable {
        let name: String
        let hasPrevious: Bool
        var id: String { name }
    }
    let cluster: String
    let namespace: String
    let podName: String
    let containers: [Container]
    var container: String
    var previous = false
    var tailLines = 500
    var showTimestamps = false
    var followOutput = true
    private(set) var snapshot: LogSnapshot?
    private(set) var isStarted = false
    private let client: KubernetesClient
    private var session: PodLogSession?
    private var operation: Task<Void, Never>?
    private var generation = 0
    private var optionsKey = ""
    private var resumeAfterBackground = false

    init(cluster: String, pod: GenericResource, client: KubernetesClient) {
        self.cluster = cluster
        namespace = pod.namespace ?? "default"
        podName = pod.name
        self.client = client
        let statuses = (pod.raw["status", "containerStatuses"]?.arrayValue ?? [])
            + (pod.raw["status", "initContainerStatuses"]?.arrayValue ?? [])
            + (pod.raw["status", "ephemeralContainerStatuses"]?.arrayValue ?? [])
        let specs = (pod.raw["spec", "containers"]?.arrayValue ?? [])
            + (pod.raw["spec", "initContainers"]?.arrayValue ?? [])
            + (pod.raw["spec", "ephemeralContainers"]?.arrayValue ?? [])
        containers = specs.compactMap { spec in
            guard let name = spec["name"]?.stringValue else { return nil }
            let previous = statuses.first { $0["name"]?.stringValue == name }?["lastState", "terminated"] != nil
            return Container(name: name, hasPrevious: previous)
        }
        container = containers.first?.name ?? ""
    }

    var canReadPrevious: Bool { containers.first { $0.name == container }?.hasPrevious == true }

    func start() {
        guard !container.isEmpty else { return }
        stop()
        isStarted = true
        let key = "\(container)/\(previous)/\(tailLines)"
        if key != optionsKey || session == nil {
            optionsKey = key
            snapshot = nil
            session = PodLogSession(
                client: client, target: PodLogTarget(namespace: namespace, pod: podName, container: container),
                options: PodLogOptions(previous: previous && canReadPrevious, tailLines: tailLines)
            )
        }
        guard let session else { return }
        let current = generation
        operation = Task {
            for await snapshot in await session.snapshots() {
                guard !Task.isCancelled, current == generation else { break }
                self.snapshot = snapshot
            }
            if current == generation { isStarted = false }
        }
    }

    func stop() {
        resumeAfterBackground = false
        generation += 1
        operation?.cancel()
        operation = nil
        isStarted = false
        // Cancellation of the snapshot consumer terminates the upstream session.
    }

    func setForeground(_ active: Bool) {
        if active {
            if resumeAfterBackground { start() }
        } else if isStarted {
            stop()
            // iOS enters inactive before background. Keep this request through
            // both transitions rather than overwriting it after we have stopped.
            resumeAfterBackground = true
        }
    }

    func selectionChanged() {
        if !canReadPrevious { previous = false }
        start()
    }
}
