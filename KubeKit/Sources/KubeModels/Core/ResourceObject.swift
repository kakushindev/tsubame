import Foundation

/// A decoded Kubernetes object.
///
/// Every object the app handles conforms to this, whether it has a typed model or
/// only a generic one. Views read identity through the protocol and fall back to
/// `raw` for anything a typed model does not cover.
public protocol ResourceObject: Sendable, Identifiable {
    var groupVersionKind: GroupVersionKind { get }
    var metadata: ObjectMeta { get }
    var raw: JSONValue { get }

    /// Fills in the type a list response left off this item.
    ///
    /// A `List` reply carries `apiVersion` and `kind` once, at the top, and omits
    /// both from every item. A typed model knows its own type and ignores this; a
    /// generic one has nothing else to go on, so `ResourceList` hands it down.
    func resolvingType(_ groupVersionKind: GroupVersionKind) -> Self
}

extension ResourceObject {
    /// A typed model's type is a property of the model, not of the payload.
    public func resolvingType(_ groupVersionKind: GroupVersionKind) -> Self { self }
}

extension ResourceObject {
    public var id: String {
        metadata.uid ?? "\(groupVersionKind.kind)/\(metadata.namespace ?? "-")/\(metadata.name)"
    }

    public var name: String { metadata.name }
    public var namespace: String? { metadata.namespace }
    public var resourceVersion: String? { metadata.resourceVersion }
}

/// The generic representation used for custom resources, discovered kinds without a
/// typed model, and the raw YAML view of any object.
public struct GenericResource: ResourceObject, Hashable, Codable {
    public let groupVersionKind: GroupVersionKind
    public let metadata: ObjectMeta
    public let raw: JSONValue

    public init(groupVersionKind: GroupVersionKind, metadata: ObjectMeta, raw: JSONValue) {
        self.groupVersionKind = groupVersionKind
        self.metadata = metadata
        self.raw = raw
    }

    /// Decodes an object, taking its type from the payload when the payload has
    /// one. Items inside a list do not: there the type arrives afterwards, through
    /// `resolvingType(_:)`, and until then `groupVersionKind.kind` is empty.
    public init(from decoder: any Decoder) throws {
        let raw = try JSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.groupVersionKind = GroupVersionKind(
            apiVersion: raw["apiVersion"]?.stringValue ?? "",
            kind: raw["kind"]?.stringValue ?? ""
        )
        self.metadata = try container.decode(ObjectMeta.self, forKey: .metadata)
        self.raw = raw
    }

    /// Adopts the list's type, and writes it into `raw` as well, so a YAML view of
    /// an object that came from a list shows the same `apiVersion` and `kind` as a
    /// YAML view of the same object fetched on its own.
    public func resolvingType(_ groupVersionKind: GroupVersionKind) -> GenericResource {
        guard self.groupVersionKind.kind.isEmpty else { return self }
        var fields = raw.objectValue ?? [:]
        fields["apiVersion"] = .string(groupVersionKind.groupVersion.apiVersion)
        fields["kind"] = .string(groupVersionKind.kind)
        return GenericResource(
            groupVersionKind: groupVersionKind,
            metadata: metadata,
            raw: .object(fields)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        try raw.encode(to: encoder)
    }

    private enum CodingKeys: String, CodingKey {
        case metadata
    }
}
