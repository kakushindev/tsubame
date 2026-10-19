import Foundation

/// A `ResourceObject` with its concrete type erased.
///
/// One browse screen has to drive a watch over `Pod` and a watch over
/// `GenericResource` without knowing which it got. Erasing here, above the client,
/// is what lets `KubernetesClient` and `ResourceWatcher` stay generic and untouched.
///
/// `unwrap(_:)` recovers the typed model where there is one, so a detail view can
/// ask for `pod.status.containerStatuses` while a YAML view just reads `raw`.
public struct AnyResourceObject: ResourceObject, Hashable, Sendable {
    public let groupVersionKind: GroupVersionKind
    public let metadata: ObjectMeta
    public let raw: JSONValue
    private let base: AnySendableBox

    public init<Object: ResourceObject>(_ object: Object) {
        if let erased = object as? AnyResourceObject {
            self = erased
            return
        }
        self.groupVersionKind = object.groupVersionKind
        self.metadata = object.metadata
        self.raw = object.raw
        self.base = AnySendableBox(object)
    }

    /// The typed model, when this was erased from one.
    public func unwrap<Object: ResourceObject>(_ type: Object.Type = Object.self) -> Object? {
        base.value as? Object
    }

    public func resolvingType(_ groupVersionKind: GroupVersionKind) -> AnyResourceObject {
        guard self.groupVersionKind.kind.isEmpty else { return self }
        return AnyResourceObject(
            groupVersionKind: groupVersionKind,
            metadata: metadata,
            raw: raw.addingTypeFields(groupVersionKind),
            base: base
        )
    }

    private init(
        groupVersionKind: GroupVersionKind,
        metadata: ObjectMeta,
        raw: JSONValue,
        base: AnySendableBox
    ) {
        self.groupVersionKind = groupVersionKind
        self.metadata = metadata
        self.raw = raw
        self.base = base
    }

    /// Identity is the object's identity, not the box's: two erasures of the same
    /// object are the same row.
    public static func == (lhs: AnyResourceObject, rhs: AnyResourceObject) -> Bool {
        lhs.groupVersionKind == rhs.groupVersionKind
            && lhs.metadata == rhs.metadata
            && lhs.raw == rhs.raw
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(groupVersionKind)
        hasher.combine(metadata)
        hasher.combine(raw)
    }

    private struct AnySendableBox: @unchecked Sendable {
        let value: any Sendable
        init(_ value: any Sendable) { self.value = value }
    }
}
