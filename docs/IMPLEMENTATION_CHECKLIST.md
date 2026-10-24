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
- [x] Release workflow: SemVer tag check, CI against the tag, universal macOS DMG attached to the GitHub release ([RELEASING.md](RELEASING.md))
- [ ] Developer ID signing and notarization secrets configured (workflow supports them; until then DMGs are ad-hoc signed)
- [ ] Homebrew tap `kakushindev/homebrew-tap` created and wired up (job and cask template exist, off until configured)
- [ ] iOS/iPadOS distribution — waits on the distribution channel decision (PRD §15)
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
- [x] `CustomResourceDefinition` model and the OpenAPI schema subset CRD views
      need, with `PrinterColumn` evaluating the dotted-field and numeric-index
      JSONPath subset only — anything else renders empty rather than wrong

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
- [x] Client-certificate provider: PEM import to a `SecIdentity` on macOS, iOS and iPadOS.
      `SecItemImport` reads RSA PKCS#1, RSA PKCS#8 and EC SEC1; an EC key in
      PKCS#8 is rebuilt as SEC1 first (`PrivateKeyPEM`). The key must be stored
      with `kSecAttrApplicationLabel` set to its public-key hash or no identity
      can ever be formed, however well both items store.
- [x] Mobile RSA PKCS#1/PKCS#8 and EC SEC1/PKCS#8 import (P-256/P-384/P-521),
      certificate/key matching, device-only Keychain storage, certificate chains,
      shared-context references and failed replacement preserving an existing identity
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
- [x] Pod log streaming: container selection, `previous`, `sinceTime`, `tailLines`,
      bounded in-memory buffer
- [x] Write operations in their own type, separate from the read client:
  - [x] Server-Side Apply with the `tsubame` field manager, dry-run first
  - [x] Delete with dry-run where supported
  - [x] Restart via the workload pod-template annotation
  - [x] Scale via the `scale` subresource
- [x] `SelfSubjectAccessReview` checks for the RBAC preflight screen, as a
      three-state `AccessDecision`: `allowed` beside an `evaluationError` is
      `undetermined`, because a webhook that errored may have failed open
- [ ] Multi-document YAML handling — open decision (PRD §15)

## 3. App — features

### Shell

- [x] `AppEnvironment` composition root with live and in-memory variants
- [x] `RootView` adaptive split view
- [x] Supplied block-T branding: platform-specific iOS/Mac app icons, adaptive
      vector mark, repository logo, documented masters and asset regeneration
- [x] Adaptive Tsubame block-T mark during local startup, with a matching
      native iPhone/iPad launch screen; no artificial minimum display time
- [x] Window-local context/resource navigator and resource tabs with independent
      namespace/search state; only the active tab owns a watcher
- [x] `NavigationModel` with explicit cluster and namespace selection
- [x] `FreshnessIndicator`
- [ ] macOS menu commands and keyboard shortcuts (PRD §10)
- [ ] Persisted cluster list (connections only; credentials stay in the Keychain)
- [x] Scene lifecycle: cancel watches on background, relist and reconnect on resume
- [x] Discovery deadline cancels the underlying shared request, reports a failure,
      and permits retry; context-switch cancellation does not report a false failure
- [x] Unsolicited request cancellation is a visible failure; foreground resume
      restarts initial discovery interrupted by backgrounding
- [x] Single iPad navigator toggle, tappable connected context names and explicit
      touch action menus; failed navigator imports open their connection details

### Clusters

- [x] `KubeconfigDiscovery` protocol with macOS and iOS implementations
- [x] `ClusterListModel` import and context-selection state
- [x] In-window connections destination with discovered contexts and separate
      file/paste sources, plus a persistent context/resource navigator
- [x] File import and paste import flows
- [x] Context selection stages an import plan without storing credentials;
      explicit Connect imports and activates an in-memory connection
- [x] Changed staged sources invalidate the prior imported-context association;
      separate sources do not silently merge duplicate context names
- [ ] Connection test that sends no write request and changes no active context
- [ ] Namespace picker, including "all namespaces" where permitted
- [ ] Guided manual setup for iOS and iPadOS
- [ ] Removing a cluster and its stored credential
- [ ] Exec-plugin approval screen: show the command, require explicit approval

### Browse

- [x] Resource list driven by `ResourceWatcher`, with freshness always visible
- [x] Adaptive native resource table with kind columns (14.4/17.4+), fixed table
      fallback at existing OS floors, compact/accessibility rows and on-demand
      timestamped inspector
- [ ] Namespace filter and name search that stay usable at 10,000 objects (PRD §18)
- [ ] Explicit empty, loading, permission-denied, partial, and error states
- [ ] Resource detail: metadata, status, labels, annotations, owner references
- [x] Raw YAML view preserving the API representation
- [x] Open inspector follows name-filtered list/watch updates, deletion and
      recreation, displays freshness/denials, and relists on foreground resume
- [x] Secret detail decoding text values and leaving binary values as base64
- [x] CRD discovery, schema-driven columns where a usable schema exists,
      generic fallback

### Edit and act

