import Foundation
import Testing
@testable import KubeModels

@Suite("Custom resource definitions")
struct CustomResourceDefinitionTests {
    /// A definition in the shape cert-manager and friends actually publish.
    private let json = """
    {"apiVersion":"apiextensions.k8s.io/v1","kind":"CustomResourceDefinition",
     "metadata":{"name":"certificates.cert-manager.io"},
     "spec":{"group":"cert-manager.io","scope":"Namespaced",
       "names":{"plural":"certificates","singular":"certificate","kind":"Certificate",
                "shortNames":["cert","certs"],"categories":["cert-manager"]},
       "versions":[
         {"name":"v1alpha2","served":true,"storage":false,"deprecated":true,
          "deprecationWarning":"use v1"},
         {"name":"v1","served":true,"storage":true,
          "subresources":{"status":{}},
          "additionalPrinterColumns":[
            {"name":"Ready","type":"string","jsonPath":".status.conditions[0].status"},
            {"name":"Secret","type":"string","jsonPath":".spec.secretName"},
            {"name":"Age","type":"date","jsonPath":".metadata.creationTimestamp","priority":0},
            {"name":"Issuer","type":"string","jsonPath":".spec.issuerRef.name","priority":1}],
          "schema":{"openAPIV3Schema":{"type":"object","properties":{
            "spec":{"type":"object","required":["secretName"],"properties":{
              "secretName":{"type":"string","description":"Where to store it"},
              "duration":{"type":"string","pattern":"^[0-9]+h$"},
              "usages":{"type":"array","items":{"type":"string","enum":["signing","key encipherment"]}},
              "extra":{"x-kubernetes-preserve-unknown-fields":true}}}}}}}]}}
    """

    private func decoded() throws -> CustomResourceDefinition {
        try JSONDecoder().decode(CustomResourceDefinition.self, from: Data(json.utf8))
    }

    @Test("Reads the names, scope and group a listing needs")
    func readsIdentity() throws {
        let crd = try decoded()
        #expect(crd.group == "cert-manager.io")
        #expect(crd.names.kind == "Certificate")
        #expect(crd.names.shortNames == ["cert", "certs"])
        #expect(crd.scope == .namespaced)
        #expect(crd.groupVersionResource(version: "v1").collectionPath(namespace: "prod")
            == "/apis/cert-manager.io/v1/namespaces/prod/certificates")
    }

    @Test("Prefers the stored version over a served but deprecated one")
    func prefersStorageVersion() throws {
        let crd = try decoded()
        #expect(crd.servedVersions.count == 2)
        #expect(crd.preferredVersion?.name == "v1")
        #expect(crd.versions.first?.deprecated == true)
        #expect(crd.versions.first?.deprecationWarning == "use v1")
    }

    @Test("Printer columns become the table's columns")
    func readsPrinterColumns() throws {
        let crd = try decoded()
        let version = try #require(crd.preferredVersion)
        #expect(version.additionalPrinterColumns.map(\.name) == ["Ready", "Secret", "Age", "Issuer"])
        // Priority above zero is detail a wide listing adds, not a default column.
        #expect(version.additionalPrinterColumns.filter { $0.priority == 0 }.count == 3)
        #expect(version.subresources == ["status"])
    }

    @Test("A column reads its value out of an object")
    func evaluatesColumns() throws {
        let object: JSONValue = .object([
            "spec": .object([
                "secretName": .string("tls-cert"),
                "issuerRef": .object(["name": .string("letsencrypt")]),
            ]),
            "status": .object(["conditions": .array([.object(["status": .string("True")])])]),
        ])
        let crd = try decoded()
        let version = try #require(crd.preferredVersion)
        let columns = version.additionalPrinterColumns
        #expect(columns[0].value(in: object) == "True")   // indexed into an array
        #expect(columns[1].value(in: object) == "tls-cert")
        #expect(columns[3].value(in: object) == "letsencrypt")
    }

    @Test("A path the subset cannot evaluate renders empty rather than wrong")
    func refusesUnsupportedPaths() {
        let object: JSONValue = .object(["spec": .object(["items": .array([.string("a")])])])
        // Filters, wildcards and recursive descent are not supported; guessing at
        // them would show a confidently wrong value.
        #expect(PrinterColumn(name: "x", jsonPath: ".spec.items[*]").value(in: object) == nil)
        #expect(PrinterColumn(name: "x", jsonPath: "..name").value(in: object) == nil)
        #expect(PrinterColumn(name: "x", jsonPath: ".spec.items[?(@.a)]").value(in: object) == nil)
        // A path that simply is not there is also empty, not an error.
        #expect(PrinterColumn(name: "x", jsonPath: ".spec.missing").value(in: object) == nil)
        #expect(PrinterColumn(name: "x", jsonPath: ".spec.items[9]").value(in: object) == nil)
    }

    @Test("The schema subset keeps what it understands and marks the rest opaque")
    func readsSchema() throws {
        let crd = try decoded()
        let version = try #require(crd.preferredVersion)
        let schema = try #require(version.schema)

        let secretName = try #require(schema.schema(at: ["spec", "secretName"]))
        guard case .scalar(let secret) = secretName else {
            Issue.record("expected a scalar"); return
        }
        #expect(secret.type == "string")
        #expect(secret.description == "Where to store it")

        let specSchema = try #require(schema.schema(at: ["spec"]))
        guard case .object(let spec) = specSchema else {
            Issue.record("expected an object"); return
        }
        #expect(spec.required == ["secretName"])

        // An enum is what lets an editor offer a picker instead of a text field.
        let usages = try #require(schema.schema(at: ["spec", "usages"]))
        guard case .array(let items, _) = usages else {
            Issue.record("expected an array"); return
        }
        let element = try #require(items)
        guard case .scalar(let usage) = element else {
            Issue.record("expected scalar elements"); return
        }
        #expect(usage.allowedValues.count == 2)

        // "Anything may be here" stops interpretation rather than guessing.
        let extra = try #require(schema.schema(at: ["spec", "extra"]))
        guard case .opaque = extra else {
            Issue.record("preserve-unknown-fields must be opaque"); return
        }
        #expect(schema.schema(at: ["spec", "secretName", "deeper"]) == nil)
    }

    @Test("A definition that publishes no schema is usable anyway")
    func toleratesNoSchema() throws {
        let bare = """
        {"apiVersion":"apiextensions.k8s.io/v1","kind":"CustomResourceDefinition",
         "metadata":{"name":"widgets.example.com"},
         "spec":{"group":"example.com","scope":"Cluster",
           "names":{"plural":"widgets","singular":"widget","kind":"Widget"},
           "versions":[{"name":"v1","served":true,"storage":true}]}}
        """
        let crd = try JSONDecoder().decode(CustomResourceDefinition.self, from: Data(bare.utf8))
        #expect(crd.scope == .cluster)
        #expect(crd.preferredVersion?.schema == nil)
        #expect(crd.preferredVersion?.additionalPrinterColumns.isEmpty == true)
        #expect(!crd.groupVersionResource(version: "v1").isNamespaced)
    }
}
