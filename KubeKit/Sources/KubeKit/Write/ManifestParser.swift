import Foundation
import KubeModels
import Yams

public enum ManifestError: Error, LocalizedError, Sendable, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let reason) = self { return reason }
        return nil
    }
}

/// Parses exactly one document without narrowing fields through a typed model.
/// Multi-document policy remains a PRD §15 decision; it cannot be silently truncated.
public struct ManifestParser: Sendable {
    public init() {}

    public func parse(_ text: String) throws -> JSONValue {
        let node: Node
        do {
            guard let root = try compose(yaml: text) else { throw ManifestError.invalid("Enter a YAML object.") }
            node = root
        } catch let error as ManifestError { throw error }
        catch {
            // YAML errors can embed full source lines. Keep resource content in
            // the draft, not in an error which may become a diagnostic later.
            throw ManifestError.invalid("Invalid YAML or multiple documents. Review the syntax and edit one object at a time.")
        }
        let value = try json(node, depth: 0)
        guard value.objectValue != nil else { throw ManifestError.invalid("The manifest must be a YAML mapping.") }
        return value
    }

    public func yaml(from value: JSONValue) throws -> String {
        try serialize(node: node(value, root: true), indent: 2, width: -1, allowUnicode: true)
    }

    private func json(_ node: Node, depth: Int) throws -> JSONValue {
        guard depth < 100 else { throw ManifestError.invalid("The manifest is nested too deeply.") }
        switch node {
        case .mapping(let mapping):
            var fields: [String: JSONValue] = [:]
            for pair in mapping {
                guard pair.key.tag == Tag(.str), let key = pair.key.string else {
                    throw ManifestError.invalid("Mapping keys must be strings. Quote numeric and boolean keys.")
                }
                guard fields[key] == nil else { throw ManifestError.invalid("Duplicate mapping keys are not allowed.") }
                fields[key] = try json(pair.value, depth: depth + 1)
            }
            return .object(fields)
        case .sequence(let sequence): return .array(try sequence.map { try json($0, depth: depth + 1) })
        case .alias: throw ManifestError.invalid("Expand YAML aliases before reviewing this object.")
        case .scalar(let scalar):
            switch node.tag {
            case Tag(.null): return .null
            case Tag(.bool):
                guard let value = node.bool else { throw ManifestError.invalid("Invalid boolean value.") }
                return .bool(value)
            case Tag(.int):
                guard let value = node.int else { throw ManifestError.invalid("An integer exceeds the supported range.") }
                return .integer(value)
            case Tag(.float):
                guard let value = node.float, value.isFinite else { throw ManifestError.invalid("Numbers must be finite.") }
                return .number(value)
            case Tag(.str), Tag(.timestamp): return .string(scalar.string)
            default: throw ManifestError.invalid("This YAML tag cannot be represented in a Kubernetes JSON object.")
            }
        }
    }

    private func node(_ value: JSONValue, root: Bool = false) -> Node {
        switch value {
        case .null: return Node("null", Tag(.null))
        case .bool(let value): return Node(value ? "true" : "false", Tag(.bool))
        case .integer(let value): return Node(String(value), Tag(.int))
        case .number(let value): return Node(String(value), Tag(.float))
        case .string(let value): return Node(value, Tag(.str), .doubleQuoted)
        case .array(let values): return Node(values.map { node($0) })
        case .object(let fields):
            let order = ["apiVersion", "kind", "metadata", "spec", "status"]
            let keys = fields.keys.sorted {
                if root {
                    let a = order.firstIndex(of: $0) ?? order.count
                    let b = order.firstIndex(of: $1) ?? order.count
                    if a != b { return a < b }
                }
                return $0 < $1
            }
            return Node(keys.map { (Node($0, Tag(.str)), node(fields[$0]!)) })
        }
    }
}
