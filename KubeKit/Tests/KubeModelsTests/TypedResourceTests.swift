import Foundation
import Testing
@testable import KubeModels

@Suite("Typed resources")
struct TypedResourceTests {
    private func decode<T: TypedResource>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom {
            let text = try $0.singleValueContainer().decode(String.self)
            guard let date = RFC3339.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: try $0.singleValueContainer(), debugDescription: "bad date")
            }
            return date
        }
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - The two structural guarantees

    @Test("A listed item gets apiVersion and kind written into its raw representation")
    func fillsTypeFieldsFromTheModel() throws {
        // Items inside a List carry neither field. Without this, the YAML view of a
        // pod opened from a list would differ from the same pod fetched on its own,
        // and a manifest built from it would be rejected by the server.
        let pod = try decode(Pod.self, """
        {"metadata":{"name":"nginx","namespace":"default"},"spec":{"containers":[]}}
        """)
        #expect(pod.raw["apiVersion"]?.stringValue == "v1")
        #expect(pod.raw["kind"]?.stringValue == "Pod")
        #expect(pod.groupVersionKind == Pod.typeIdentity)
    }

    @Test("Encoding writes the API's own bytes, not the projection")
    func encodesRawNotProjection() throws {
        let json = """
        {"apiVersion":"v1","kind":"Pod",
         "metadata":{"name":"nginx","namespace":"default"},
         "spec":{"containers":[{"name":"app","image":"nginx:1.25"}],
                 "unknownFutureField":{"nested":true}},
         "status":{"phase":"Running"}}
        """
        let pod = try decode(Pod.self, json)
        let reencoded = try JSONEncoder().encode(pod)
        let round = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        let spec = round?["spec"] as? [String: Any]
        // A field the model does not know about must survive a round trip, or an
        // apply built from a browsed object would silently drop it.
        #expect(spec?["unknownFutureField"] != nil)
    }

    @Test("An unexpected or missing field never fails the object")
    func toleratesUnexpectedPayloads() throws {
        let sparse = try decode(Pod.self, #"{"metadata":{"name":"x"}}"#)
        #expect(sparse.spec.containers.isEmpty)
        #expect(sparse.status.phase == nil)
        #expect(sparse.rowSummary.headline == "Unknown")
    }

    // MARK: - Pod

    @Test("A crash-looping pod reports the container reason, not the phase")
    func podReportsCrashLoop() throws {
        // status.phase is "Running" here, which would be a misleading headline.
        let pod = try decode(Pod.self, """
        {"metadata":{"name":"api"},
         "spec":{"containers":[{"name":"app"},{"name":"sidecar"}],"nodeName":"node-1"},
         "status":{"phase":"Running","containerStatuses":[
            {"name":"app","ready":false,"restartCount":7,
             "state":{"waiting":{"reason":"CrashLoopBackOff"}},
             "lastState":{"terminated":{"reason":"Error"}}},
            {"name":"sidecar","ready":true,"restartCount":0,"state":{"running":{}}}]}}
        """)
        #expect(pod.rowSummary.headline == "CrashLoopBackOff")
        #expect(pod.rowSummary.tone == .failure)
        #expect(pod.readyContainerCount == 1)
        #expect(pod.totalContainerCount == 2)
        #expect(pod.restartCount == 7)
        // Previous-container logs are only valid where a previous instance exists.
        #expect(pod.status.containerStatuses[0].hasPreviousInstance)
        #expect(!pod.status.containerStatuses[1].hasPreviousInstance)
    }

    @Test("A healthy pod reads as Running, and a partially ready one as pending")
    func podReportsReadiness() throws {
        func pod(ready: Bool) throws -> Pod {
            try decode(Pod.self, """
            {"metadata":{"name":"api"},"spec":{"containers":[{"name":"a"},{"name":"b"}]},
             "status":{"phase":"Running","containerStatuses":[
               {"name":"a","ready":true,"state":{"running":{}}},
               {"name":"b","ready":\(ready),"state":{"running":{}}}]}}
            """)
        }
        #expect(try pod(ready: true).rowSummary.tone == .normal)
        #expect(try pod(ready: false).rowSummary.tone == .pending)
    }

    @Test("A deleted pod reads as terminating whatever its phase says")
    func podReportsTermination() throws {
        let pod = try decode(Pod.self, """
        {"metadata":{"name":"api","deletionTimestamp":"2026-10-19T09:00:00Z"},
         "status":{"phase":"Running"}}
        """)
        #expect(pod.rowSummary.headline == "Terminating")
        #expect(pod.rowSummary.tone == .terminating)
    }

    @Test("Init containers are offered to the log picker")
    func podListsEveryContainer() throws {
        let pod = try decode(Pod.self, """
        {"metadata":{"name":"api"},
         "spec":{"initContainers":[{"name":"migrate"}],"containers":[{"name":"app"}]}}
        """)
        #expect(pod.allContainers.map(\.name) == ["migrate", "app"])
    }

    // MARK: - Workloads

    @Test("Deployment replica counts drive the rollout summary")
    func deploymentSummarisesRollout() throws {
        let rolling = try decode(Deployment.self, """
        {"metadata":{"name":"api"},"spec":{"replicas":3},
         "status":{"readyReplicas":1,"updatedReplicas":2,"availableReplicas":1}}
        """)
        #expect(rolling.rowSummary.headline == "1/3")
        #expect(rolling.rowSummary.tone == .pending)

        let healthy = try decode(Deployment.self, """
        {"metadata":{"name":"api"},"spec":{"replicas":3},
         "status":{"readyReplicas":3,"updatedReplicas":3,"availableReplicas":3}}
        """)
        #expect(healthy.rowSummary.tone == .normal)
    }

    @Test("An unset spec.replicas means one, not zero")
    func deploymentDefaultsReplicas() throws {
        // status.replicas is the count of non-terminated pods, a different number;
        // using it as the desired count would misreport every rollout.
        let deployment = try decode(Deployment.self, """
        {"metadata":{"name":"api"},"spec":{},"status":{"replicas":5,"readyReplicas":1}}
        """)
        #expect(deployment.desiredReplicas == 1)
    }

    @Test("A workload scaled to zero is called out rather than shown as healthy")
    func deploymentReportsScaledToZero() throws {
        let deployment = try decode(Deployment.self, """
        {"metadata":{"name":"api"},"spec":{"replicas":0},"status":{}}
        """)
        #expect(deployment.rowSummary.headline == "Scaled to zero")
        #expect(deployment.rowSummary.tone == .attention)
    }

    @Test("A DaemonSet takes its desired count from status, having no spec.replicas")
    func daemonSetUsesStatusCounts() throws {
        let daemonSet = try decode(DaemonSet.self, """
        {"metadata":{"name":"fluentd"},"spec":{},
         "status":{"desiredNumberScheduled":4,"numberReady":4,
                   "updatedNumberScheduled":4,"numberAvailable":4}}
        """)
        #expect(daemonSet.desiredReplicas == 4)
        #expect(daemonSet.rowSummary.headline == "4/4")
        #expect(daemonSet.rowSummary.tone == .normal)
    }

    @Test("Restart reads the pod-template annotations it would have to change")
    func workloadExposesTemplateAnnotations() throws {
        let deployment = try decode(Deployment.self, """
        {"metadata":{"name":"api"},"spec":{"replicas":1,"template":{"metadata":{
           "annotations":{"kubectl.kubernetes.io/restartedAt":"2026-10-19T09:00:00Z"}}}}}
        """)
        #expect(deployment.podTemplateAnnotations["kubectl.kubernetes.io/restartedAt"]
            == "2026-10-19T09:00:00Z")
    }

    // MARK: - Batch

    @Test("Job states map to completion, failure and suspension")
    func jobSummarises() throws {
        #expect(try decode(Job.self, """
        {"metadata":{"name":"j"},"spec":{"completions":3},"status":{"succeeded":3}}
        """).rowSummary.headline == "Complete")

        #expect(try decode(Job.self, """
        {"metadata":{"name":"j"},"spec":{"completions":3},"status":{"failed":2}}
        """).rowSummary.tone == .failure)

        #expect(try decode(Job.self, """
        {"metadata":{"name":"j"},"spec":{"suspend":true},"status":{}}
        """).rowSummary.headline == "Suspended")
    }

    @Test("A suspended CronJob says so instead of showing its schedule as active")
    func cronJobReportsSuspension() throws {
        let suspended = try decode(CronJob.self, """
        {"metadata":{"name":"nightly"},"spec":{"schedule":"0 2 * * *","suspend":true}}
        """)
        #expect(suspended.rowSummary.headline == "Suspended")
        #expect(suspended.rowSummary.tone == .attention)

        let active = try decode(CronJob.self, """
        {"metadata":{"name":"nightly"},"spec":{"schedule":"0 2 * * *"}}
        """)
        #expect(active.rowSummary.headline == "0 2 * * *")
    }

    // MARK: - Core

    @Test("A LoadBalancer with no address yet reads as pending")
    func serviceReportsPendingAddress() throws {
        let pending = try decode(Service.self, """
        {"metadata":{"name":"web"},"spec":{"type":"LoadBalancer","ports":[{"port":80}]},
         "status":{"loadBalancer":{}}}
        """)
        #expect(pending.rowSummary.headline == "Pending address")
        #expect(pending.rowSummary.tone == .pending)

        let ready = try decode(Service.self, """
        {"metadata":{"name":"web"},"spec":{"type":"LoadBalancer","ports":[{"port":80}]},
         "status":{"loadBalancer":{"ingress":[{"hostname":"a.elb.example"}]}}}
        """)
        #expect(ready.externalIPs == ["a.elb.example"])
        #expect(ready.rowSummary.tone == .normal)
    }

    @Test("Service ports render with their node port and protocol")
    func serviceFormatsPorts() throws {
        let service = try decode(Service.self, """
        {"metadata":{"name":"web"},"spec":{"type":"NodePort","ports":[
           {"port":80,"nodePort":30080,"protocol":"TCP"},
           {"port":53,"protocol":"UDP"}]}}
        """)
        #expect(service.ports.map(\.displayName) == ["80:30080/TCP", "53/UDP"])
    }

    @Test("Event takes its time from whichever field the cluster populated")
    func eventReadsMicroTime() throws {
        // eventTime is a MicroTime: fractional seconds, which a strict ISO-8601
        // parser rejects.
        let event = try decode(Event.self, """
        {"metadata":{"name":"nginx.17f","namespace":"default"},
         "eventTime":"2026-10-19T09:00:00.123456Z",
         "type":"Warning","reason":"BackOff","message":"Back-off restarting",
         "count":12,"involvedObject":{"kind":"Pod","name":"nginx"}}
        """)
        #expect(event.lastOccurrence != nil)
        #expect(event.rowSummary.headline == "BackOff")
        #expect(event.rowSummary.tone == .attention)
        #expect(event.count == 12)
    }

    @Test("ConfigMap counts text and binary keys together")
    func configMapCountsKeys() throws {
        let configMap = try decode(ConfigMap.self, """
        {"metadata":{"name":"app"},"data":{"a":"1","b":"2"},"binaryData":{"c":"AQID"}}
        """)
        #expect(configMap.data.count == 2)
        #expect(configMap.binaryDataKeys == ["c"])
        #expect(configMap.rowSummary.headline == "3 keys")
    }

    // MARK: - Secret

    @Test("Secret values decode to text, unmasked, per PRD §17")
    func secretDecodesText() throws {
        let secret = try decode(Secret.self, """
        {"metadata":{"name":"db"},"type":"Opaque",
         "data":{"username":"YWRtaW4=","password":"aHVudGVyMg=="}}
        """)
        #expect(secret.values["username"] == .text("admin"))
        #expect(secret.values["password"] == .text("hunter2"))
        #expect(secret.keys == ["password", "username"])
    }

    @Test("A binary Secret value keeps its base64 and reports its size")
    func secretKeepsBinaryAsBase64() throws {
        // 0xFF 0xFE is not valid UTF-8, so there is nothing readable to show.
        let secret = try decode(Secret.self, """
        {"metadata":{"name":"cert"},"data":{"blob":"//4="}}
        """)
        #expect(secret.values["blob"] == .binary(base64: "//4=", byteCount: 2))
    }

    @Test("Raw YAML keeps the API representation even though the detail decodes it")
    func secretRawStaysEncoded() throws {
        let secret = try decode(Secret.self, """
        {"metadata":{"name":"db"},"data":{"username":"YWRtaW4="}}
        """)
        // The detail view decodes; `raw` must not, or the YAML view would show
        // something the cluster never sent.
        #expect(secret.raw["data", "username"]?.stringValue == "YWRtaW4=")
        #expect(secret.values["username"] == .text("admin"))
    }

    @Test("A Secret list row shows a key count, never a value")
    func secretRowHidesValuesByShape() throws {
        let secret = try decode(Secret.self, """
        {"metadata":{"name":"db"},"type":"Opaque","data":{"password":"aHVudGVyMg=="}}
        """)
        // Not masking — there is simply nowhere sensible to put a value in a row,
        // and the detail is one tap away.
        let rendered = secret.rowSummary.headline
            + secret.rowSummary.fields.map(\.value).joined()
        #expect(!rendered.contains("hunter2"))
        #expect(!rendered.contains("aHVudGVyMg=="))
    }
}
