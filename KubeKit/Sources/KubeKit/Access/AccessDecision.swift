import Foundation
import KubeModels

/// What the cluster said about one permission.
///
/// Three states, not a boolean. PRD §9.7 forbids telling the user an action will
/// succeed when the check did not actually answer, and a check can fail to answer
/// in several ordinary ways: the authorization API may not be served, the review
/// itself may be refused, or the authorizer may error while deciding.
public enum AccessDecision: Hashable, Sendable {
    case allowed(reason: String?)
    case denied(reason: String?)
    /// The cluster did not answer. Never rendered as either of the others.
    case undetermined(Reason)

    public enum Reason: Hashable, Sendable {
        case notChecked
        /// `authorization.k8s.io` is not served here.
        case reviewUnavailable
        /// RBAC refused the review request itself.
        case reviewForbidden
        /// The authorizer reported a problem while deciding.
        case evaluationError(String)
        /// `SelfSubjectRulesReview` said its answer was incomplete.
        case rulesIncomplete
        case requestFailed(String)

        public var message: String {
            switch self {
            case .notChecked:
                return "Not checked."
            case .reviewUnavailable:
                return "This cluster does not serve the authorization API, so permissions "
                    + "cannot be checked ahead of time."
            case .reviewForbidden:
                return "Your account may not ask what it is allowed to do."
            case .evaluationError(let detail):
                return "The cluster could not decide: \(detail)"
            case .rulesIncomplete:
                return "The cluster's answer was incomplete, so this is not covered by it."
            case .requestFailed(let detail):
                return "The check could not be completed: \(detail)"
            }
        }
    }

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var isDenied: Bool {
        if case .denied = self { return true }
        return false
    }

    /// Whether an action should be offered.
    ///
    /// Undetermined counts as offerable: disabling an action because the check did
    /// not answer would hide something the user may well be allowed to do, and the
    /// cluster refuses it anyway if they are not.
    public var permitsAttempt: Bool { !isDenied }

    /// Builds the decision from a review the server answered.
    ///
    /// `allowed` beside an `evaluationError` is deliberately **not** allowed: a
    /// webhook authorizer that failed may have failed open, and the honest answer
    /// is that we do not know.
    public static func from(_ status: SubjectAccessReviewStatus) -> AccessDecision {
        if status.denied == true { return .denied(reason: status.reason) }
        if let evaluationError = status.evaluationError, !evaluationError.isEmpty {
            return .undetermined(.evaluationError(evaluationError))
        }
        return status.allowed ? .allowed(reason: status.reason) : .denied(reason: status.reason)
    }
}

/// Answers permission questions for the current user.
public protocol AccessReviewing: Sendable {
    /// One decision per attribute.
    ///
    /// Never throws: a check that fails is a decision — `.undetermined` — not an
    /// error that takes a screen down with it.
    func decisions(for attributes: [ResourceAttributes]) async -> [ResourceAttributes: AccessDecision]
}

extension AccessReviewing {
    public func decision(for attribute: ResourceAttributes) async -> AccessDecision {
        await decisions(for: [attribute])[attribute] ?? .undetermined(.notChecked)
    }
}
