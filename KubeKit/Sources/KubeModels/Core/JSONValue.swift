import Foundation

/// The generic representation of any Kubernetes object field.
///
/// Typed models cover the core kinds. Everything else — custom resources, unknown
/// fields on known kinds, and the raw payload behind a YAML view — is carried as
/// `JSONValue` so the API representation survives a decode/encode round trip.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as JSON."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// Reads a nested value by key path, e.g. `["spec", "replicas"]`.
    public subscript(path: String...) -> JSONValue? {
        var current: JSONValue? = self
        for key in path {
            guard case .object(let fields)? = current else { return nil }
            current = fields[key]
        }
        return current
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var integerValue: Int? {
        switch self {
        case .integer(let value): return value
        case .number(let value): return Int(exactly: value.rounded())
        default: return nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}
