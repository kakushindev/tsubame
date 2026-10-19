import Foundation

public struct Job: TypedResource {
    public static let typeIdentity = GroupVersionKind(apiVersion: "batch/v1", kind: "Job")
    public static let resourceName = "jobs"
    public static let isNamespaced = true

    public let metadata: ObjectMeta
    public let raw: JSONValue
    public let completions: Int?
    public let parallelism: Int?
    public let succeeded: Int
    public let failed: Int
    public let active: Int
    public let startTime: Date?
    public let completionTime: Date?
    public let isSuspended: Bool

    public init(from decoder: any Decoder) throws {
        self.raw = try JSONValue(from: decoder).addingTypeFields(Self.typeIdentity)
        let c = try decoder.container(keyedBy: Key.self)
        self.metadata = try c.decode(ObjectMeta.self, forKey: .metadata)
        self.completions = raw["spec", "completions"]?.integerValue
        self.parallelism = raw["spec", "parallelism"]?.integerValue
        self.succeeded = raw["status", "succeeded"]?.integerValue ?? 0
        self.failed = raw["status", "failed"]?.integerValue ?? 0
        self.active = raw["status", "active"]?.integerValue ?? 0
        self.isSuspended = raw["spec", "suspend"] == .bool(true)
        self.startTime = raw["status", "startTime"]?.stringValue.flatMap(RFC3339.date(from:))
        self.completionTime = raw["status", "completionTime"]?.stringValue.flatMap(RFC3339.date(from:))
    }

    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
    private enum Key: String, CodingKey { case metadata }

    public var rowSummary: ResourceRowSummary {
        let target = completions ?? 1
        let fields: [ResourceRowSummary.Field] = [
            .init(label: "Completions", value: "\(succeeded)/\(target)"),
            .init(label: "Failed", value: "\(failed)"),
        ]
        if metadata.deletionTimestamp != nil {
            return ResourceRowSummary(headline: "Terminating", fields: fields, tone: .terminating)
        }
        if isSuspended {
            return ResourceRowSummary(headline: "Suspended", fields: fields, tone: .attention)
        }
        if succeeded >= target {
            return ResourceRowSummary(headline: "Complete", fields: fields, tone: .normal)
        }
        if failed > 0 {
            return ResourceRowSummary(headline: "Failed", fields: fields, tone: .failure)
        }
        if active > 0 {
            return ResourceRowSummary(headline: "Running", fields: fields, tone: .pending)
        }
        return ResourceRowSummary(headline: "Pending", fields: fields, tone: .pending)
    }
}

public struct CronJob: TypedResource {
    public static let typeIdentity = GroupVersionKind(apiVersion: "batch/v1", kind: "CronJob")
    public static let resourceName = "cronjobs"
    public static let isNamespaced = true

    public let metadata: ObjectMeta
    public let raw: JSONValue
    public let schedule: String?
    public let isSuspended: Bool
    public let activeCount: Int
    public let lastScheduleTime: Date?

    public init(from decoder: any Decoder) throws {
        self.raw = try JSONValue(from: decoder).addingTypeFields(Self.typeIdentity)
        let c = try decoder.container(keyedBy: Key.self)
        self.metadata = try c.decode(ObjectMeta.self, forKey: .metadata)
        self.schedule = raw["spec", "schedule"]?.stringValue
        self.isSuspended = raw["spec", "suspend"] == .bool(true)
        self.activeCount = raw["status", "active"]?.arrayValue?.count ?? 0
        self.lastScheduleTime = raw["status", "lastScheduleTime"]?.stringValue.flatMap(RFC3339.date(from:))
    }

    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
    private enum Key: String, CodingKey { case metadata }

    public var rowSummary: ResourceRowSummary {
        var fields: [ResourceRowSummary.Field] = []
        if let schedule { fields.append(.init(label: "Schedule", value: schedule)) }
        fields.append(.init(label: "Active", value: "\(activeCount)"))

        if metadata.deletionTimestamp != nil {
            return ResourceRowSummary(headline: "Terminating", fields: fields, tone: .terminating)
        }
        // A suspended CronJob looks healthy and silently never runs, so it is worth
        // saying out loud rather than showing the schedule as though it were active.
        if isSuspended {
            return ResourceRowSummary(headline: "Suspended", fields: fields, tone: .attention)
        }
        return ResourceRowSummary(
            headline: schedule ?? "Scheduled",
            fields: fields,
            tone: activeCount > 0 ? .pending : .normal
        )
    }
}
