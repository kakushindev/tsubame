import Foundation
import KubeModels

public struct WriteTarget: Hashable, Sendable {
    public let resource: DiscoveredResource
    public let namespace: String?
    public let name: String

    public init(resource: DiscoveredResource, namespace: String?, name: String) {
        self.resource = resource
        self.namespace = namespace
        self.name = name
    }
}

public enum WriteIntent: Hashable, Sendable {
    case apply(manifest: String)
    case delete(uid: String, resourceVersion: String)
    case restart(at: Date)
    case scale(replicas: Int, resourceVersion: String)
}

public struct WritePlan: Sendable {
    public let target: WriteTarget
    public let intent: WriteIntent
    public let warnings: [String]
    fileprivate let request: APIRequest
    fileprivate let owner: UUID
}

/// Only ResourceWriter can construct a rehearsal. A live write requires one.
public struct WriteRehearsal: Sendable {
    public let plan: WritePlan
    public let proposed: JSONValue
    public let warnings: [String]
    fileprivate let liveRequest: APIRequest
}

public struct FieldOwnershipConflict: Hashable, Sendable {
    public let rawMessage: String

    /// Server prose is not a stable grammar. Keep even an unrecognized message.
    public static func conflicts(in message: String) -> [FieldOwnershipConflict] {
        [FieldOwnershipConflict(rawMessage: message)]
    }
}

public enum WriteError: Error, Sendable, LocalizedError {
    case invalid(String)
    case fieldOwnershipConflict([FieldOwnershipConflict])
    case changedSinceRehearsal(WriteRehearsal)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .fieldOwnershipConflict(let conflicts): return conflicts.map(\.rawMessage).joined(separator: "\n")
        case .changedSinceRehearsal: return "The server's proposed result changed. Review the new dry-run before applying."
        }
    }
}

/// The write boundary for one cluster. It never forces field ownership and it
/// never retries a failed dry-run as a live operation.
public final class ResourceWriter: Sendable {
    public static let fieldManager = "tsubame"
    private let client: KubernetesClient
    private let owner = UUID()
    private let parser = ManifestParser()

    public init(client: KubernetesClient) { self.client = client }

