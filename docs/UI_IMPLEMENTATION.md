# Native workflow implementation

This records the workspace/connections redesign and the M4/M5 logs, YAML editor,
and resource-action extension as of 19 October 2026. [PRODUCT.md](../PRODUCT.md) pins the native Apple category
standard: system navigation and controls, clear hierarchy, and useful density.
These screens extend that standard; no new visual identity, palette, or token
system was approved. [ARCHITECTURE.md](ARCHITECTURE.md) describes ownership and
[IMPLEMENTATION_CHECKLIST.md](IMPLEMENTATION_CHECKLIST.md) tracks remaining work.

## Presentation conventions

- `RootView` owns the adaptive split workspace and cross-feature presentations.
  The main window starts with clusters, using a native table on wide screens and
  readable rows on compact screens or at accessibility text sizes. File import
  and an inline paste editor are alternatives on that same destination; there is
  no import wizard. Selection shows the target, warnings and auth limitations
  before the explicit Connect action.
- The Clusters sidebar expands connected clusters into resource groups.
  Resource tabs sit above namespace/search controls and the resource table;
  selecting a row opens an inspector on demand. The inspector contains metadata,
  labels, annotations, owners, raw YAML and available tools. Its detail is a
  name-filtered live watch, with freshness and failure messages visible in both
  Overview and YAML. Deletion removes action payloads; reconnection and foreground
  resume use the same list/watch recovery as lists. Editors retain their drafts.
- `WorkspaceTabs` retains namespace and name-search text separately for each
  connection/resource kind. Only the active tab creates a list/watch; inactive
  tabs keep no resource snapshots. Switching tabs clears row/inspector selection.
  Closing the selected tab activates the next tab at that position, or the prior
  tab at the end. Tabs and connected sessions exist only within the window.
- Wide layouts use native tables with kind-specific columns on macOS 14.4 and
  iOS/iPadOS 17.4 or later. The existing macOS 14/iOS 17 floors keep a fixed
  Name/Status/Details/Age table. Compact layouts and accessibility text sizes use
  resource rows. iPad provides one explicit navigator toggle (suppressing the
  generated duplicate), and touch tab actions
  use at least 44-point targets and grow with text size. The namespace control
  lists discovered namespaces and still accepts a typed namespace when listing
  is denied. Its popover opens below the control without raising a touch keyboard
  until the search field is tapped. iOS uses fixed inline titles on every workspace
  state so scrolling a popover cannot move the heading or leave a large title gap.
- Touch context rows expose an ellipsis menu for Connect, Disconnect, Settings
  and Permissions as applicable; connected names activate their workspace while
  the disclosure chevron expands the resource tree. Failed navigator imports
  open connection details so unsupported mobile authentication is visible.
- Logs, editing, and resource actions use `NavigationStack`, system toolbars,
  pickers, toggles, progress indicators, and explicit completion/cancel controls.
  `FullScreenDestination` confines platform-specific presentation to `Platform`.
- UI labels use system text styles. YAML, server results, diffs, and logs use
  monospaced text. `YAMLSourceEditor` wraps the app-only editor dependency and
  scales its font with Dynamic Type; it selects the package's light/dark themes.
- `ClusterScopeBar` keeps cluster, namespace, kind, and object name together on
  write screens. `FreshnessIndicator` pairs words and SF Symbols with color;
  stopped logs explicitly say the output is not live.
- Review diffs use semantic primary text with translucent green/red backgrounds.
  Explicit addition/removal markers and accessibility descriptions carry the
  meaning independently of color. These highlights are local review semantics,
  not a new app palette.
- Log controls switch from a horizontal row to a vertical arrangement when needed.
  Log output scrolls in both directions to preserve long lines.

## Data and write behavior

`ClusterListModel` stages discovered, imported or pasted kubeconfig contexts
without storing credentials or contacting the cluster. Explicit Connect imports
the credential and activates the returned connection; Kubernetes API discovery
starts after activation. Each source remains separate, including duplicate context names;
this does not establish a kubeconfig merge policy. A changed staged document
invalidates its saved-context association so a new Connect cannot reuse the old
destination. Already-open connections retain their original target.

