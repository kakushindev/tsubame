import Foundation
import KubeModels

public struct DiffLine: Hashable, Sendable {
    public enum Change: Hashable, Sendable { case unchanged, added, removed }
    public let change: Change
    public let text: String
}

public enum ResourceDiff {
    /// A linear-space diff over stable YAML. Large edits use a whole-block diff
    /// rather than an unbounded quadratic LCS table.
    public static func between(_ before: JSONValue?, _ after: JSONValue?) throws -> [DiffLine] {
        let parser = ManifestParser()
        let old = try before.map { try parser.yaml(from: $0).components(separatedBy: "\n") } ?? []
        let new = try after.map { try parser.yaml(from: $0).components(separatedBy: "\n") } ?? []
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        return old.prefix(prefix).map { DiffLine(change: .unchanged, text: $0) }
            + old[prefix..<(old.count - suffix)].map { DiffLine(change: .removed, text: $0) }
            + new[prefix..<(new.count - suffix)].map { DiffLine(change: .added, text: $0) }
            + new.suffix(suffix).map { DiffLine(change: .unchanged, text: $0) }
    }

    /// Only root metadata and root status are server-owned. A nested spec.status
    /// or similarly named CRD field remains part of the approved proposal.
    public static func reviewValue(_ value: JSONValue) -> JSONValue {
        guard var fields = value.objectValue else { return value }
        fields.removeValue(forKey: "status")
        if var metadata = fields["metadata"]?.objectValue {
            for key in ["resourceVersion", "generation", "managedFields", "uid", "creationTimestamp"] {
                metadata.removeValue(forKey: key)
            }
            fields["metadata"] = .object(metadata)
        }
        return .object(fields)
    }
}