    public func plan(_ intent: WriteIntent, target: WriteTarget) throws -> WritePlan {
        guard Self.validSegment(target.name),
              !target.resource.isNamespaced || target.namespace.map(Self.validSegment) == true,
              target.resource.isNamespaced || target.namespace == nil else {
            throw WriteError.invalid("Choose a valid name and namespace for this target.")
        }
        let path = target.resource.groupVersionResource.objectPath(namespace: target.namespace, name: target.name)
        var warnings: [String] = []
        let request: APIRequest
        switch intent {
        case .apply(let text):
            try require("patch", on: target)
            let manifest = try parser.parse(text)
            guard manifest["apiVersion"]?.stringValue == target.resource.groupVersion.apiVersion,
                  manifest["kind"]?.stringValue == target.resource.kind,
                  manifest["metadata", "name"]?.stringValue == target.name,
                  manifest["metadata", "namespace"]?.stringValue == target.namespace else {
                throw WriteError.invalid("apiVersion, kind, name, and namespace must match the selected target.")
            }
            if manifest["status"] != nil || ["uid", "resourceVersion", "generation", "managedFields", "creationTimestamp"].contains(where: { manifest["metadata", $0] != nil }) {
                warnings.append("The manifest includes server-owned fields. You may remove them from your draft before reviewing again.")
            }
            // Send the validated source itself: JSONEncoder normalizes 1.0 to 1,
            // and rewriting YAML here would change the user's reviewed manifest.
            request = APIRequest(method: .patch, path: path,
                                 queryItems: [URLQueryItem(name: "fieldManager", value: Self.fieldManager)],
                                 headers: ["Content-Type": APIRequest.PatchKind.apply.rawValue], body: Data(text.utf8))
        case .delete(let uid, let version):
            try require("delete", on: target)
            guard !uid.isEmpty, !version.isEmpty else { throw WriteError.invalid("Reload the object before deleting it.") }
            request = APIRequest(method: .delete, path: path, headers: ["Content-Type": "application/json"], body: try JSONEncoder().encode(JSONValue.object([
                "apiVersion": .string("v1"), "kind": .string("DeleteOptions"),
                "preconditions": .object(["uid": .string(uid), "resourceVersion": .string(version)]),
            ])))
            warnings.append("Dry-run validates this delete request; it does not predict which dependent resources garbage collection will remove.")
        case .restart(let date):
            try require("patch", on: target)
            guard target.resource.groupVersion.group == "apps",
                  ["Deployment", "StatefulSet", "DaemonSet"].contains(target.resource.kind) else {
                throw WriteError.invalid("Only Deployments, StatefulSets, and DaemonSets support restart.")
            }
            var metadata: [String: JSONValue] = ["name": .string(target.name)]
            if let namespace = target.namespace { metadata["namespace"] = .string(namespace) }
            request = try patch(path: path, body: .object([
                "apiVersion": .string(target.resource.groupVersion.apiVersion), "kind": .string(target.resource.kind),
                "metadata": .object(metadata),
                "spec": .object(["template": .object(["metadata": .object(["annotations": .object([
                    "kubectl.kubernetes.io/restartedAt": .string(date.ISO8601Format()),
                ])])])]),
            ]), kind: .apply)
        case .scale(let replicas, let version):
            guard target.resource.subresources.contains("scale"), replicas >= 0, !version.isEmpty else {
                throw WriteError.invalid("Scale requires a scale subresource, a current resource version, and a nonnegative replica count.")
            }
            request = try patch(path: path + "/scale", body: .object([
                "metadata": .object(["resourceVersion": .string(version)]),
                "spec": .object(["replicas": .integer(replicas)]),
            ]), kind: .merge)
        }
        return WritePlan(target: target, intent: intent, warnings: warnings, request: request, owner: owner)
    }

    public func rehearse(_ plan: WritePlan) async throws -> WriteRehearsal {
        guard plan.owner == owner else { throw WriteError.invalid("Review this operation on its original cluster.") }
        do {
            let response = try await client.perform(plan.request.dryRun())
            let proposed = try JSONDecoder().decode(JSONValue.self, from: response.body)
            let warnings = response.headers.filter { $0.key.caseInsensitiveCompare("Warning") == .orderedSame }.map(\.value)
            return WriteRehearsal(plan: plan, proposed: proposed, warnings: plan.warnings + warnings, liveRequest: plan.request)
        } catch KubernetesError.conflict(let status) {
            throw WriteError.fieldOwnershipConflict(FieldOwnershipConflict.conflicts(in: status?.message ?? "The server reported a conflict. Reload and review the object."))
        }
    }

    /// Called only by the separate user action after review. Rehearsing again
    /// catches admission/defaulting changes; the approved request bytes stay fixed.
    public func commit(_ rehearsal: WriteRehearsal) async throws -> APIResponse {
        let current = try await rehearse(rehearsal.plan)
        guard ResourceDiff.reviewValue(current.proposed) == ResourceDiff.reviewValue(rehearsal.proposed),
              current.warnings == rehearsal.warnings else {
            throw WriteError.changedSinceRehearsal(current)
        }
        try Task.checkCancellation()
        return try await client.perform(rehearsal.liveRequest)
    }

    private func patch(path: String, body: JSONValue, kind: APIRequest.PatchKind) throws -> APIRequest {
        APIRequest(method: .patch, path: path,
                   queryItems: [URLQueryItem(name: "fieldManager", value: Self.fieldManager)],
                   headers: ["Content-Type": kind.rawValue], body: try JSONEncoder().encode(body))
    }

    private func require(_ verb: String, on target: WriteTarget) throws {
        guard target.resource.supports(verb) else { throw WriteError.invalid("The discovered API does not support this operation.") }
    }

    private static func validSegment(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
        }
    }
}
