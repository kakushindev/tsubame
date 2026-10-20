import Foundation
import KubeModels

/// Asks the cluster what the current user may do, one `SelfSubjectAccessReview`
/// at a time.
///
/// Deliberately not used before a list: a list already returns 403 and the watcher
/// already surfaces it, which is the authoritative answer and costs nothing extra.
/// This exists for the places where the answer is needed *before* acting — the RBAC
/// screen, and a write confirmation.
public actor SelfSubjectAccessReviewer: AccessReviewing {
    private let client: KubernetesClient
    private let discovery: any APIDiscovering
    private let coder: KubernetesCoder
    private let concurrencyLimit: Int
    private let cacheLifetime: TimeInterval
    private let now: @Sendable () -> Date

    private var cache: [ResourceAttributes: (decision: AccessDecision, at: Date)] = [:]

    public init(
        client: KubernetesClient,
        discovery: any APIDiscovering,
        coder: KubernetesCoder = KubernetesCoder(),
        concurrencyLimit: Int = 4,
        cacheLifetime: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.discovery = discovery
        self.coder = coder
        self.concurrencyLimit = max(1, concurrencyLimit)
        self.cacheLifetime = cacheLifetime
        self.now = now
    }

    public func decisions(
        for attributes: [ResourceAttributes]
    ) async -> [ResourceAttributes: AccessDecision] {
        var results: [ResourceAttributes: AccessDecision] = [:]
        var pending: [ResourceAttributes] = []
        for attribute in attributes {
            if let cached = cache[attribute], now().timeIntervalSince(cached.at) < cacheLifetime {
                results[attribute] = cached.decision
            } else {
                pending.append(attribute)
            }
        }
        guard !pending.isEmpty else { return results }

        guard await isServed() else {
            // One answer for all of them: the API is simply not there.
            for attribute in pending {
                let decision = AccessDecision.undetermined(.reviewUnavailable)
                results[attribute] = decision
                cache[attribute] = (decision, now())
            }
            return results
        }

        // A few at a time: a preflight screen asks about a dozen permissions, and
        // a dozen simultaneous POSTs is a burst the API server did not ask for.
        let limit = concurrencyLimit
        var index = 0
        while index < pending.count {
            let slice = Array(pending[index..<min(index + limit, pending.count)])
            let answered = await withTaskGroup(
                of: (ResourceAttributes, AccessDecision).self
            ) { group in
                for attribute in slice {
                    group.addTask { [self] in (attribute, await review(attribute)) }
                }
                var collected: [(ResourceAttributes, AccessDecision)] = []
                for await value in group { collected.append(value) }
                return collected
            }
            for (attribute, decision) in answered {
                results[attribute] = decision
                cache[attribute] = (decision, now())
            }
            index += limit
        }
        return results
    }

    /// Forgets every cached answer, for after a context's permissions may have
    /// changed.
    public func invalidate() {
        cache.removeAll()
    }

    private func isServed() async -> Bool {
        guard let catalog = try? await discovery.catalog() else { return false }
        return catalog.isServed(GroupVersion(group: "authorization.k8s.io", version: "v1"))
    }

    private func review(_ attributes: ResourceAttributes) async -> AccessDecision {
        let review = SelfSubjectAccessReview(resourceAttributes: attributes)
        do {
            let body = try coder.encoder.encode(review)
            let data = try await client.send(
                APIRequest(
                    method: .post,
                    path: "/apis/authorization.k8s.io/v1/selfsubjectaccessreviews",
                    headers: ["Content-Type": "application/json"],
                    body: body
                )
            )
            let answered = try coder.decoder.decode(SelfSubjectAccessReview.self, from: data)
            guard let status = answered.status else {
                return .undetermined(.requestFailed("the cluster returned no decision"))
            }
            return .from(status)
        } catch KubernetesError.permissionDenied {
            // Being refused the question is not the same as being refused the
            // action: say the check could not run.
            return .undetermined(.reviewForbidden)
        } catch KubernetesError.notFound {
            return .undetermined(.reviewUnavailable)
        } catch {
            return .undetermined(.requestFailed(error.localizedDescription))
        }
    }
}
