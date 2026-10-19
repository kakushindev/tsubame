import Foundation
import Testing
@testable import KubeKit

@Suite("CredentialRedactor")
struct CredentialRedactorTests {
    private let redactor = CredentialRedactor()

    @Test("Removes an authorization header value")
    func removesAuthorizationHeader() {
        let headers = redactor.redact(headers: [
            "Authorization": "Bearer eyJhbGciOiJSUzI1NiJ9.payload.signature",
            "Content-Type": "application/json",
        ])

        #expect(headers["Authorization"] == CredentialRedactor.placeholder)
        #expect(headers["Content-Type"] == "application/json")
    }

    @Test("Removes inline bearer tokens and kubeconfig credential fields")
    func removesInlineCredentials() {
        let text = """
        request failed: Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.payload.signature
        client-key-data: LS0tLS1CRUdJTiBQUklWQVRF
        """
        let redacted = redactor.redact(text)

        #expect(!redacted.contains("eyJhbGciOiJSUzI1NiJ9"))
        #expect(!redacted.contains("LS0tLS1CRUdJTiBQUklWQVRF"))
        #expect(redacted.contains(CredentialRedactor.placeholder))
    }

    @Test("Removes a PEM private key block")
    func removesPrivateKeyBlock() {
        let text = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAsecretkeymaterial
        -----END RSA PRIVATE KEY-----
        """
        #expect(redactor.redact(text) == CredentialRedactor.placeholder)
    }

    @Test("Leaves ordinary error text alone")
    func leavesOrdinaryTextAlone() {
        let text = #"pods "api-0" is forbidden: User cannot list resource "pods""#
        #expect(redactor.redact(text) == text)
    }
}
