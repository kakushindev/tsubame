import Foundation

/// A CRD, as far as browsing its resources needs it.
///
/// Enough to list a custom resource well: what it is called, whether it is
/// namespaced, which versions are served, and what columns the author wants
/// shown. The schema is kept where one is published, and its absence is a
/// fallback rather than an error (PRD §9.2).
public struct CustomResourceDefinition: TypedResource {
    public static let typeIdentity = GroupVersionKind(
        apiVersion: "apiextensions.k8s.io/v1", kind: "CustomResourceDefinition"
    )
    public static let resourceName = "customresourcedefinitions"
    public static let isNamespaced = false

    public let metadata: ObjectMeta
    public let raw: JSONValue
    public let group: String
    public let names: Names
    public let scope: Scope
    public let versions: [Version]

    public struct Names: Hashable, Sendable {
        public let plural: String
        public let singular: String
        public let kind: String
        public let shortNames: [String]
        public let categories: [String]
    }

    public enum Scope: String, Hashable, Sendable {
        case namespaced = "Namespaced"
        case cluster = "Cluster"
    }

    public struct Version: Hashable, Sendable {
        public let name: String
        public let served: Bool
        public let storage: Bool
        public let deprecated: Bool
        public let deprecationWarning: String?
        /// `nil` when the definition publishes no schema, which is common and
        /// means the generic view rather than a failure.
        public let schema: OpenAPISchema?
        public let additionalPrinterColumns: [PrinterColumn]
        public let subresources: Set<String>
    }

    public init(from decoder: any Decoder) throws {
        self.raw = try JSONValue(from: decoder).addingTypeFields(Self.typeIdentity)
        let c = try decoder.container(keyedBy: Key.self)
        self.metadata = try c.decode(ObjectMeta.self, forKey: .metadata)
        self.group = raw["spec", "group"]?.stringValue ?? ""
        self.scope = Scope(rawValue: raw["spec", "scope"]?.stringValue ?? "") ?? .namespaced

        let names = raw["spec", "names"]
        self.names = Names(
            plural: names?["plural"]?.stringValue ?? "",
            singular: names?["singular"]?.stringValue ?? "",
            kind: names?["kind"]?.stringValue ?? "",
            shortNames: names?["shortNames"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            categories: names?["categories"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )

        self.versions = (raw["spec", "versions"]?.arrayValue ?? []).map { entry in
            var subresources: Set<String> = []
            if entry["subresources", "status"] != nil { subresources.insert("status") }
            if entry["subresources", "scale"] != nil { subresources.insert("scale") }
            return Version(
                name: entry["name"]?.stringValue ?? "",
                served: entry["served"] != .bool(false),
                storage: entry["storage"] == .bool(true),
                deprecated: entry["deprecated"] == .bool(true),
                deprecationWarning: entry["deprecationWarning"]?.stringValue,
                schema: entry["schema", "openAPIV3Schema"].map(OpenAPISchema.init(_:)),
                additionalPrinterColumns: (entry["additionalPrinterColumns"]?.arrayValue ?? [])
                    .compactMap(PrinterColumn.init(json:)),
                subresources: subresources
            )
        }
    }

    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
    private enum Key: String, CodingKey { case metadata }

    public var servedVersions: [Version] { versions.filter(\.served) }
    public var storageVersion: Version? { versions.first(\.storage) }

    /// The version a browser should use: the stored one, else the first served.
    public var preferredVersion: Version? { storageVersion ?? servedVersions.first }

    public func groupVersionResource(version: String) -> GroupVersionResource {
        GroupVersionResource(
            groupVersion: GroupVersion(group: group, version: version),
            resource: names.plural,
            isNamespaced: scope == .namespaced
        )
    }

    public func groupVersionKind(version: String) -> GroupVersionKind {
        GroupVersionKind(groupVersion: GroupVersion(group: group, version: version), kind: names.kind)
    }
}

extension Sequence {
    fileprivate func first(_ keyPath: KeyPath<Element, Bool>) -> Element? {
        first { $0[keyPath: keyPath] }
    }
}

extension PrinterColumn {
    /// Builds a column straight from the definition's own JSON.
    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue,
              let path = json["jsonPath"]?.stringValue ?? json["JSONPath"]?.stringValue
        else { return nil }
        self.init(
            name: name,
            type: ColumnType(rawValue: json["type"]?.stringValue ?? "string") ?? .string,
            description: json["description"]?.stringValue,
            jsonPath: path,
            priority: json["priority"]?.integerValue ?? 0
        )
    }
}
