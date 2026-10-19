import Foundation
import Observation
import KubeKit
import KubeModels

@MainActor @Observable
final class YAMLEditorModel {
    enum State {
        case editing, dryRunning, reviewed, applying, applied
        case rejected(String), conflict(String)
    }
    var text: String {
        didSet {
            guard text != oldValue else { return }
            revision += 1
            rehearsal = nil
            diff = []
            state = .editing
            if text == original { drafts.remove(key) } else { drafts.save(text, for: key) }
        }
    }
    private(set) var state: State = .editing
    private(set) var rehearsal: WriteRehearsal?
    private(set) var diff: [DiffLine] = []
    let target: WriteTarget
    let cluster: String
    private var original: String
    private var base: JSONValue
    private let writer: ResourceWriter
    private let drafts: EditorDraftStore
    private let key: EditorDraftStore.Key
    private var revision = 0

    init(cluster: String, key: EditorDraftStore.Key, original: JSONValue, writer: ResourceWriter, drafts: EditorDraftStore) {
        self.cluster = cluster
        self.key = key
        self.target = key.target
        self.base = original
        let source = (try? ManifestParser().yaml(from: original)) ?? ""
        self.original = source
        self.writer = writer
        self.drafts = drafts
        self.text = drafts.text(for: key) ?? source
    }

    var isBusy: Bool {
        switch state { case .dryRunning, .applying: true; default: false }
    }
    var hasChanges: Bool { drafts.text(for: key) != nil }

    func dryRun() async {
        guard !isBusy else { return }
        let current = revision
        state = .dryRunning
        rehearsal = nil
        do {
            let plan = try writer.plan(.apply(manifest: text), target: target)
            let result = try await writer.rehearse(plan)
            try Task.checkCancellation()
            guard current == revision else { return }
            try review(result)
        } catch is CancellationError { if current == revision { state = .editing } }
        catch { if current == revision { fail(error) } }
    }

    func apply() async {
        guard case .reviewed = state, let rehearsal else { return }
        let current = revision
        state = .applying
        do {
            let response = try await writer.commit(rehearsal)
            guard current == revision else { return }
            // A second edit is based on the successful write, even when the user
            // chooses text which happened to match the first version they opened.
            original = text
            base = (try? JSONDecoder().decode(JSONValue.self, from: response.body)) ?? rehearsal.proposed
            drafts.remove(key)
            self.rehearsal = nil
            state = .applied
        } catch WriteError.changedSinceRehearsal(let next) {
            guard current == revision else { return }
            // A changed proposal cannot remain in the approvable state. A new
            // dry-run is required and the existing draft remains untouched.
            self.rehearsal = nil
            diff = (try? ResourceDiff.between(base, next.proposed)) ?? []
            state = .conflict("The server result changed. Run dry-run again and review the new proposal.")
        } catch is CancellationError {
            self.rehearsal = nil
            state = .rejected("The request was interrupted. Reload the resource to check its state before trying again.")
        } catch { if current == revision { fail(error) } }
    }

    func discard() { drafts.remove(key) }

    private func review(_ result: WriteRehearsal) throws {
        diff = try ResourceDiff.between(ResourceDiff.reviewValue(base), ResourceDiff.reviewValue(result.proposed))
        rehearsal = result
        state = .reviewed
    }

    private func fail(_ error: any Error) {
        rehearsal = nil
        if case WriteError.fieldOwnershipConflict = error { state = .conflict(error.localizedDescription) }
        else { state = .rejected(error.localizedDescription) }
    }
}
