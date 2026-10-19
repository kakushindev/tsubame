import Foundation
import Testing
import KubeModels
@testable import KubeKit

@Suite("KubernetesErrorMapper")
struct KubernetesErrorMapperTests {
    private let mapper = KubernetesErrorMapper()

    private func status(code: Int, reason: String, message: String) -> Data {
        Data("""
        {"kind":"Status","status":"Failure","message":"\(message)","reason":"\(reason)","code":\(code)}
        """.utf8)
    }

    @Test("Maps a 403 to a permission denial carrying the server message")
    func mapsForbidden() {
        let error = mapper.error(
            statusCode: 403,
            headers: [:],
            body: status(code: 403, reason: "Forbidden", message: "pods is forbidden")
        )

        guard case .permissionDenied(let status) = error else {
            Issue.record("Expected permissionDenied, got \(error)")
            return
        }
        #expect(status?.message == "pods is forbidden")
        #expect(error.isTransient == false)
    }

    @Test("Maps a 410 to an expired resource version so the caller relists")
    func mapsGone() {
        let error = mapper.error(
            statusCode: 410,
            headers: [:],
            body: status(code: 410, reason: "Expired", message: "too old resource version")
        )
        guard case .resourceVersionExpired = error else {
            Issue.record("Expected resourceVersionExpired, got \(error)")
            return
        }
    }

    @Test("Honors Retry-After on a 429, case-insensitively")
    func honorsRetryAfter() {
        let error = mapper.error(
            statusCode: 429,
            headers: ["retry-after": "7"],
            body: Data()
        )
        guard case .throttled(let retryAfter, _) = error else {
            Issue.record("Expected throttled, got \(error)")
            return
        }
        #expect(retryAfter == 7)
        #expect(error.isTransient)
    }

    @Test("Falls back to a bounded delay when Retry-After is missing")
    func fallsBackWhenRetryAfterMissing() {
        let error = mapper.error(statusCode: 503, headers: [:], body: Data())
        guard case .throttled(let retryAfter, _) = error else {
            Issue.record("Expected throttled, got \(error)")
            return
        }
        #expect(retryAfter == 1)
    }

    @Test("Maps an unrecognized code to a server error")
    func mapsUnknownCode() {
        let error = mapper.error(statusCode: 500, headers: [:], body: Data())
        guard case .serverError(let code, _) = error else {
            Issue.record("Expected serverError, got \(error)")
            return
        }
        #expect(code == 500)
        #expect(error.isTransient)
    }
}
