import Foundation
import Observation
import KubeKit

/// Resource content is memory-only, including Secret YAML. This store deliberately
/// has no Codable, preferences, disk, or diagnostic integration.
@MainActor @Observable
final class EditorDraftStore {
    struct Key: Hashable {
        let connectionID: UUID
        let target: WriteTarget
    }
    private var drafts: [Key: String] = [:]
    var hasPendingDrafts: Bool { !drafts.isEmpty }
    func text(for key: Key) -> String? { drafts[key] }
    func save(_ text: String, for key: Key) { drafts[key] = text }
    func remove(_ key: Key) { drafts.removeValue(forKey: key) }
    func discardAll() { drafts.removeAll() }
}
