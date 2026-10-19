import Foundation
import Testing
import KubeModels
@testable import KubeKit

@Suite("KubernetesCoder")
struct KubernetesCoderTests {
    private struct Stamped: Codable { let t: Date }

    private func decode(_ timestamp: String) throws -> Date {
        try KubernetesCoder().decoder
            .decode(Stamped.self, from: Data("{\"t\":\"\(timestamp)\"}".utf8))
            .t
    }

    @Test("Decodes metav1.Time, whole seconds")
    func decodesWholeSeconds() throws {
        let date = try decode("2026-10-19T09:00:00Z")
        #expect(date.timeIntervalSince1970 == 1792400400)
    }

    @Test("Decodes metav1.MicroTime, which carries fractional seconds")
    func decodesFractionalSeconds() throws {
        // Event.eventTime and several lastTransitionTime fields use this shape.
        // `.iso8601` rejects it on older Foundation versions, which would have
        // failed the whole page it appeared on.
        let date = try decode("2026-10-19T09:00:00.123456Z")
        #expect(abs(date.timeIntervalSince1970 - 1792400400.123456) < 0.001)
    }

    @Test("Decodes milliseconds as well as microseconds")
    func decodesMilliseconds() throws {
        let date = try decode("2026-10-19T09:00:00.123Z")
        #expect(abs(date.timeIntervalSince1970 - 1792400400.123) < 0.001)
    }

    @Test("Decodes a non-UTC offset")
    func decodesOffset() throws {
        let date = try decode("2026-10-19T16:00:00+07:00")
        #expect(date.timeIntervalSince1970 == 1792400400)
    }

    @Test("Refuses a timestamp it cannot parse rather than inventing one")
    func refusesGarbage() {
        #expect(throws: (any Error).self) { _ = try decode("yesterday") }
        #expect(throws: (any Error).self) { _ = try decode("") }
    }

    @Test("A real Event list decodes, fractional eventTime and all")
    func decodesRealEventList() throws {
        // The shape the API server actually returns, abbreviated.
        let json = """
        {"kind":"EventList","apiVersion":"v1","metadata":{"resourceVersion":"8821"},
         "items":[
           {"metadata":{"name":"nginx.17f","namespace":"default",
                        "creationTimestamp":"2026-10-19T09:00:00Z"},
            "eventTime":"2026-10-19T09:00:00.123456Z",
            "type":"Normal","reason":"Scheduled","message":"Assigned to node-1"},
           {"metadata":{"name":"nginx.180","namespace":"default",
                        "creationTimestamp":"2026-10-19T09:00:01Z"},
            "eventTime":null,
            "type":"Warning","reason":"BackOff","message":"Back-off restarting"}
         ]}
        """
        let list = try KubernetesCoder().decoder
            .decode(ResourceList<GenericResource>.self, from: Data(json.utf8))
        #expect(list.items.count == 2)
        #expect(list.resourceVersion == "8821")
        #expect(list.items[0].metadata.creationTimestamp != nil)
    }
}
