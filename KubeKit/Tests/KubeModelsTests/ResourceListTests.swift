import Foundation
import Testing
@testable import KubeModels

@Suite("ResourceList")
struct ResourceListTests {
    private let decoder = JSONDecoder()

    @Test("Items that omit their type take it from the list")
    func itemsInheritTheListType() throws {
        // This is the shape a real API server sends: apiVersion and kind appear
        // once, on the list, and never on an item.
        let json = """
        {"apiVersion":"v1","kind":"PodList","metadata":{"resourceVersion":"120"},
         "items":[{"metadata":{"name":"api-0","namespace":"prod","uid":"u-1"}}]}
        """

        let list = try decoder.decode(ResourceList<GenericResource>.self, from: Data(json.utf8))

        let pod = try #require(list.items.first)
        #expect(pod.groupVersionKind == GroupVersionKind(apiVersion: "v1", kind: "Pod"))
        #expect(pod.name == "api-0")
        #expect(pod.namespace == "prod")
        #expect(list.resourceVersion == "120")
    }

    @Test("A grouped list hands down its group and version")
    func groupedListHandsDownItsGroup() throws {
        let json = """
        {"apiVersion":"apps/v1","kind":"DeploymentList","metadata":{},
         "items":[{"metadata":{"name":"api","namespace":"prod"}}]}
        """

        let list = try decoder.decode(ResourceList<GenericResource>.self, from: Data(json.utf8))

        let deployment = try #require(list.items.first)
        #expect(deployment.groupVersionKind.groupVersion == GroupVersion(group: "apps", version: "v1"))
        #expect(deployment.groupVersionKind.kind == "Deployment")
    }

    @Test("The inherited type is written into the raw representation too")
    func rawCarriesTheInheritedType() throws {
        let json = """
        {"apiVersion":"v1","kind":"PodList","metadata":{},
         "items":[{"metadata":{"name":"api-0"},"spec":{"nodeName":"node-1"}}]}
        """

        let list = try decoder.decode(ResourceList<GenericResource>.self, from: Data(json.utf8))

        let pod = try #require(list.items.first)
        #expect(pod.raw["apiVersion"]?.stringValue == "v1")
        #expect(pod.raw["kind"]?.stringValue == "Pod")
        // Nothing else about the payload changed.
        #expect(pod.raw["spec", "nodeName"]?.stringValue == "node-1")

        // A YAML view re-encodes `raw`, so the type survives the round trip.
        let reencoded = try JSONEncoder().encode(pod)
        let roundTripped = try decoder.decode(GenericResource.self, from: reencoded)
        #expect(roundTripped.groupVersionKind == pod.groupVersionKind)
    }

    @Test("An item that states its own type keeps it")
    func anItemKeepsItsOwnType() throws {
        let json = """
        {"apiVersion":"v1","kind":"List","metadata":{},
         "items":[{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"api"}}]}
        """

        let list = try decoder.decode(ResourceList<GenericResource>.self, from: Data(json.utf8))

        let item = try #require(list.items.first)
        #expect(item.groupVersionKind == GroupVersionKind(apiVersion: "apps/v1", kind: "Deployment"))
    }

    @Test("A mixed List names no item type, so its items are left untyped")
    func mixedListLeavesItemsUntyped() throws {
        let json = """
        {"apiVersion":"v1","kind":"List","metadata":{},"items":[{"metadata":{"name":"mystery"}}]}
        """

        let list = try decoder.decode(ResourceList<GenericResource>.self, from: Data(json.utf8))

        let item = try #require(list.items.first)
        #expect(item.groupVersionKind.kind.isEmpty)
        #expect(item.name == "mystery")
    }

    @Test("An object decoded on its own keeps the type the server sent with it")
    func standaloneObjectKeepsItsType() throws {
        let json = #"{"apiVersion":"v1","kind":"Pod","metadata":{"name":"api-0","uid":"u-1"}}"#

        let pod = try decoder.decode(GenericResource.self, from: Data(json.utf8))

        #expect(pod.groupVersionKind == GroupVersionKind(apiVersion: "v1", kind: "Pod"))
        #expect(pod.id == "u-1")
    }
}
