import Foundation

/// What a permission question is about: a verb on a resource, optionally in one
/// namespace and on one object.
public struct ResourceAttributes: Hashable, Sendable, Codable {
    public var namespace: String?
    public var verb: String
    public var group: String
    public var version: String
    /// Plural, as the API names it.
    public var resource: String
    /// `log`, `scale`, and the like.
    public var subresource: String?
    public var name: String?

    public init(
        namespace: String? = nil,
        verb: String,
        group: String = "",
        version: String = "",
        resource: String,
        subresource: String? = nil,
        name: String? = nil
    ) {
        self.namespace = namespace
        self.verb = verb
        self.group = group
        self.version = version
        self.resource = resource
        self.subresource = subresource
        self.name = name
    }

    public init(from decoder: any Decoder) throws {
        // The API omits what is empty: the core group has no `group`, and a
        // question about every version has no `version`. Synthesised decoding
        // would require both and fail on the server's own answer.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        namespace = try c.decodeIfPresent(String.self, forKey: .namespace)
        verb = try c.decodeIfPresent(String.self, forKey: .verb) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        resource = try c.decodeIfPresent(String.self, forKey: .resource) ?? ""
        subresource = try c.decodeIfPresent(String.self, forKey: .subresource)
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }

    private enum CodingKeys: String, CodingKey {
        case namespace, verb, group, version, resource, subresource, name
    }

    /// How the question reads in the RBAC screen and in a Role example.
    public var displayName: String {
        var text = resource
        if let subresource { text += "/\(subresource)" }
        if !group.isEmpty { text += ".\(group)" }
        return "\(verb) \(text)"
    }
}

/// `authorization.k8s.io/v1` SelfSubjectAccessReview: asks the server what the
/// current user may do, without needing permission to read any policy.
public struct SelfSubjectAccessReview: Hashable, Sendable, Codable {
    public var resourceAttributes: ResourceAttributes
    public var status: SubjectAccessReviewStatus?

    public init(resourceAttributes: ResourceAttributes, status: SubjectAccessReviewStatus? = nil) {
        self.resourceAttributes = resourceAttributes
        self.status = status
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let spec = try container.nestedContainer(keyedBy: SpecKeys.self, forKey: .spec)
        resourceAttributes = try spec.decode(ResourceAttributes.self, forKey: .resourceAttributes)
        status = try container.decodeIfPresent(SubjectAccessReviewStatus.self, forKey: .status)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("authorization.k8s.io/v1", forKey: .apiVersion)
        try container.encode("SelfSubjectAccessReview", forKey: .kind)
        var spec = container.nestedContainer(keyedBy: SpecKeys.self, forKey: .spec)
        try spec.encode(resourceAttributes, forKey: .resourceAttributes)
    }

    private enum CodingKeys: String, CodingKey { case apiVersion, kind, spec, status }
    private enum SpecKeys: String, CodingKey { case resourceAttributes }
}

public struct SubjectAccessReviewStatus: Hashable, Sendable, Codable {
    public let allowed: Bool
    /// Set when the authorizer denied outright, as opposed to merely not allowing.
    public let denied: Bool?
    public let reason: String?
    /// The authorizer hit a problem deciding. An `allowed` beside this cannot be
    /// trusted — see `AccessDecision`.
    public let evaluationError: String?

    public init(
        allowed: Bool,
        denied: Bool? = nil,
        reason: String? = nil,
        evaluationError: String? = nil
    ) {
        self.allowed = allowed
        self.denied = denied
        self.reason = reason
        self.evaluationError = evaluationError
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowed = try c.decodeIfPresent(Bool.self, forKey: .allowed) ?? false
        denied = try c.decodeIfPresent(Bool.self, forKey: .denied)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        evaluationError = try c.decodeIfPresent(String.self, forKey: .evaluationError)
    }

    private enum CodingKeys: String, CodingKey { case allowed, denied, reason, evaluationError }
}
