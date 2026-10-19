import Foundation

/// A Kubernetes kind the app models explicitly.
///
/// A typed model knows its own identity, so it does not depend on the payload
/// carrying `apiVersion` and `kind` — which items inside a `List` response never do.
/// Kinds without a typed model are still handled, as `GenericResource`; the two sit
/// side by side behind `ResourceObject` so one list and watch path serves both.
public protocol TypedResource: ResourceObject, Codable, Hashable {
    /// What this model always is, whatever the payload says.
    static var typeIdentity: GroupVersionKind { get }
    /// The plural REST name. Discovery is authoritative; this lets a caller build a
    /// request before discovery has answered.
    static var resourceName: String { get }
    static var isNamespaced: Bool { get }
}

extension TypedResource {
    public var groupVersionKind: GroupVersionKind { Self.typeIdentity }

    public static var groupVersionResource: GroupVersionResource {
        GroupVersionResource(
            groupVersion: typeIdentity.groupVersion,
            resource: resourceName,
            isNamespaced: isNamespaced
        )
    }

    /// Nothing to resolve: a typed model fills its own type in while decoding, so
    /// `raw` is already complete by the time a list hands its type down.
    public func resolvingType(_ groupVersionKind: GroupVersionKind) -> Self { self }
}

extension JSONValue {
    /// Returns this object with `apiVersion` and `kind` filled in when absent.
    ///
    /// A `List` reply states the item type once, at the top, and omits it from every
    /// item. Without this, the YAML view of an object opened from a list would be
    /// missing the two fields the same object shows when fetched on its own — and a
    /// manifest built from it would be rejected by the server, which is the bug this
    /// exists to prevent. Typed models apply it while decoding, so it costs one
    /// dictionary check per item rather than a re-decode.
    public func addingTypeFields(_ groupVersionKind: GroupVersionKind) -> JSONValue {
        guard var fields = objectValue else { return self }
        guard fields["apiVersion"] == nil || fields["kind"] == nil else { return self }
        fields["apiVersion"] = .string(groupVersionKind.groupVersion.apiVersion)
        fields["kind"] = .string(groupVersionKind.kind)
        return .object(fields)
    }
}
