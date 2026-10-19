import Foundation
import Testing
@testable import KubeModels

@Suite("JSONValue")
struct JSONValueTests {
    @Test("Round-trips an object without losing unknown fields")
    func roundTripsUnknownFields() throws {
        let source = """
        {"apiVersion":"example.com/v1","kind":"Widget","spec":{"replicas":3,"flags":["a","b"],"nested":{"on":true}}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        let encoded = try JSONEncoder().encode(value)
        let reDecoded = try JSONDecoder().decode(JSONValue.self, from: encoded)

        #expect(value == reDecoded)
        #expect(value["spec", "replicas"]?.integerValue == 3)
        #expect(value["spec", "nested", "on"] == .bool(true))
        #expect(value["spec", "flags"]?.arrayValue?.count == 2)
    }

    @Test("Reports a missing key path as nil rather than failing")
    func missingKeyPathIsNil() throws {
        let value = JSONValue.object(["spec": .object([:])])
        #expect(value["spec", "replicas"] == nil)
        #expect(value["status"] == nil)
    }

    @Test("Decodes a generic resource and keeps its raw payload")
    func decodesGenericResource() throws {
        let source = """
        {"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"api","namespace":"prod","resourceVersion":"42"},"spec":{"replicas":2}}
        """
        let resource = try JSONDecoder().decode(GenericResource.self, from: Data(source.utf8))

        #expect(resource.groupVersionKind.kind == "Deployment")
        #expect(resource.groupVersionKind.groupVersion == GroupVersion(group: "apps", version: "v1"))
        #expect(resource.metadata.name == "api")
        #expect(resource.metadata.namespace == "prod")
        #expect(resource.resourceVersion == "42")
        #expect(resource.raw["spec", "replicas"]?.integerValue == 2)
    }
}

@Suite("GroupVersionResource")
struct GroupVersionResourceTests {
    @Test("Builds core and grouped paths")
    func buildsPaths() {
        let pods = GroupVersionResource(groupVersion: .core, resource: "pods", isNamespaced: true)
        #expect(pods.collectionPath(namespace: "prod") == "/api/v1/namespaces/prod/pods")
        #expect(pods.collectionPath(namespace: nil) == "/api/v1/pods")
        #expect(pods.objectPath(namespace: "prod", name: "api-0") == "/api/v1/namespaces/prod/pods/api-0")

        let deployments = GroupVersionResource(
            groupVersion: GroupVersion(group: "apps", version: "v1"),
            resource: "deployments",
            isNamespaced: true
        )
        #expect(
            deployments.subresourcePath(namespace: "prod", name: "api", subresource: "scale")
                == "/apis/apps/v1/namespaces/prod/deployments/api/scale"
        )
    }

    @Test("Ignores a namespace on a cluster-scoped resource")
    func ignoresNamespaceWhenClusterScoped() {
        let nodes = GroupVersionResource(groupVersion: .core, resource: "nodes", isNamespaced: false)
        #expect(nodes.collectionPath(namespace: "prod") == "/api/v1/nodes")
    }
}