`EditorDraftStore` is per window, keyed by connection and write target, and holds
YAML only in memory. Drafts survive failures and dismissals when kept, and pending
drafts guard context changes. Closing the process does not preserve them. Logs
also remain in bounded memory; the UI reports discarded earlier lines. Resource
content, Secret values, YAML, diffs, and logs are intentionally visible unmasked
when access is allowed. Credential protection is a separate boundary.

The editor enables Apply only after a successful server dry-run and review. A
source edit invalidates that review. `ResourceWriter` rechecks the proposal before
commit; changed results or ownership conflicts require another review. Successful
apply rebases the editor's draft comparison and diff baseline on that write.
Delete, restart, and scale use a separate dry-run and explicit confirmation with
the destination visible. Unsupported dry-run currently blocks the write.

## Synthetic launch fixtures

Debug builds accept one of these launch arguments in the Tsubame scheme's Run
configuration:

| Argument | Screen |
| --- | --- |
| `--preview-connections` | Three staged contexts before connecting |
| `--preview-workspace` | Connected context, resource tree and synthetic Pods table |
| `--preview-editor` | Deployment YAML source and review workflow |
| `--preview-logs` | Pod logs with two selectable containers |
| `--preview-actions` | Deployment scale confirmation |

Build and run the Debug scheme for the selected Mac or simulator, with exactly
one argument enabled. Remove it to return to the workspace. Release builds omit
the fixtures. `WorkflowPreview` and `WorkspacePreview` use synthetic transports
and in-memory storage; displayed live streams are simulated and no cluster is
contacted. Workspace fixtures visibly identify themselves as previews. These
fixtures exercise presentation, not Kubernetes integration.

For an explicit simulator integration check, Debug simulator builds also accept
`--import-kubeconfig /absolute/path/to/config`. This stages the original host file
without copying it into a fixture or putting credential bytes in launch arguments.
It opens Manage Clusters and still requires an explicit Connect action. It uses
the real iOS authentication and Keychain paths, can contact the chosen cluster
after Connect, and is unavailable in release or physical-device builds.

## Verification limits and remaining scope

### Workspace titles, pane contrast and live details — 20 October 2026

- Renamed the sidebar to Clusters, removed its Contexts subheading, and changed
  connection-management wording to clusters. Pane tabs use semantic text colors
  on a translucent accent fill, including selected names and close icons.
- All rows of an open list use its existing collection watch. Open inspectors now
  watch the selected object, including raw YAML, without changing editor drafts.
  Five new regressions cover modifications, deletion/recreation, permission denial,
  pause/resume, cancellation cleanup and updates to every object in a list.
- macOS passed 40 app tests; iPad Simulator passed 37. Interactive iPad simulator
  checks exercised a 44-namespace popover in portrait and landscape, confirming
  that dragging through the list leaves the heading fixed. Landscape editor/log
  tabs remained readable with both tools open; the Clusters heading and footer
  were inspected. After unlocking the Mac, rotation to portrait with both tools
  open preserved the tab labels and close icons. The portrait dark-mode capture
  confirmed readable selected Logs text/icons beside the inactive YAML tab;
  restored the simulator's original light appearance afterward. These are
  simulator checks, not physical-device gesture or accessibility acceptance.

### Startup splash — 20 October 2026

- Added a centered Tsubame wordmark as a text placeholder for the future logo.
  Semantic system colors adapt to light/dark appearance; the SwiftUI placeholder
  supports Dynamic Type. No animation or minimum display delay is added.
- The native iPhone/iPad launch storyboard matches the default SwiftUI wordmark.
  Local startup prepares and retains the cluster model before opening the
  workspace. Cluster API discovery keeps its existing loading/error UI.
- macOS and iOS Simulator builds passed. Inspected the actual native iPad launch
  screen, the iPhone dark preview at an enlarged text size, and the macOS preview.
  Normal iPad launch reached the workspace after the splash. Debug builds accept
  `--preview-splash` for a static view of the placeholder.

