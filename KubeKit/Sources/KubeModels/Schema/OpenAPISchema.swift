import Foundation

/// The part of a CRD's OpenAPI schema this app can act on.
///
/// Deliberately a subset. Everything it does not model becomes `.opaque`, and a
/// view renders that subtree generically rather than guessing — a schema-driven
/// field built on a half-understood constraint is worse than an honest text box.
public indirect enum OpenAPISchema: Hashable, Sendable {
    case object(ObjectSchema)
    case array(items: OpenAPISchema?, description: String?)
    case scalar(ScalarSchema)
    /// `x-kubernetes-preserve-unknown-fields`, `x-kubernetes-int-or-string`, a
    /// `$ref`, a composition keyword, or anything else outside the subset.
    case opaque(description: String?)

    public init(_ json: JSONValue) {
        // A schema that says "anything may be here" is exactly the case to stop
        // interpreting and show the raw value.
        if json["x-kubernetes-preserve-unknown-fields"] == .bool(true)
            || json["x-kubernetes-int-or-string"] == .bool(true)
            || json["$ref"] != nil
            || json["allOf"] != nil || json["anyOf"] != nil || json["oneOf"] != nil {
            self = .opaque(description: json["description"]?.stringValue)
            return
        }

        let description = json["description"]?.stringValue
        switch json["type"]?.stringValue {
        case "object":
            let properties = (json["properties"]?.objectValue ?? [:])
                .mapValues(OpenAPISchema.init(_:))
            self = .object(ObjectSchema(
                description: description,
                properties: properties,
                required: Set((json["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            ))
        case "array":
            self = .array(items: json["items"].map(OpenAPISchema.init(_:)), description: description)
        case .some(let type):
            self = .scalar(ScalarSchema(
                type: type,
                format: json["format"]?.stringValue,
                description: description,
                allowedValues: json["enum"]?.arrayValue ?? [],
                defaultValue: json["default"],
                pattern: json["pattern"]?.stringValue
            ))
        case nil:
            // No type and no properties is a schema that describes nothing.
            if let properties = json["properties"]?.objectValue {
                self = .object(ObjectSchema(
                    description: description,
                    properties: properties.mapValues(OpenAPISchema.init(_:)),
                    required: Set((json["required"]?.arrayValue ?? []).compactMap(\.stringValue))
                ))
            } else {
                self = .opaque(description: description)
            }
        }
    }

    public var description: String? {
        switch self {
        case .object(let schema): schema.description
        case .array(_, let description): description
        case .scalar(let schema): schema.description
        case .opaque(let description): description
        }
    }

    /// The schema describing a field path, or nil where the schema says nothing.
    public func schema(at path: [String]) -> OpenAPISchema? {
        guard let head = path.first else { return self }
        switch self {
        case .object(let schema):
            return schema.properties[head]?.schema(at: Array(path.dropFirst()))
        case .array(let items, _):
            // An index into an array describes the element.
            guard Int(head) != nil, let items else { return nil }
            return items.schema(at: Array(path.dropFirst()))
        case .scalar, .opaque:
            return nil
        }
    }
}

public struct ObjectSchema: Hashable, Sendable {
    public let description: String?
    public let properties: [String: OpenAPISchema]
    public let required: Set<String>
}

public struct ScalarSchema: Hashable, Sendable {
    public let type: String
    public let format: String?
    public let description: String?
    /// The `enum` values, which are the whole reason a schema-driven editor can
    /// offer a picker instead of a text field.
    public let allowedValues: [JSONValue]
    public let defaultValue: JSONValue?
    public let pattern: String?
}
