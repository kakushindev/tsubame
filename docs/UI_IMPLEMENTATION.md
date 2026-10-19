# Native workflow implementation

This records the workspace/connections redesign and the M4/M5 logs, YAML editor,
and resource-action extension as of 19 October 2026. [PRODUCT.md](../PRODUCT.md) pins the native Apple category
standard: system navigation and controls, clear hierarchy, and useful density.
These screens extend that standard; no new visual identity, palette, or token
system was approved. [ARCHITECTURE.md](ARCHITECTURE.md) describes ownership and
[IMPLEMENTATION_CHECKLIST.md](IMPLEMENTATION_CHECKLIST.md) tracks remaining work.

## Presentation conventions

- `RootView` owns the adaptive split workspace and cross-feature presentations.
  The main window starts with contexts, using a native table on wide screens and
  readable rows on compact screens or at accessibility text sizes. File import
  and an inline paste editor are alternatives on that same destination; there is
  no import wizard. Selection shows the target, warnings and auth limitations
  before the explicit Connect action.
- The persistent navigator expands connected contexts into resource groups.
  Resource tabs sit above namespace/search controls and the resource table;
  selecting a row opens an inspector on demand. The inspector contains metadata,
  labels, annotations, owners, raw YAML and available tools. Its detail is a
  timestamped snapshot with explicit refresh, not a live watch.
- `WorkspaceTabs` retains namespace and name-search text separately for each
  connection/resource kind. Only the active tab creates a list/watch; inactive
  tabs keep no resource snapshots. Switching tabs clears row/inspector selection.
  Closing the selected tab activates the next tab at that position, or the prior
  tab at the end. Tabs and connected sessions exist only within the window.
- Wide layouts use native tables with kind-specific columns on macOS 14.4 and
  iOS/iPadOS 17.4 or later. The existing macOS 14/iOS 17 floors keep a fixed
  Name/Status/Details/Age table. Compact layouts and accessibility text sizes use
  resource rows. iPad provides an explicit navigator toggle, and touch tab actions
  use at least 44-point targets and grow with text size. The namespace control
  still accepts a typed namespace; it does not discover namespaces.
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

## Verification limits and remaining scope

The redesign was checked against source and temporary synthetic captures in
`/tmp/tsubame-redesign-review`: `mac-workspace`, `mac-tabs`, `mac-inspector`,
`mac-connections`, `phone-workspace`, `tablet-workspace`,
`phone-connections-accessibility` and `phone-workspace-accessibility` (all PNGs).
Mac UI interactions were exercised. Mobile evidence is limited to captures and
source inspection; interactive mobile GUI verification was unavailable. Earlier
M4/M5 editor/log captures remain a separate, narrower review record.

Eighteen macOS app tests passed before the final presentation-only review fixes;
macOS and iOS Simulator builds passed after those fixes. The earlier KubeKit
continuation passed 127 KubeKit tests and 38 KubeModels tests. These outcomes do
not establish whole-app UI acceptance. No HTML detector applies to this native
SwiftUI interface. Full VoiceOver, keyboard, contrast, Reduce Motion/Transparency,
device-hardware, performance and real-cluster checks remain unverified.

M4/M5 are not a complete MVP. M6 RBAC help and CRD schema views, M7 persistence
and the published support matrix, interactive OIDC/exec approval UI wiring,
connection testing, namespace discovery/selection, and large-list performance
work remain outstanding. Open product decisions retain the status in the PRD.
