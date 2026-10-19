import Foundation
import Observation
import KubeKit
import KubeModels

@MainActor @Observable
final class ResourceActionModel {
    enum Action: String { case delete = "Delete", restart = "Restart", scale = "Scale" }
    let action: Action
    let cluster: String
    let target: WriteTarget
    let original: GenericResource
    var replicas: Int {
        didSet { rehearsal = nil; diff = [] }
    }
    private(set) var rehearsal: WriteRehearsal?
    private(set) var diff: [DiffLine] = []
    private(set) var failure: String?
    private(set) var isBusy = false
    private(set) var succeeded = false
    private let writer: ResourceWriter

    init(action: Action, cluster: String, target: WriteTarget, original: GenericResource, writer: ResourceWriter) {
        self.action = action
        self.cluster = cluster
        self.target = target
        self.original = original
        self.writer = writer
        replicas = original.raw["spec", "replicas"]?.integerValue ?? 1
    }

    func dryRun() async {
        guard !isBusy else { return }
        isBusy = true
        failure = nil
        rehearsal = nil
        defer { isBusy = false }
        do {
            let intent: WriteIntent
            switch action {
            case .delete: intent = .delete(uid: original.metadata.uid ?? "", resourceVersion: original.resourceVersion ?? "")
            case .restart: intent = .restart(at: Date())
            case .scale: intent = .scale(replicas: replicas, resourceVersion: original.resourceVersion ?? "")
            }
            let result = try await writer.rehearse(writer.plan(intent, target: target))
            try Task.checkCancellation()
            let before: JSONValue
            if action == .scale {
                before = .object(["spec": .object(["replicas": .integer(original.raw["spec", "replicas"]?.integerValue ?? 1)])])
            } else { before = original.raw }
            diff = try ResourceDiff.between(
                ResourceDiff.reviewValue(before), action == .delete ? nil : ResourceDiff.reviewValue(result.proposed)
            )
            rehearsal = result
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }

    func confirm() async {
        guard let rehearsal, !isBusy else { return }
        isBusy = true
        failure = nil
        defer { isBusy = false }
        do {
            _ = try await writer.commit(rehearsal)
            succeeded = true
            self.rehearsal = nil
        } catch {
            self.rehearsal = nil
            failure = error.localizedDescription
        }
    }
}
