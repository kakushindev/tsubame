import SwiftUI
import KubeKit
import KubeModels

/// What Tsubame needs permission to do, what this account may do, and a policy
/// an administrator can install.
struct RBACHelpView: View {
    @State var model: RBACHelpModel
    var close: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Cluster", value: model.cluster)
                    LabeledContent("Namespace", value: model.namespace)
                } footer: {
                    Text("Checked for the account used to connect to this cluster.")
                }

                if let inconclusive = model.inconclusive {
                    Section {
                        Label {
                            Text(inconclusive)
                        } icon: {
                            Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                        }
                    } footer: {
                        // PRD §9.7: never imply an action will succeed when the
                        // check did not answer.
                        Text("Actions are still offered. The cluster decides when you use them.")
                    }
                }

                ForEach(model.workflows) { workflow in
                    workflowSection(workflow)
                }

                Section {
                    CopyableCodeBlock(text: model.roleYAML)
                } header: {
                    Text("Least-privilege policy")
                } footer: {
                    Text("An administrator must review and install this. Tsubame never grants "
                         + "itself permissions.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Permissions")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
                ToolbarItem(placement: .automatic) {
                    Button("Check Again") { Task { await model.check() } }
                        .disabled(model.isChecking)
                }
            }
            .task { await model.check() }
            .overlay {
                if model.isChecking && model.checks.isEmpty {
                    ProgressView("Checking permissions…")
                }
            }
        }
        .frame(idealWidth: 620, idealHeight: 680)
    }

    private func workflowSection(_ workflow: RBACHelpModel.Workflow) -> some View {
        Section {
            ForEach(model.checks(for: workflow)) { check in
                row(check)
            }
        } header: {
            Text(workflow.title)
        } footer: {
            Text(workflow.detail)
        }
    }

    private func row(_ check: RBACHelpModel.Check) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(check.decision))
                .foregroundStyle(tint(check.decision))
            VStack(alignment: .leading, spacing: 2) {
                Text(check.attribute.displayName).font(.body.monospaced())
                if let detail = detail(check.decision) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(label(check.decision)).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.attribute.displayName): \(label(check.decision))")
    }

    private func symbol(_ decision: AccessDecision) -> String {
        switch decision {
        case .allowed: "checkmark.circle.fill"
        case .denied: "xmark.octagon.fill"
        case .undetermined: "questionmark.circle.fill"
        }
    }

    private func tint(_ decision: AccessDecision) -> Color {
        switch decision {
        case .allowed: .green
        case .denied: .red
        // Not a failure, and deliberately not green: nobody knows.
        case .undetermined: .orange
        }
    }

    private func label(_ decision: AccessDecision) -> String {
        switch decision {
        case .allowed: "Allowed"
        case .denied: "Denied"
        case .undetermined: "Unknown"
        }
    }

    private func detail(_ decision: AccessDecision) -> String? {
        switch decision {
        case .allowed(let reason), .denied(let reason): reason
        case .undetermined(let reason): reason.message
        }
    }
}
