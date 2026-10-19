import Foundation

// MARK: - Service

public struct Service: TypedResource {
    public static let typeIdentity = GroupVersionKind(apiVersion: "v1", kind: "Service")
    public static let resourceName = "services"
    public static let isNamespaced = true

    public let metadata: ObjectMeta
    public let raw: JSONValue
    public let type: String
    public let clusterIP: String?
    public let externalIPs: [String]
    public let ports: [Port]

    public struct Port: Hashable, Sendable {
        public let name: String?
        public let port: Int
        public let targetPort: String?
        public let nodePort: Int?
        public let networkProtocol: String

        public var displayName: String {
            var text = "\(port)"
            if let nodePort { text += ":\(nodePort)" }
            return "\(text)/\(networkProtocol)"
        }
    }

    public init(from decoder: any Decoder) throws {
        self.raw = try JSONValue(from: decoder).addingTypeFields(Self.typeIdentity)
        let c = try decoder.container(keyedBy: Key.self)
        self.metadata = try c.decode(ObjectMeta.self, forKey: .metadata)
        self.type = raw["spec", "type"]?.stringValue ?? "ClusterIP"
        self.clusterIP = raw["spec", "clusterIP"]?.stringValue
        self.ports = (raw["spec", "ports"]?.arrayValue ?? []).compactMap { entry in
            guard let port = entry["port"]?.integerValue else { return nil }
            return Port(
                name: entry["name"]?.stringValue,
                port: port,
                targetPort: entry["targetPort"]?.stringValue
                    ?? entry["targetPort"]?.integerValue.map(String.init),
                nodePort: entry["nodePort"]?.integerValue,
                networkProtocol: entry["protocol"]?.stringValue ?? "TCP"
            )
        }
        // A LoadBalancer reports its address under status, and an ingress entry
        // carries either a hostname or an IP depending on the provider.
        var addresses = (raw["status", "loadBalancer", "ingress"]?.arrayValue ?? [])
            .compactMap { $0["ip"]?.stringValue ?? $0["hostname"]?.stringValue }
        addresses.append(contentsOf: (raw["spec", "externalIPs"]?.arrayValue ?? [])
            .compactMap(\.stringValue))
        self.externalIPs = addresses
    }

    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
    private enum Key: String, CodingKey { case metadata }

    public var rowSummary: ResourceRowSummary {
        var fields: [ResourceRowSummary.Field] = [
            .init(label: "Type", value: type),
            .init(label: "Cluster IP", value: clusterIP ?? "None"),
        ]
        if !ports.isEmpty {
            fields.append(.init(
                label: "Ports", value: ports.map(\.displayName).joined(separator: ", ")
            ))
        }
        if metadata.deletionTimestamp != nil {
            return ResourceRowSummary(headline: "Terminating", fields: fields, tone: .terminating)
        }
        // A LoadBalancer with no address yet is still being provisioned, which is
        // the single most common "why doesn't this work" question for Services.
        if type == "LoadBalancer", externalIPs.isEmpty {
            return ResourceRowSummary(headline: "Pending address", fields: fields, tone: .pending)
        }
        return ResourceRowSummary(headline: type, fields: fields, tone: .normal)
    }
}

// MARK: - Namespace

public struct Namespace: TypedResource {
    public static let typeIdentity = GroupVersionKind(apiVersion: "v1", kind: "Namespace")
    public static let resourceName = "namespaces"
    public static let isNamespaced = false

    public let metadata: ObjectMeta
    public let raw: JSONValue
    public let phase: String?

    public init(from decoder: any Decoder) throws {
        self.raw = try JSONValue(from: decoder).addingTypeFields(Self.typeIdentity)
        let c = try decoder.container(keyedBy: Key.self)
        self.metadata = try c.decode(ObjectMeta.self, forKey: .metadata)
        self.phase = raw["status", "phase"]?.stringValue
    }

    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
    private enum Key: String, CodingKey { case metadata }

    public var rowSummary: ResourceRowSummary {
        let phase = phase ?? "Unknown"
        return ResourceRowSummary(headline: phase, tone: Self.tone(forPhase: phase))
    }
}

// MARK: - Event

public struct Event: TypedResource {
    public static let typeIdentity = GroupVersionKind(apiVersion: "v1", kind: "Event")
    public static let resourceName = "events"
    public static let isNamespaced = true

    public let metadata: ObjectMeta
    public let raw: JSONValue
    public let type: String?
    public let reason: String?
    public let message: String?
    public let count: Int
    public let involvedObjectKind: String?
    public let involvedObjectName: String?
    /// When this event last happened, from whichever field the cluster populated.
    public let lastOccurrence: Date?

    public init(from decoder: any Decoder) throws {
        self.raw = try JSONValue(from: decoder).addingTypeFields(Self.typeIdentity)
        let c = try decoder.container(keyedBy: Key.self)
        self.metadata = try c.decode(ObjectMeta.self, forKey: .metadata)
        self.type = raw["type"]?.stringValue
        self.reason = raw["reason"]?.stringValue
        self.message = raw["message"]?.stringValue
        self.count = raw["count"]?.integerValue ?? 1
        self.involvedObjectKind = raw["involvedObject", "kind"]?.stringValue
        self.involvedObjectName = raw["involvedObject", "name"]?.stringValue
        // `eventTime` is a MicroTime and carries fractional seconds; the others are
        // whole-second Times. Any of them may be absent, so take the first present.
        self.lastOccurrence = [
            raw["lastTimestamp"]?.stringValue,
            raw["eventTime"]?.stringValue,
            raw["firstTimestamp"]?.stringValue,
        ]
        .compactMap { $0 }
        .compactMap(RFC3339.date(from:))
        .first
    }

    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
    private enum Key: String, CodingKey { case metadata }

