import Foundation
import Observation
import KubeKit
import KubeModels

/// What Tsubame needs permission to do, and what this account may actually do.
///
/// The screen exists because a denial mid-task is a bad way to learn about a
/// missing permission. It checks ahead and says plainly when it could not check
/// at all, which PRD §9.7 requires: an unanswered check is never reported as
/// permission granted.
@MainActor @Observable
final class RBACHelpModel {
    /// A group of permissions that belong to one thing the user does.
    struct Workflow: Identifiable {
        let id: String
        let title: String
        let detail: String
        let attributes: [ResourceAttributes]
    }

    struct Check: Identifiable {
        let id: String
        let attribute: ResourceAttributes
        let decision: AccessDecision
    }

    private(set) var checks: [String: [Check]] = [:]
    private(set) var isChecking = false
    /// Set when nothing could be checked, as opposed to individual unknowns.
    private(set) var inconclusive: String?

    let namespace: String
    let cluster: String
    private let reviewer: any AccessReviewing

    init(cluster: String, namespace: String, reviewer: any AccessReviewing) {
        self.cluster = cluster
        self.namespace = namespace
        self.reviewer = reviewer
    }

    /// The workflows the app actually performs, in the order a user meets them.
    var workflows: [Workflow] {
        [
            Workflow(
                id: "browse", title: "Browse resources",
                detail: "Listing and watching the kinds in the navigator.",
                attributes: Self.browse(in: namespace)
            ),
            Workflow(
                id: "logs", title: "Read pod logs",
                detail: "Streaming a container's output.",
                attributes: [
                    ResourceAttributes(namespace: namespace, verb: "get", version: "v1",
                                       resource: "pods", subresource: "log"),
                ]
            ),
            Workflow(
                id: "apply", title: "Edit and apply YAML",
                detail: "A server-side dry run, then the apply itself.",
                attributes: [
                    ResourceAttributes(namespace: namespace, verb: "patch", version: "v1",
                                       resource: "configmaps"),
                    ResourceAttributes(namespace: namespace, verb: "patch", group: "apps",
                                       version: "v1", resource: "deployments"),
                ]
            ),
            Workflow(
                id: "act", title: "Delete, restart and scale",
                detail: "Restart patches the pod template; scale uses the scale subresource.",
                attributes: [
                    ResourceAttributes(namespace: namespace, verb: "delete", version: "v1",
                                       resource: "pods"),
                    ResourceAttributes(namespace: namespace, verb: "patch", group: "apps",
                                       version: "v1", resource: "deployments"),
                    ResourceAttributes(namespace: namespace, verb: "patch", group: "apps",
                                       version: "v1", resource: "deployments",
                                       subresource: "scale"),
                ]
            ),
        ]
    }

    private static func browse(in namespace: String) -> [ResourceAttributes] {
        [("", "pods"), ("apps", "deployments"), ("", "services"), ("", "configmaps"),
         ("", "secrets"), ("", "events")].flatMap { group, resource in
            ["list", "watch"].map {
                ResourceAttributes(namespace: namespace, verb: $0, group: group,
                                   version: "v1", resource: resource)
            }
        }
    }

    func check() async {
        isChecking = true
        defer { isChecking = false }
        inconclusive = nil

        let all = workflows.flatMap(\.attributes)
        let decisions = await reviewer.decisions(for: all)

        var grouped: [String: [Check]] = [:]
        for workflow in workflows {
            grouped[workflow.id] = workflow.attributes.map { attribute in
                Check(
                    id: "\(workflow.id)/\(attribute.displayName)",
                    attribute: attribute,
                    decision: decisions[attribute] ?? .undetermined(.notChecked)
                )
            }
        }
        checks = grouped

        // Every answer unknown for the same reason means the cluster did not
        // answer at all, which is worth saying once rather than on every row.
        let reasons = grouped.values.flatMap { $0 }.map(\.decision)
        if !reasons.isEmpty, reasons.allSatisfy({ if case .undetermined = $0 { true } else { false } }) {
            if case .undetermined(let reason) = reasons[0] { inconclusive = reason.message }
        }
    }

    func checks(for workflow: Workflow) -> [Check] { checks[workflow.id] ?? [] }

    /// A least-privilege Role covering exactly what the screen checked.
    ///
    /// Generated from the same attributes, so the policy shown and the
    /// permissions checked cannot drift apart.
    var roleYAML: String {
        let attributes = workflows.flatMap(\.attributes)
        var byGroup: [String: (resources: Set<String>, verbs: Set<String>)] = [:]
        for attribute in attributes {
            var resource = attribute.resource
            if let subresource = attribute.subresource { resource += "/\(subresource)" }
            var entry = byGroup[attribute.group] ?? ([], [])
            entry.resources.insert(resource)
            entry.verbs.insert(attribute.verb)
            byGroup[attribute.group] = entry
        }

        let rules = byGroup.keys.sorted().map { group -> String in
            let entry = byGroup[group]!
            return """
              - apiGroups: ["\(group)"]
                resources: [\(entry.resources.sorted().map { "\"\($0)\"" }.joined(separator: ", "))]
                verbs: [\(entry.verbs.sorted().map { "\"\($0)\"" }.joined(separator: ", "))]
            """
        }.joined(separator: "\n")

        return """
        # Least-privilege Role for Tsubame in the \(namespace) namespace.
        # An administrator must review and install this; Tsubame cannot grant
        # itself permissions.
        apiVersion: rbac.authorization.k8s.io/v1
        kind: Role
        metadata:
          name: tsubame
          namespace: \(namespace)
        rules:
        \(rules)
        ---
        apiVersion: rbac.authorization.k8s.io/v1
        kind: RoleBinding
        metadata:
          name: tsubame
          namespace: \(namespace)
        subjects:
          - kind: User
            name: YOUR-USERNAME
            apiGroup: rbac.authorization.k8s.io
        roleRef:
          kind: Role
          name: tsubame
          apiGroup: rbac.authorization.k8s.io
        """
    }
}
