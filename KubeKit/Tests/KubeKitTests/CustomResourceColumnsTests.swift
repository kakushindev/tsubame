import Foundation
import Testing
import KubeModels
@testable import KubeKit

@Suite("Custom resource columns")
struct CustomResourceColumnsTests {
    /// The project's own coder, so timestamps decode the way they do in the app.
    private func object(_ json: String) throws -> GenericResource {
        try KubernetesCoder().decoder.decode(GenericResource.self, from: Data(json.utf8))
    }

    private let columns = [
        PrinterColumn(name: "Ready", jsonPath: ".status.conditions[0].status"),
        PrinterColumn(name: "Secret", jsonPath: ".spec.secretName"),
        PrinterColumn(name: "Issuer", jsonPath: ".spec.issuerRef.name"),
    ]

    @Test("A Ready column becomes the row's state, the rest become fields")
    func readyDrivesTheHeadline() throws {
        // CRD authors already use Ready/Status/Phase for the row's state, so the
        // table follows that rather than inventing its own idea of health.
        let certificate = try object("""
        {"apiVersion":"cert-manager.io/v1","kind":"Certificate",
         "metadata":{"name":"tls"},
         "spec":{"secretName":"tls-cert","issuerRef":{"name":"letsencrypt"}},
         "status":{"conditions":[{"status":"True"}]}}
        """)
        let summary = ResourceKindRegistry.summary(of: certificate, columns: columns)

        #expect(summary.headline == "True")
        #expect(summary.tone == .normal)
        #expect(summary.fields.map(\.label) == ["Secret", "Issuer"])
        #expect(summary.fields.map(\.value) == ["tls-cert", "letsencrypt"])
    }

    @Test("A not-ready custom resource reads as a failure")
    func notReadyIsAFailure() throws {
        let certificate = try object("""
        {"apiVersion":"cert-manager.io/v1","kind":"Certificate","metadata":{"name":"tls"},
         "status":{"conditions":[{"status":"False"}]}}
        """)
        #expect(ResourceKindRegistry.summary(of: certificate, columns: columns).tone == .failure)
    }

    @Test("A column whose path does not resolve is left out, not shown blank")
    func unresolvedColumnsAreOmitted() throws {
        let sparse = try object("""
        {"apiVersion":"cert-manager.io/v1","kind":"Certificate","metadata":{"name":"tls"},
         "spec":{"secretName":"tls-cert"}}
        """)
        let summary = ResourceKindRegistry.summary(of: sparse, columns: columns)
        // No status and no issuer: a blank cell would be something to interpret.
        #expect(summary.fields.map(\.label) == ["Secret"])
        #expect(summary.headline == "—")
    }

    @Test("Deletion outranks whatever the columns say")
    func terminatingWins() throws {
        let going = try object("""
        {"apiVersion":"cert-manager.io/v1","kind":"Certificate",
         "metadata":{"name":"tls","deletionTimestamp":"2026-10-20T09:00:00Z"},
         "status":{"conditions":[{"status":"True"}]}}
        """)
        #expect(ResourceKindRegistry.summary(of: going, columns: columns).tone == .terminating)
    }

    @Test("A definition's default columns drive the binding")
    func bindingUsesPrinterColumns() throws {
        let crd = try KubernetesCoder().decoder.decode(CustomResourceDefinition.self, from: Data("""
        {"apiVersion":"apiextensions.k8s.io/v1","kind":"CustomResourceDefinition",
         "metadata":{"name":"certificates.cert-manager.io"},
         "spec":{"group":"cert-manager.io","scope":"Namespaced",
           "names":{"plural":"certificates","singular":"certificate","kind":"Certificate"},
           "versions":[{"name":"v1","served":true,"storage":true,
             "additionalPrinterColumns":[
               {"name":"Ready","type":"string","jsonPath":".status.ready"},
               {"name":"Issuer","type":"string","jsonPath":".spec.issuer","priority":1}]}]}}
        """.utf8))

        let binding = ResourceKindRegistry.mvp.binding(for: crd, version: "v1")
        // Priority above zero is for a wide listing, so it is not a default column.
        #expect(binding.columns == ["Ready"])
        #expect(binding.defaultResourceName == "certificates")
        #expect(binding.groupVersionKind.kind == "Certificate")
    }

    @Test("A definition with no columns still browses, generically")
    func fallsBackWithoutColumns() throws {
        let crd = try KubernetesCoder().decoder.decode(CustomResourceDefinition.self, from: Data("""
        {"apiVersion":"apiextensions.k8s.io/v1","kind":"CustomResourceDefinition",
         "metadata":{"name":"widgets.example.com"},
         "spec":{"group":"example.com","scope":"Cluster",
           "names":{"plural":"widgets","singular":"widget","kind":"Widget"},
           "versions":[{"name":"v1","served":true,"storage":true}]}}
        """.utf8))

        // No schema and no columns is common, and means the generic view rather
        // than a kind the app refuses to show (PRD §9.2).
        let binding = ResourceKindRegistry.mvp.binding(for: crd, version: "v1")
        #expect(binding.columns == ["Status"])
    }
}