- [x] YAML editor with syntax validation and a draft that survives every failure
- [x] Dry-run, server result, and diff before any live apply
- [x] Apply as a separate explicit action reusing the dry-run manifest
- [x] Field-ownership conflict returns the user to review; never force silently
- [x] Delete, restart, and scale confirmations showing cluster, namespace, kind, name
- [x] Actions disabled or failing explicitly under insufficient RBAC

### Logs

- [x] Pod and container picker
- [x] Live stream with start and stop, bounded buffer, long-line handling
- [x] Previous-container logs, timestamps, bounded starting window
- [x] Interrupted-versus-current indication, and no log content in diagnostics

### RBAC help

- [x] Preflight screen naming the permissions each workflow needs
- [x] Copyable least-privilege Role example, generated from the same
      attributes the screen checks so policy and checks cannot drift
- [x] Says so plainly when a capability check is unavailable or inconclusive

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

## M4 / M5 continuation — 19 October 2026

- `PodLogSession` resumes with the original timestamp, suppresses replayed
  occurrences, keeps monotonic row IDs, and bounds both lines and UTF-8 bytes.
  Snapshots are coalesced to ten per second and buffered one deep. The transport
  also bounds its line queue and reports overflow, closes the socket on
  cancellation, and retains UTF-8 across forced line breaks.
- `ResourceWriter` makes rehearsal construction private and binds it to its
  originating writer/cluster. It re-rehearses before commit and requires another
  review when the meaningful proposal or warnings changed. Requests never set
  `force`. Apply sends the validated source bytes directly, retaining numeric
  spelling such as `1.0`. Delete binds UID and resource-version preconditions;
  scale binds a resource version. Unsupported dry-run currently blocks a write
  rather than offering an unchecked fallback.
- The editor uses a pinned app-only CodeEditorView dependency behind one wrapper,
  with YAML highlighting and Dynamic Type. Drafts are scoped to cluster and
  target and kept only in memory. Kept drafts block context changes until the
  user applies or explicitly discards them.
- Import, discovery, resource selection and fetched detail now connect the tools
  end to end. The browse list is a functional starting point, **not** the
  10,000-object performance implementation in the plan. Namespace entry is manual;
  all-namespaces selection, namespace discovery, list projection, first-page
  publication, live detail, complete metadata panes and menu commands remain.
- Exec and interactive OIDC providers are still not connected to the app's
  presentation layer. The import screen explicitly says when setup/approval is
  needed and does not execute plugins. Cluster persistence, credential removal,
  connection testing, guided mobile setup and the support matrix remain open.
- M6 (RBAC help and CRD schemas) and M7 (persistence and support matrix) remain.
  Multi-document YAML, kubeconfig merging, issuer guarantees, OS/Kubernetes
  floors, distribution and license decisions have not been settled.

### Verification for this continuation

- `swift test --package-path KubeKit`: 127 tests passed in the KubeKit suite;
  the KubeModels suite also passed (38 tests).
- macOS app tests: 13 tests passed, including post-apply draft rebasing and
  foreground log resume across inactive/background transitions.
- iOS Simulator build: passed at the existing iOS 17 deployment target; macOS
  remains at 14. The shared plist now merges the generated launch/scene keys,
  avoiding the legacy letterboxed iOS frame found during simulator inspection.
- iPhone accessibility/Dark Mode editor and iPad log captures inspected with
  synthetic data. Focused review scored the draft-baseline and diff-contrast
  source fixes resolved. Mac tool captures, a full accessibility/keyboard matrix,
  hardware soak, and real-cluster write/log validation remain unverified.

See [UI_IMPLEMENTATION.md](UI_IMPLEMENTATION.md) for preview instructions and
presentation conventions. Dependency notices ship in `ThirdPartyNotices.txt`;
this does not settle the app's open license decision.

## Workspace/connections redesign — 19 October 2026

- Replaced the import-form entry and three-column shell with contexts first,
  a persistent resource tree, tabs, namespace/search above the resource table,
  and an inspector that opens on selection. The selected Lens composition is
  recorded in [WORKSPACE_DESIGN.md](WORKSPACE_DESIGN.md); spaces, metrics and
  Helm are outside this change.
- Namespace entry and name search are available per tab. Namespace discovery,
  all-namespaces selection and the 10,000-object performance requirement remain
  open. Metadata, labels, annotations and owners are visible in the inspector;
  full resource-detail/status coverage and the complete error-state matrix are
  still unchecked above.
- Debug fixtures now include `--preview-connections` and `--preview-workspace`.
  Eighteen macOS app tests passed before final presentation-only fixes, and both
  macOS and iOS Simulator builds passed afterward. The previous 127 KubeKit and
  38 KubeModels passing results belong to the M4/M5 continuation.
- Synthetic Mac workspace/tab/inspector/connections and phone/tablet captures,
  including two phone accessibility-size views, support focused layout review.
  Mac interactions were exercised; mobile evidence is captures/source only.
  This does not complete VoiceOver, full keyboard/accessibility, real-cluster,
  performance, or hardware verification. See UI_IMPLEMENTATION.md for the
  temporary evidence paths and precise limits.
- M6/M7 and all PRD-owned open decisions retain their existing status.
