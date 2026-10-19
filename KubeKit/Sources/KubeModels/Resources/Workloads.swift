import Foundation

/// A workload whose rollout is described by replica counts.
///
/// Deployment and StatefulSet share this shape exactly; DaemonSet reports the same
/// idea under different field names and so projects into it rather than conforming
/// to a shape it does not have.
public protocol ReplicatedWorkload: TypedResource {
    var desiredReplicas: Int { get }
    var readyReplicas: Int { get }
    var updatedReplicas: Int { get }
    /// Where a restart's pod-template annotation is written, and what a scale
    /// confirmation needs to show.
    var podTemplateAnnotations: [String: String] { get }
}

extension ReplicatedWorkload {
    public var rowSummary: ResourceRowSummary {
        let fields: [ResourceRowSummary.Field] = [
            .init(label: "Ready", value: "\(readyReplicas)/\(desiredReplicas)"),
            .init(label: "Up-to-date", value: "\(updatedReplicas)"),
        ]
        if metadata.deletionTimestamp != nil {
            return ResourceRowSummary(headline: "Terminating", fields: fields, tone: .terminating)
        }
        if desiredReplicas == 0 {
            // Scaled to zero on purpose is not a failure, but it is worth noticing.
            return ResourceRowSummary(headline: "Scaled to zero", fields: fields, tone: .attention)
        }
        if readyReplicas == desiredReplicas, updatedReplicas == desiredReplicas {
            return ResourceRowSummary(
                headline: "\(readyReplicas)/\(desiredReplicas)", fields: fields, tone: .normal
            )
        }
        return ResourceRowSummary(
            headline: "\(readyReplicas)/\(desiredReplicas)",
            fields: fields,
            tone: readyReplicas == 0 ? .failure : .pending
        )
    }
}

/// Shared decoding for the `apps/v1` controllers that carry `spec.replicas`.
///
/// DaemonSet does not: its desired count is however many nodes match, so it reads
/// its own status fields instead of using this.
struct WorkloadBody: Sendable {
    var desiredReplicas: Int
    var readyReplicas: Int
    var updatedReplicas: Int
    var availableReplicas: Int
    var podTemplateAnnotations: [String: String]

    init(raw: JSONValue) {
        // An unset `spec.replicas` means one replica, per the API's own default.
        // `status.replicas` is the count of non-terminated pods, which is a
        // different number and would misreport a rollout.
        desiredReplicas = raw["spec", "replicas"]?.integerValue ?? 1
        readyReplicas = raw["status", "readyReplicas"]?.integerValue ?? 0
        updatedReplicas = raw["status", "updatedReplicas"]?.integerValue ?? 0
        availableReplicas = raw["status", "availableReplicas"]?.integerValue ?? 0
        podTemplateAnnotations = raw["spec", "template", "metadata", "annotations"]?
            .objectValue?
            .compactMapValues(\.stringValue) ?? [:]
    }
}

// MARK: - Deployment

public struct Deployment: ReplicatedWorkload {
    public static let typeIdentity = GroupVersionKind(apiVersion: "apps/v1", kind: "Deployment")
    public static let resourceName = "deployments"
    public static let isNamespaced = true

    public let metadata: ObjectMeta
    public let raw: JSONValue
    public let desiredReplicas: Int
    public let readyReplicas: Int
    public let updatedReplicas: Int
    public let availableReplicas: Int
    public let podTemplateAnnotations: [String: String]

    public init(from decoder: any Decoder) throws {
        self.raw = try JSONValue(from: decoder).addingTypeFields(Self.typeIdentity)
        let c = try decoder.container(keyedBy: Key.self)
        self.metadata = try c.decode(ObjectMeta.self, forKey: .metadata)
        let body = WorkloadBody(raw: raw)
        self.desiredReplicas = body.desiredReplicas
        self.readyReplicas = body.readyReplicas
        self.updatedReplicas = body.updatedReplicas
        self.availableReplicas = body.availableReplicas
        self.podTemplateAnnotations = body.podTemplateAnnotations
    }

    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
    private enum Key: String, CodingKey { case metadata }
}

// MARK: - StatefulSet

public struct StatefulSet: ReplicatedWorkload {
    public static let typeIdentity = GroupVersionKind(apiVersion: "apps/v1", kind: "StatefulSet")
    public static let resourceName = "statefulsets"
    public static let isNamespaced = true

    public let metadata: ObjectMeta
    public let raw: JSONValue
    public let desiredReplicas: Int
    public let readyReplicas: Int
    public let updatedReplicas: Int
    public let serviceName: String?
    public let podTemplateAnnotations: [String: String]

    public init(from decoder: any Decoder) throws {
        self.raw = try JSONValue(from: decoder).addingTypeFields(Self.typeIdentity)
        let c = try decoder.container(keyedBy: Key.self)
        self.metadata = try c.decode(ObjectMeta.self, forKey: .metadata)
        let body = WorkloadBody(raw: raw)
        self.desiredReplicas = body.desiredReplicas
        self.readyReplicas = body.readyReplicas
        self.updatedReplicas = body.updatedReplicas
        self.podTemplateAnnotations = body.podTemplateAnnotations
        self.serviceName = raw["spec", "serviceName"]?.stringValue
    }

    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
    private enum Key: String, CodingKey { case metadata }
}

// MARK: - DaemonSet

/// A DaemonSet has no `spec.replicas`: its desired count is however many nodes
/// match, which only the status reports.
public struct DaemonSet: ReplicatedWorkload {
    public static let typeIdentity = GroupVersionKind(apiVersion: "apps/v1", kind: "DaemonSet")
    public static let resourceName = "daemonsets"
    public static let isNamespaced = true

    public let metadata: ObjectMeta
    public let raw: JSONValue
    public let desiredReplicas: Int
    public let readyReplicas: Int
    public let updatedReplicas: Int
    public let availableReplicas: Int
    public let misscheduledCount: Int
    public let podTemplateAnnotations: [String: String]

    public init(from decoder: any Decoder) throws {
        self.raw = try JSONValue(from: decoder).addingTypeFields(Self.typeIdentity)
        let c = try decoder.container(keyedBy: Key.self)
        self.metadata = try c.decode(ObjectMeta.self, forKey: .metadata)
        self.desiredReplicas = raw["status", "desiredNumberScheduled"]?.integerValue ?? 0
        self.readyReplicas = raw["status", "numberReady"]?.integerValue ?? 0
        self.updatedReplicas = raw["status", "updatedNumberScheduled"]?.integerValue ?? 0
        self.availableReplicas = raw["status", "numberAvailable"]?.integerValue ?? 0
        self.misscheduledCount = raw["status", "numberMisscheduled"]?.integerValue ?? 0
        self.podTemplateAnnotations = raw["spec", "template", "metadata", "annotations"]?
            .objectValue?.compactMapValues(\.stringValue) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
    private enum Key: String, CodingKey { case metadata }
}
