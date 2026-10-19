# Implementation checklist

Modules and features, in the order PRD §8 sequences them. Checked items exist in the
repository and are covered by tests; everything else is outstanding.

Rules that apply throughout: each item lands in the layer named in
[ARCHITECTURE.md](ARCHITECTURE.md), behind a protocol where it crosses a boundary,
with no shared `Utils` or `Helpers` type introduced to hold it.

## 0. Foundation — project and toolchain

- [x] `project.yml` as the XcodeGen source of truth; `.xcodeproj` generated and ignored
- [x] Multiplatform app target (iOS 17+, macOS 14+ provisional) with ad-hoc signing
- [x] `KubeKit` local package with four targets and enforced dependency direction
- [x] Swift 6 language mode and complete strict concurrency in both the package and the app
- [x] Unit test targets for the package and the app, running under Swift Testing
- [x] Continuous integration: `xcodegen generate`, build for both platforms, run both test suites
- [ ] SwiftLint or swift-format configuration, if the project wants one
- [ ] `LICENSE` — open decision (PRD §15)

## 1. KubeModels — data types

- [x] `JSONValue` generic representation with round-trip fidelity
- [x] `GroupVersion`, `GroupVersionKind`, `GroupVersionResource` with REST path building
- [x] `ObjectMeta`, `OwnerReference`
- [x] `ResourceObject` protocol and `GenericResource`
- [x] `ResourceList` paging envelope and `WatchEvent`
- [x] Kubeconfig document model, including `exec` and `auth-provider` entries
- [x] `ClusterConnection`, `AuthenticationMethod`, `CredentialReference`, `TLSConfiguration`
- [x] `DataFreshness` — live, reconnecting, stale, disconnected, polling
- [x] Typed models for the MVP kinds: Pod, Deployment, Service, Namespace, Event,
      ConfigMap, Secret, StatefulSet, DaemonSet, Job, CronJob (`TypedResource`;
      each decodes `raw` first and encodes it back, so a round trip never narrows
      a manifest)
- [x] Per-kind status summaries for list rows (PRD §9.2) — `ResourceRowSummary`,
      owned by each kind; `tone` is never a colour alone
- [x] API discovery payloads (`APIVersions`, `APIGroupList`, `APIResourceList`) and
      the resolved `APIResourceCatalog`
- [ ] `CustomResourceDefinition` model and the OpenAPI schema subset CRD views need

## 2. KubeKit — client layer

### Transport and errors

- [x] `KubernetesTransport` protocol with a request and a line-stream entry point
- [x] `URLSessionTransport` with per-cluster configuration and no response caching
- [x] `ServerTrustEvaluator`: kubeconfig CA as an additional anchor, system trust kept
- [x] `KubernetesError` and `KubernetesErrorMapper`, including 410 and `Retry-After`
- [x] `CredentialRedactor` for errors, logs, and diagnostics
- [x] `RetryPolicy` with bounded exponential backoff and jitter
- [x] Proxy support for a kubeconfig `proxy-url` (unsupported proxies refuse the
      connection rather than silently connecting directly)
- [x] Request timeouts and cancellation audited against context switching (PRD §12):
      a separate streaming session so a quiet watch is not killed by the 60s
      inter-packet default, a bounded `\n`-only `LineChunker` replacing
      `AsyncLineSequence`, and cancellation always surfacing as `CancellationError`

### Authentication

- [x] `CredentialProvider` protocol and `UnsupportedCredentialProvider`
- [x] `BearerTokenCredentialProvider` with invalidation on rejection
- [x] `TokenFileCredentialProvider` re-reading a rotating service-account token
      (macOS; iOS copies the value once and warns that it will expire)
- [x] `CredentialStore` protocol and `EphemeralCredentialStore`
- [x] `KeychainCredentialStore` (device-only, available after first unlock)
- [x] Client-certificate provider: PEM import to a `SecIdentity` (macOS).
      `SecItemImport` reads RSA PKCS#1, RSA PKCS#8 and EC SEC1; an EC key in
      PKCS#8 is rebuilt as SEC1 first (`PrivateKeyPEM`). The key must be stored
      with `kSecAttrApplicationLabel` set to its public-key hash or no identity
      can ever be formed, however well both items store.
- [x] OIDC provider: authorization code + PKCE, single-flight refresh, expiry a
      minute early. The header carries the **ID token**, not the access token
- [x] Exec credential plugin runner in its own `KubeExec` target (macOS only),
      approval required before execution and bound to the command fingerprint
- [ ] Per-platform support matrix published in the app and the README (PRD §9.1)

### Kubeconfig

- [x] `KubeconfigParsing` protocol and the Yams-backed parser
- [x] Context summaries for the picker, defaulting the namespace to `default`
- [x] Importing a context into a `ClusterConnection` plus a stored credential
      (`KubeconfigImporter`: `plan` reads and stores nothing, `import` writes once)
- [x] Resolving file references (`certificate-authority`, `client-key`, `tokenFile`)
- [ ] `KUBECONFIG` multi-path merge — open decision (PRD §15)

### Resource operations

- [x] `KubernetesClient` get, paged list, and watch, with `Retry-After` honored
- [x] `ListOptions` with limit, continue, selectors, and watch bookmarks
- [x] API discovery: served groups, versions, resources, and namespacing
- [x] `ResourceWatcher`: list then watch, relist on 410, bounded reconnect, bounded
      event buffer, and a `DataFreshness` output
- [x] Erasure layer so one browse path serves typed and generic kinds:
      `AnyResourceObject`, `ResourceWatching`, `ErasedResourceSnapshot`,
      `ErasedResourceWatcher`, and `ResourceKindRegistry` as the only place that
      decides typed versus generic versus polling
