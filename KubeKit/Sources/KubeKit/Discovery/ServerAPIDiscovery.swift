import Foundation
import KubeModels

/// Discovery against a live API server, with the result cached per instance.
///
/// The requests run one after another rather than concurrently: a cluster with many
/// aggregated groups would otherwise open dozens of sockets at once on a phone, and
/// discovery is a once-per-connection cost that a user already expects to wait for.
public actor ServerAPIDiscovery: APIDiscovering {
    private let client: KubernetesClient
    private let coder: KubernetesCoder

    private var cached: APIResourceCatalog?
    private var inFlight: Task<APIResourceCatalog, any Error>?
    /// Distinguishes the pass that owns `cached` from one a `refresh()` superseded.
    private var generation = 0

    public init(client: KubernetesClient, coder: KubernetesCoder = KubernetesCoder()) {
        self.client = client
        self.coder = coder
    }

    public func catalog() async throws -> APIResourceCatalog {
        if let cached { return cached }
        return try await load()
    }

    @discardableResult
    public func refresh() async throws -> APIResourceCatalog {
        await invalidate()
        return try await load()
    }

    public func invalidate() async {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        cached = nil
    }

    public func resource(forKind kind: String, inGroup group: String?) async throws -> DiscoveredResource {
        let catalog = try await catalog()
        if let match = catalog.resource(forKind: kind, inGroup: group) { return match }

        if case .permissionDenied(let message) = catalog.denial(forKind: kind, inGroup: group) {
            throw KubernetesError.permissionDenied(
                status: KubernetesStatus(
                    status: "Failure",
                    message: message ?? "Your permissions do not allow discovering \(kind).",
                    reason: "Forbidden",
                    code: 403,
                    details: nil
                )
            )
        }

        throw KubernetesError.notFound(
            status: KubernetesStatus(
                status: "Failure",
                message: "This cluster does not serve the kind \(kind).",
                reason: "NotFound",
                code: 404,
                details: nil
            )
        )
    }

    /// Shares one pass between concurrent callers, so opening three views at once
    /// does not discover three times.
    private func load() async throws -> APIResourceCatalog {
        if let inFlight { return try await inFlight.value }

        generation += 1
        let pass = generation
        let task = Task { try await self.fetchCatalog() }
        inFlight = task

        do {
            let catalog = try await task.value
            if pass == generation {
                cached = catalog
                inFlight = nil
            }
            return catalog
        } catch {
            if pass == generation { inFlight = nil }
            throw error
        }
    }

    private func fetchCatalog() async throws -> APIResourceCatalog {
        var groupVersions: [GroupVersion] = []
        var resources: [DiscoveredResource] = []
        var failures: [GroupVersion: DiscoveryFailure] = [:]

        // The core group answers at /api and names no preferred version, so the
        // first version it lists is treated as preferred. In practice that is v1.
        let coreVersions = try await decode(APIVersions.self, atPath: "/api").versions
        for (index, version) in coreVersions.enumerated() {
            try Task.checkCancellation()
            let groupVersion = GroupVersion(group: "", version: version)
            groupVersions.append(groupVersion)
            switch await resourceList(for: groupVersion, isPreferred: index == 0) {
            case .success(let discovered): resources.append(contentsOf: discovered)
            case .failure(let failure): failures[groupVersion] = failure
            }
        }

        let groups = try await decode(APIGroupList.self, atPath: "/apis").groups
        for group in groups {
            try Task.checkCancellation()
            let preferred = group.preferredVersion?.parsed
            for description in group.versions {
                try Task.checkCancellation()
                let groupVersion = description.parsed
                groupVersions.append(groupVersion)
                switch await resourceList(for: groupVersion, isPreferred: groupVersion == preferred) {
                case .success(let discovered): resources.append(contentsOf: discovered)
                case .failure(let failure): failures[groupVersion] = failure
                }
            }
        }

        return APIResourceCatalog(
            groupVersions: groupVersions,
            resources: resources,
            failures: failures,
            discoveredAt: Date()
        )
    }

    /// One group-version's resource list. A failure here is recorded rather than
    /// thrown: a single unreachable aggregated API server, or one group the user may
    /// not read, must not blank out the rest of the cluster.
    private func resourceList(
        for groupVersion: GroupVersion,
        isPreferred: Bool
    ) async -> Result<[DiscoveredResource], DiscoveryFailure> {
        do {
            let list = try await decode(APIResourceList.self, atPath: groupVersion.pathPrefix)
            return .success(
                Self.discovered(in: list, groupVersion: groupVersion, isPreferred: isPreferred)
            )
        } catch let error as KubernetesError {
            switch error {
            case .permissionDenied(let status), .unauthenticated(let status):
                return .failure(.permissionDenied(message: status?.message))
            default:
                return .failure(.unavailable(reason: error.errorDescription ?? "\(error)"))
            }
        } catch {
            return .failure(.unavailable(reason: String(describing: error)))
        }
    }

    /// Folds an `APIResourceList` into one entry per collection endpoint, attaching
    /// `pods/log`-style entries to the resource they belong to instead of listing
    /// them as kinds of their own.
    private static func discovered(
        in list: APIResourceList,
        groupVersion: GroupVersion,
        isPreferred: Bool
    ) -> [DiscoveredResource] {
        var subresources: [String: Set<String>] = [:]
        for entry in list.resources {
            guard let parent = entry.parentResourceName, let subresource = entry.subresourceName else {
                continue
            }
            subresources[parent, default: []].insert(subresource)
        }

        return list.resources.compactMap { entry in
            guard entry.parentResourceName == nil else { return nil }
            let singular = entry.singularName.flatMap { $0.isEmpty ? nil : $0 } ?? entry.kind.lowercased()
            return DiscoveredResource(
                groupVersionResource: GroupVersionResource(
                    groupVersion: groupVersion,
                    resource: entry.name,
                    isNamespaced: entry.namespaced
                ),
                kind: entry.kind,
                singularName: singular,
                shortNames: entry.shortNames,
                categories: entry.categories,
                verbs: Set(entry.verbs),
                isPreferredVersion: isPreferred,
                subresources: subresources[entry.name] ?? []
            )
        }
    }

    private func decode<Payload: Decodable>(_ type: Payload.Type, atPath path: String) async throws -> Payload {
        let data = try await client.send(APIRequest(method: .get, path: path))
        do {
            return try coder.decoder.decode(Payload.self, from: data)
        } catch {
            throw KubernetesError.decodingFailure(reason: "\(path): \(error)")
        }
    }
}
