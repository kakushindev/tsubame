import Foundation
import Testing
@testable import KubeModels

/// A typed element strict enough to fail on a bad item, so partial decoding can be
/// observed. `GenericResource` accepts almost anything, which is the point of it.
private struct StrictPod: ResourceObject, Codable, Hashable {
    let groupVersionKind: GroupVersionKind
    let metadata: ObjectMeta
    let raw: JSONValue
    let replicas: Int

    init(from decoder: any Decoder) throws {
        self.raw = try JSONValue(from: decoder)
        let c = try decoder.container(keyedBy: Key.self)
        self.metadata = try c.decode(ObjectMeta.self, forKey: .metadata)
        // Required and strictly typed: a string here fails this item.
        self.replicas = try c.decode(Int.self, forKey: .replicas)
        self.groupVersionKind = GroupVersionKind(apiVersion: "v1", kind: "Pod")
    }

    func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
    private enum Key: String, CodingKey { case metadata, replicas }
}

@Suite("Partial list decoding")
struct PartialListDecodingTests {
    private func list(_ json: String) throws -> ResourceList<StrictPod> {
        try JSONDecoder().decode(ResourceList<StrictPod>.self, from: Data(json.utf8))
    }

    @Test("One bad item costs that item, not the whole page")
    func keepsGoodItemsAroundABadOne() throws {
        let decoded = try list("""
        {"kind":"PodList","apiVersion":"v1","metadata":{"resourceVersion":"42"},
         "items":[
           {"metadata":{"name":"first"},"replicas":1},
           {"metadata":{"name":"broken"},"replicas":"not-a-number"},
           {"metadata":{"name":"third"},"replicas":3}
         ]}
        """)

        // The good items must both survive, and in order: a skip that consumed the
        // wrong element would drop "third" instead.
        #expect(decoded.items.map(\.metadata.name) == ["first", "third"])
        #expect(decoded.items.map(\.replicas) == [1, 3])
        #expect(decoded.undecodableItemCount == 1)
        #expect(decoded.isPartial)
        #expect(decoded.resourceVersion == "42")
    }

    @Test("Several bad items are all counted")
    func countsEveryFailure() throws {
        let decoded = try list("""
        {"kind":"PodList","apiVersion":"v1","items":[
           {"metadata":{"name":"a"},"replicas":"x"},
           {"metadata":{"name":"b"},"replicas":2},
           {"metadata":{"name":"c"},"replicas":"y"},
           {"metadata":{"name":"d"},"replicas":4}
         ]}
        """)
        #expect(decoded.items.map(\.metadata.name) == ["b", "d"])
        #expect(decoded.undecodableItemCount == 2)
    }

    @Test("A page where everything fails is partial, not silently empty")
    func allItemsBad() throws {
        let decoded = try list("""
        {"kind":"PodList","apiVersion":"v1","items":[
           {"metadata":{"name":"a"},"replicas":"x"}
         ]}
        """)
        #expect(decoded.items.isEmpty)
        // An empty list and a list that failed to decode must be distinguishable.
        #expect(decoded.undecodableItemCount == 1)
        #expect(decoded.isPartial)
    }

    @Test("A genuinely empty page is not partial")
    func emptyIsNotPartial() throws {
        let decoded = try list("""
        {"kind":"PodList","apiVersion":"v1","items":[]}
        """)
        #expect(decoded.items.isEmpty)
        #expect(!decoded.isPartial)
    }

    @Test("A null or absent items field decodes as empty")
    func toleratesMissingItems() throws {
        #expect(try list(#"{"kind":"PodList","apiVersion":"v1"}"#).items.isEmpty)
        #expect(try list(#"{"kind":"PodList","apiVersion":"v1","items":null}"#).items.isEmpty)
    }
}