### iPad navigation and discovery fixes — 20 October 2026

- Removed the duplicate system navigator control on regular-width iOS while
  retaining the explicit toggle in portrait. The inspector control appears only
  when an object is selected. Added normal-tap context action menus and connected
  context activation; settings navigation was exercised in the iPad simulator.
- The discovery deadline now cancels the shared request before its task group
  exits. Regression tests cover timeout, retry and cancellation on navigation.
  All 28 app tests and 154 package tests passed. macOS tests, iOS Simulator build
  and the signed physical-iPad build passed after the final toolbar change.
- Inspected iPad portrait and iPhone dark/accessibility-large synthetic screens.
  Evidence is temporary under `/tmp/tsubame-ipad-fix-review`. Installed and
  launched the final build on attached `iPad (2)`; real-cluster connectivity and
  physical-device interactions still require reconnecting an imported context.

### Mobile client certificates and cancelled discovery — 20 October 2026

- Mobile client-certificate support is now part of the confirmed scope. Imported
  RSA PKCS#1/PKCS#8 and EC SEC1/PKCS#8 identities (P-256/P-384/P-521) are validated
  and held in the device Keychain. Certificate chains and shared-context
  references stay protected there too. Exec plugins remain unavailable on mobile.
- An unsolicited URLSession cancellation no longer disappears as if the user
  navigated away. Initial discovery resumes when the scene becomes active again.
- Generated-key tests exercise actual identity import, retrieval, signing,
  duplicate/shared references, removal, mismatched replacement and a loopback
  server requiring a verified client certificate. The mutual-TLS test passed on
  macOS, iPad Simulator and the attached physical `iPad (2)`.
- The macOS app suite passed 35 tests; the iPad Simulator suite passed 32 tests
  (macOS-only locator tests are excluded). KubeKit passed 156 tests. The focused
  physical-iPad run passed nine tests covering identities and discovery.
- Real-cluster simulator verification succeeded with `kurasuta`: client-certificate
  authentication, API discovery, namespace enumeration, the Pods list and its Live
  state were exercised. The navigator showed one toggle and the explicit context
  menu opened and connected normally.
- The affected DigitalOcean context reaches its TLS endpoint but Apple rejects
  its server certificate's 7,305-day validity period (2026–2046). A native
  `SecTrust` probe reports `OtherTrustValidityPeriod`; Apple requires at most
  825 days for certificates issued after July 2019. This needs a server certificate
  reissue; client-certificate support does not change server trust validation.
  `cgk-biznet-k8s01` separately timed out at TCP connection establishment.

The redesign was checked against source and temporary synthetic captures in
`/tmp/tsubame-redesign-review`: `mac-workspace`, `mac-tabs`, `mac-inspector`,
`mac-connections`, `phone-workspace`, `tablet-workspace`,
`phone-connections-accessibility` and `phone-workspace-accessibility` (all PNGs).
Mac UI interactions were exercised. At that earlier redesign review, mobile
evidence was limited to captures and source inspection. The later simulator
integration checks above provide narrower interactive mobile verification. Earlier
M4/M5 editor/log captures remain a separate, narrower review record.

Eighteen macOS app tests passed before the final presentation-only review fixes;
macOS and iOS Simulator builds passed after those fixes. The earlier KubeKit
continuation passed 127 KubeKit tests and 38 KubeModels tests. These outcomes do
not establish whole-app UI acceptance. No HTML detector applies to this native
SwiftUI interface. Full VoiceOver, keyboard, contrast, Reduce Motion/Transparency,
device-hardware and performance checks remain unverified; real-cluster coverage
is limited to the simulator checks recorded above.

M4/M5 are not a complete MVP. M6 RBAC help and CRD schema views, M7 persistence
and the published support matrix, interactive OIDC/exec approval UI wiring,
connection testing, namespace discovery/selection, and large-list performance
work remain outstanding. Open product decisions retain the status in the PRD.
