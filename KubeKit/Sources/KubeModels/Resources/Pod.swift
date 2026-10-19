import Foundation

/// A Pod, projected to the fields the list row, detail header, and log picker read.
///
/// `raw` holds the API's own representation and is decoded first, so the YAML view
/// and any manifest built from this object are byte-faithful. The projection below
/// is a convenience over `raw`, never a replacement for it.
public struct Pod: TypedResource {
    public static let typeIdentity = GroupVersionKind(apiVersion: "v1", kind: "Pod")
    public static let resourceName = "pods"
    public static let isNamespaced = true

    public let metadata: ObjectMeta
    public let spec: Spec
    public let status: Status
    public let raw: JSONValue

    public struct Spec: Hashable, Sendable, Codable {
        public var nodeName: String?
        public var restartPolicy: String?
        public var serviceAccountName: String?
        public var containers: [Container]
        public var initContainers: [Container]

        public static let empty = Spec(containers: [], initContainers: [])

        public init(
            nodeName: String? = nil,
            restartPolicy: String? = nil,
            serviceAccountName: String? = nil,
            containers: [Container] = [],
            initContainers: [Container] = []
        ) {
            self.nodeName = nodeName
            self.restartPolicy = restartPolicy
            self.serviceAccountName = serviceAccountName
            self.containers = containers
            self.initContainers = initContainers
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            nodeName = try c.decodeIfPresent(String.self, forKey: .nodeName)
            restartPolicy = try c.decodeIfPresent(String.self, forKey: .restartPolicy)
            serviceAccountName = try c.decodeIfPresent(String.self, forKey: .serviceAccountName)
            containers = try c.decodeIfPresent([Container].self, forKey: .containers) ?? []
            initContainers = try c.decodeIfPresent([Container].self, forKey: .initContainers) ?? []
        }

        private enum Key: String, CodingKey {
            case nodeName, restartPolicy, serviceAccountName, containers, initContainers
        }
    }

    public struct Container: Hashable, Sendable, Codable {
        public var name: String
        public var image: String?

        public init(name: String, image: String? = nil) {
            self.name = name
            self.image = image
        }
    }

    public struct Status: Hashable, Sendable, Codable {
        public var phase: String?
        public var podIP: String?
        public var startTime: Date?
        public var reason: String?
        public var containerStatuses: [ContainerStatus]
        public var initContainerStatuses: [ContainerStatus]
        public var conditions: [Condition]

        public static let empty = Status()

        public init(
            phase: String? = nil,
            podIP: String? = nil,
            startTime: Date? = nil,
            reason: String? = nil,
            containerStatuses: [ContainerStatus] = [],
            initContainerStatuses: [ContainerStatus] = [],
            conditions: [Condition] = []
        ) {
            self.phase = phase
            self.podIP = podIP
            self.startTime = startTime
            self.reason = reason
            self.containerStatuses = containerStatuses
            self.initContainerStatuses = initContainerStatuses
            self.conditions = conditions
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            phase = try c.decodeIfPresent(String.self, forKey: .phase)
            podIP = try c.decodeIfPresent(String.self, forKey: .podIP)
            startTime = try c.decodeIfPresent(Date.self, forKey: .startTime)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            containerStatuses = try c.decodeIfPresent(
                [ContainerStatus].self, forKey: .containerStatuses) ?? []
            initContainerStatuses = try c.decodeIfPresent(
                [ContainerStatus].self, forKey: .initContainerStatuses) ?? []
            conditions = try c.decodeIfPresent([Condition].self, forKey: .conditions) ?? []
        }

        private enum Key: String, CodingKey {
            case phase, podIP, startTime, reason
            case containerStatuses, initContainerStatuses, conditions
        }
    }

    public struct ContainerStatus: Hashable, Sendable, Codable {
        public var name: String
        public var ready: Bool
        public var restartCount: Int
        /// The reason the container is waiting or terminated, such as
        /// `CrashLoopBackOff`. This is what a row shows when a pod is unhealthy,
        /// because "Running" would be a lie at that point.
        public var stateReason: String?
        public var isTerminated: Bool
        /// Whether a previous instance exists, which is what makes previous-container
        /// logs available. Offering them otherwise produces a 400.
        public var hasPreviousInstance: Bool