- [x] Tolerant list decoding: one undecodable item costs that item, and the page
      reports `undecodableItemCount` rather than silently showing fewer rows
- [x] Rate-limited polling fallback for resources that cannot be watched
      (`PollingResourceWatcher` + per-connection `PollingBudget`, published as
      `DataFreshness.polling` so it is never shown as a live watch)
- [ ] Pod log streaming: container selection, `previous`, `sinceTime`, `tailLines`,
      bounded in-memory buffer
- [ ] Write operations in their own type, separate from the read client:
  - [ ] Server-Side Apply with the `tsubame` field manager, dry-run first
  - [ ] Delete with dry-run where supported
  - [ ] Restart via the workload pod-template annotation
  - [ ] Scale via the `scale` subresource
- [ ] `SelfSubjectAccessReview` checks for the RBAC preflight screen
- [ ] Multi-document YAML handling — open decision (PRD §15)

## 3. App — features

### Shell

- [x] `AppEnvironment` composition root with live and in-memory variants
- [x] `RootView` adaptive split view
- [x] `NavigationModel` with explicit cluster and namespace selection
- [x] `FreshnessIndicator`
- [ ] macOS menu commands and keyboard shortcuts (PRD §10)
- [ ] Persisted cluster list (connections only; credentials stay in the Keychain)
- [ ] Scene lifecycle: cancel watches on background, relist and reconnect on resume

### Clusters

- [x] `KubeconfigDiscovery` protocol with macOS and iOS implementations
- [x] `ClusterListModel` import and context-selection state
- [x] `ClusterListView` sidebar with discovered configurations
- [ ] File import and paste import flows
- [ ] Context picker that writes the credential and saves the connection
- [ ] Connection test that sends no write request and changes no active context
- [ ] Namespace picker, including "all namespaces" where permitted
- [ ] Guided manual setup for iOS and iPadOS
- [ ] Removing a cluster and its stored credential
- [ ] Exec-plugin approval screen: show the command, require explicit approval

### Browse

- [ ] Resource list driven by `ResourceWatcher`, with freshness always visible
- [ ] Namespace filter and name search that stay usable at 10,000 objects (PRD §18)
- [ ] Explicit empty, loading, permission-denied, partial, and error states
- [ ] Resource detail: metadata, status, labels, annotations, owner references
- [ ] Raw YAML view preserving the API representation
- [ ] Secret detail decoding text values and leaving binary values as base64
- [ ] CRD discovery, schema-driven columns where a usable schema exists, generic fallback

### Edit and act

- [ ] YAML editor with syntax validation and a draft that survives every failure
- [ ] Dry-run, server result, and diff before any live apply
- [ ] Apply as a separate explicit action reusing the dry-run manifest
- [ ] Field-ownership conflict returns the user to review; never force silently
- [ ] Delete, restart, and scale confirmations showing cluster, namespace, kind, name
- [ ] Actions disabled or failing explicitly under insufficient RBAC

### Logs

- [ ] Pod and container picker
- [ ] Live stream with start and stop, bounded buffer, long-line handling
- [ ] Previous-container logs, timestamps, bounded starting window
- [ ] Interrupted-versus-current indication, and no log content in diagnostics

### RBAC help

- [ ] Preflight screen naming the permissions each workflow needs
- [ ] Copyable least-privilege Role and ClusterRole examples
- [ ] Says so plainly when a capability check is unavailable or inconclusive

## 4. Later (PRD §8)

- [ ] Container exec, macOS first
- [ ] Resource metrics, with the data source named
- [ ] Port-forwarding on macOS
- [ ] Follow-on resource coverage from the PRD §16 inventory

## 5. Cross-cutting verification

- [x] Watch reliability: drop, resume, 410 (both the in-stream event and the HTTP
      failure), duplicate and out-of-order events, rapid navigation, paging
- [ ] No task or memory growth across context switches and backgrounding
- [ ] No credential value in any log, error, or diagnostic (extend the redactor tests)
- [ ] Secret values and logs absent from every persistent cache
- [ ] VoiceOver labels, Dynamic Type, Reduce Motion, Reduce Transparency, contrast
- [ ] Keyboard navigation on macOS and iPadOS
- [ ] Benchmarks against the Freelens workflow defined in PRD §18

## Decisions this scaffold has already taken

These were needed to produce a project that builds. Each is reversible; raise them if
the intended answer differs.

1. **Yams is a dependency** of KubeKit, for kubeconfig and YAML editing. PRD §11
   rules out a third-party Kubernetes client, not a YAML parser; writing one is
   weeks of work for no product value.
2. **The macOS App Sandbox is off.** A sandboxed app cannot read `~/.kube/config`
   without the user selecting it, which contradicts the automatic discovery PRD §9.1
   requires. Turning the sandbox on means security-scoped bookmarks after a one-time
   file selection, and it is tied to the undecided distribution channel (PRD §15).
3. **Ad-hoc signing by default**, so the repository builds with no Apple developer
   team. Device builds and distribution need a real `DEVELOPMENT_TEAM`.
4. **KubeKit is four targets, not one.** PRD §11 asks for one package; splitting it
   internally is what makes "models never reach the network" and "the package never
   imports SwiftUI" compiler-enforced rather than conventional.
5. **Deployment targets are iOS 17.0 and macOS 14.0**, the provisional values from
   PRD §10. Still to be confirmed against a real compatibility review (PRD §15).

## Open decisions still owned by the PRD (§15)

OIDC issuers and flows · exec-plugin approval and refresh UX · final minimum OS
versions · Kubernetes version floor · `KUBECONFIG` merge behavior · multi-document
YAML · distribution channel · license.