    public var rowSummary: ResourceRowSummary {
        var fields: [ResourceRowSummary.Field] = []
        if let reason { fields.append(.init(label: "Reason", value: reason)) }
        if let kind = involvedObjectKind, let name = involvedObjectName {
            fields.append(.init(label: "Object", value: "\(kind)/\(name)"))
        }
        if count > 1 { fields.append(.init(label: "Count", value: "\(count)")) }
        if let message { fields.append(.init(label: "Message", value: message)) }

        return ResourceRowSummary(
            headline: reason ?? type ?? "Event",
            fields: fields,
            tone: type == "Warning" ? .attention : .normal
        )
    }
}

// MARK: - ConfigMap

public struct ConfigMap: TypedResource {
    public static let typeIdentity = GroupVersionKind(apiVersion: "v1", kind: "ConfigMap")
    public static let resourceName = "configmaps"
    public static let isNamespaced = true

    public let metadata: ObjectMeta
    public let raw: JSONValue
    public let data: [String: String]
    public let binaryDataKeys: [String]

    public init(from decoder: any Decoder) throws {
        self.raw = try JSONValue(from: decoder).addingTypeFields(Self.typeIdentity)
        let c = try decoder.container(keyedBy: Key.self)
        self.metadata = try c.decode(ObjectMeta.self, forKey: .metadata)
        self.data = raw["data"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
        self.binaryDataKeys = (raw["binaryData"]?.objectValue?.keys).map(Array.init)?.sorted() ?? []
    }

    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
    private enum Key: String, CodingKey { case metadata }

    public var rowSummary: ResourceRowSummary {
        let total = data.count + binaryDataKeys.count
        return ResourceRowSummary(
            headline: total == 1 ? "1 key" : "\(total) keys",
            fields: [.init(label: "Keys", value: data.keys.sorted().joined(separator: ", "))],
            tone: metadata.deletionTimestamp == nil ? .normal : .terminating
        )
    }
}

// MARK: - Secret

public struct Secret: TypedResource {
    public static let typeIdentity = GroupVersionKind(apiVersion: "v1", kind: "Secret")
    public static let resourceName = "secrets"
    public static let isNamespaced = true

    /// One decoded Secret entry.
    ///
    /// PRD §9.2 and §17 are explicit: when the user's RBAC allows reading a Secret,
    /// its values are shown as they are. There is no masking and no reveal step —
    /// listing a Secret already discloses it, so hiding it in the UI protects
    /// nothing and only makes the app less useful than `kubectl`.
    public enum Value: Hashable, Sendable {
        /// Base64-decoded and valid UTF-8: shown as text.
        case text(String)
        /// Decoded but not text. The API representation is kept, because there is
        /// nothing readable to show and base64 is what `raw` holds anyway.
        case binary(base64: String, byteCount: Int)

        public var isBinary: Bool {
            if case .binary = self { return true }
            return false
        }
    }

    public let metadata: ObjectMeta
    public let raw: JSONValue
    public let type: String?
    /// Entry names, sorted. A list row shows these; values belong in the detail.
    public let keys: [String]
    private let encodedData: [String: String]
    private let stringData: [String: String]

    public init(from decoder: any Decoder) throws {
        self.raw = try JSONValue(from: decoder).addingTypeFields(Self.typeIdentity)
        let c = try decoder.container(keyedBy: Key.self)
        self.metadata = try c.decode(ObjectMeta.self, forKey: .metadata)
        self.type = raw["type"]?.stringValue
        self.encodedData = raw["data"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
        self.stringData = raw["stringData"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
        self.keys = Set(encodedData.keys).union(stringData.keys).sorted()
    }

    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
    private enum Key: String, CodingKey { case metadata }

    /// The decoded entries, for the detail view.
    ///
    /// Computed on demand rather than at decode time: a list of a thousand Secrets
    /// would otherwise decode every value to show a key count.
    public var values: [String: Value] {
        var result: [String: Value] = [:]
        // `stringData` is write-only in the API and comes back under `data`, but a
        // manifest the user is editing may still carry it, so it is shown as-is.
        for (key, value) in stringData { result[key] = .text(value) }
        for (key, encoded) in encodedData {
            guard let bytes = Data(base64Encoded: encoded) else {
                // Not valid base64. Show what the API sent rather than dropping it.
                result[key] = .text(encoded)
                continue
            }
            if let text = String(data: bytes, encoding: .utf8) {
                result[key] = .text(text)
            } else {
                result[key] = .binary(base64: encoded, byteCount: bytes.count)
            }
        }
        return result
    }

    public var rowSummary: ResourceRowSummary {
        var fields: [ResourceRowSummary.Field] = [
            .init(label: "Keys", value: "\(keys.count)"),
        ]
        if let type { fields.append(.init(label: "Type", value: type)) }
        return ResourceRowSummary(
            headline: type ?? "Opaque",
            fields: fields,
            tone: metadata.deletionTimestamp == nil ? .normal : .terminating
        )
    }
}