        public init(
            name: String,
            ready: Bool = false,
            restartCount: Int = 0,
            stateReason: String? = nil,
            isTerminated: Bool = false,
            hasPreviousInstance: Bool = false
        ) {
            self.name = name
            self.ready = ready
            self.restartCount = restartCount
            self.stateReason = stateReason
            self.isTerminated = isTerminated
            self.hasPreviousInstance = hasPreviousInstance
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            ready = try c.decodeIfPresent(Bool.self, forKey: .ready) ?? false
            restartCount = try c.decodeIfPresent(Int.self, forKey: .restartCount) ?? 0

            let state = try c.decodeIfPresent(JSONValue.self, forKey: .state)
            stateReason = state?["waiting", "reason"]?.stringValue
                ?? state?["terminated", "reason"]?.stringValue
            isTerminated = state?["terminated"] != nil

            let lastState = try c.decodeIfPresent(JSONValue.self, forKey: .lastState)
            hasPreviousInstance = lastState?["terminated"] != nil
        }

        private enum Key: String, CodingKey {
            case name, ready, restartCount, state, lastState
        }
    }

    public struct Condition: Hashable, Sendable, Codable {
        public var type: String
        public var status: String
        public var reason: String?
        public var message: String?
        public var lastTransitionTime: Date?

        public init(
            type: String,
            status: String,
            reason: String? = nil,
            message: String? = nil,
            lastTransitionTime: Date? = nil
        ) {
            self.type = type
            self.status = status
            self.reason = reason
            self.message = message
            self.lastTransitionTime = lastTransitionTime
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            message = try c.decodeIfPresent(String.self, forKey: .message)
            lastTransitionTime = try c.decodeIfPresent(Date.self, forKey: .lastTransitionTime)
        }

        private enum Key: String, CodingKey {
            case type, status, reason, message, lastTransitionTime
        }
    }

    public init(from decoder: any Decoder) throws {
        self.raw = try JSONValue(from: decoder).addingTypeFields(Self.typeIdentity)
        let c = try decoder.container(keyedBy: Key.self)
        self.metadata = try c.decode(ObjectMeta.self, forKey: .metadata)
        self.spec = try c.decodeIfPresent(Spec.self, forKey: .spec) ?? .empty
        self.status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .empty
    }

    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }

    private enum Key: String, CodingKey { case metadata, spec, status }

    // MARK: - Presentation

    /// Every container a log stream could target, init containers included.
    public var allContainers: [Container] { spec.initContainers + spec.containers }

    public var readyContainerCount: Int { status.containerStatuses.filter(\.ready).count }
    public var totalContainerCount: Int {
        max(status.containerStatuses.count, spec.containers.count)
    }
    public var restartCount: Int {
        status.containerStatuses.reduce(0) { $0 + $1.restartCount }
    }

    public var rowSummary: ResourceRowSummary {
        var fields: [ResourceRowSummary.Field] = [
            .init(label: "Ready", value: "\(readyContainerCount)/\(totalContainerCount)"),
            .init(label: "Restarts", value: "\(restartCount)"),
        ]
        if let node = spec.nodeName { fields.append(.init(label: "Node", value: node)) }

        if metadata.deletionTimestamp != nil {
            return ResourceRowSummary(headline: "Terminating", fields: fields, tone: .terminating)
        }
        // A waiting or crashing container is the useful headline. "Running" while a
        // container is in CrashLoopBackOff is technically the phase and practically
        // a lie.
        if let blocked = status.containerStatuses.first(where: { !$0.ready && $0.stateReason != nil }),
           let reason = blocked.stateReason {
            return ResourceRowSummary(
                headline: reason,
                fields: fields,
                tone: Self.tone(forContainerReason: reason)
            )
        }
        if let reason = status.reason {
            return ResourceRowSummary(headline: reason, fields: fields, tone: .failure)
        }
        let phase = status.phase ?? "Unknown"
        var tone = Self.tone(forPhase: phase)
        if phase == "Running", totalContainerCount > 0, readyContainerCount < totalContainerCount {
            tone = .pending
        }
        return ResourceRowSummary(headline: phase, fields: fields, tone: tone)
    }

    private static func tone(forContainerReason reason: String) -> ResourceRowSummary.Tone {
        switch reason {
        case "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull",
             "CreateContainerError", "InvalidImageName", "OOMKilled":
            return .failure
        case "ContainerCreating", "PodInitializing", "Pending":
            return .pending
        case "Completed":
            return .normal
        default:
            return .attention
        }
    }
}
