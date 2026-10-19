import Foundation

/// A single page of a list response, with the continuation data the client needs to
/// page through large collections and to start a watch from the right point.
public struct ResourceList<Element: ResourceObject & Codable>: Sendable, Codable {
    public let items: [Element]
    public let resourceVersion: String?
    public let continueToken: String?
    public let remainingItemCount: Int?
    /// Items on this page that could not be decoded.
    ///
    /// One malformed or unexpected object must not cost the user the whole page —
    /// it would read as "this namespace is empty", which PRD §9.2 forbids. The
    /// count travels so the UI can say the page is partial instead.
    public let undecodableItemCount: Int

    public init(
        items: [Element],
        resourceVersion: String?,
        continueToken: String?,
        remainingItemCount: Int? = nil,
        undecodableItemCount: Int = 0
    ) {
        self.items = items
        self.resourceVersion = resourceVersion
        self.continueToken = continueToken
        self.remainingItemCount = remainingItemCount
        self.undecodableItemCount = undecodableItemCount
    }

    public var isPartial: Bool { undecodableItemCount > 0 }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decoded one at a time rather than as `[Element]`, so a single bad item
        // costs that item and not the page around it.
        var decoded: [Element] = []
        var undecodable = 0
        if container.contains(.items), try !container.decodeNil(forKey: .items) {
            var items = try container.nestedUnkeyedContainer(forKey: .items)
            if let count = items.count { decoded.reserveCapacity(count) }
            while !items.isAtEnd {
                do {
                    decoded.append(try items.decode(Element.self))
                } catch {
                    // The element container has to be advanced past the item that
                    // failed, or the loop never terminates.
                    _ = try? items.decode(SkippedItem.self)
                    undecodable += 1
                }
            }
        }
        self.undecodableItemCount = undecodable
        // The server states the item type once, on the list, and omits it from the
        // items themselves. Hand it down so every item knows what it is.
        if let itemType = Self.itemType(
            listAPIVersion: try container.decodeIfPresent(String.self, forKey: .apiVersion),
            listKind: try container.decodeIfPresent(String.self, forKey: .kind)
        ) {
            items = decoded.map { $0.resolvingType(itemType) }
        } else {
            items = decoded
        }
        let metadata = try container.decodeIfPresent(ListMeta.self, forKey: .metadata)
        resourceVersion = metadata?.resourceVersion
        continueToken = metadata?.continueToken
        remainingItemCount = metadata?.remainingItemCount
    }

    /// `PodList` in `v1` holds `Pod`s. A bare `List`, which the API uses for mixed
    /// collections, names no item type, so there is nothing to hand down.
    private static func itemType(listAPIVersion: String?, listKind: String?) -> GroupVersionKind? {
        guard
            let listAPIVersion, !listAPIVersion.isEmpty,
            let listKind, listKind.hasSuffix("List")
        else { return nil }
        let kind = String(listKind.dropLast("List".count))
        guard !kind.isEmpty else { return nil }
        return GroupVersionKind(apiVersion: listAPIVersion, kind: kind)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encode(
            ListMeta(
                resourceVersion: resourceVersion,
                continueToken: continueToken,
                remainingItemCount: remainingItemCount
            ),
            forKey: .metadata
        )
    }

    private enum CodingKeys: String, CodingKey {
        case items, metadata, apiVersion, kind
    }

    /// Consumes one element of any shape, to step over an item that failed to
    /// decode without abandoning the rest of the page.
    private struct SkippedItem: Decodable {
        init(from decoder: any Decoder) throws {
            _ = try? decoder.singleValueContainer()
        }
    }

    private struct ListMeta: Codable {
        let resourceVersion: String?
        let continueToken: String?
        let remainingItemCount: Int?

        init(resourceVersion: String?, continueToken: String?, remainingItemCount: Int?) {
            self.resourceVersion = resourceVersion
            self.continueToken = continueToken
            self.remainingItemCount = remainingItemCount
        }

        enum CodingKeys: String, CodingKey {
            case resourceVersion
            case continueToken = "continue"
            case remainingItemCount
        }
    }
}

/// One event from a watch stream.
public enum WatchEvent<Element: ResourceObject>: Sendable {
    case added(Element)
    case modified(Element)
    case deleted(Element)
    /// The server reported the requested `resourceVersion` is no longer usable.
    /// The caller must discard its cache and relist.
    case resourceVersionExpired
    /// A periodic marker carrying a newer `resourceVersion` with no object change.
    case bookmark(resourceVersion: String)

    public var object: Element? {
        switch self {
        case .added(let object), .modified(let object), .deleted(let object): return object
        case .resourceVersionExpired, .bookmark: return nil
        }
    }
}

extension WatchEvent: Equatable where Element: Equatable {}
extension WatchEvent: Hashable where Element: Hashable {}
