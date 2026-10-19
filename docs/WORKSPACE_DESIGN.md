# Workspace and connections

Confirmed with the user on 19 October 2026 after rejecting the three-empty-column
composition and import wizard.

- **Job:** connect to an existing Kubernetes context and inspect resources quickly.
  This is an operating interface for developers, on Mac first, with adaptive iPad
  and iPhone layouts.
- **Composition:** contexts appear directly in the main window before connecting.
  The user's subsequent Lens screenshot pins the workspace composition: a
  persistent context tree on the left, expandable resource groups beneath each
  connected context, resource tabs across the content area, and namespace/search
  controls directly above a wide table. Details appear on demand in an inspector.
  The earlier compact cluster-switcher proposal is superseded.
- **Connection flow:** show contexts discovered in local kubeconfig immediately.
  File and paste import are alternatives on the same surface. Selecting a context
  exposes identity, authentication limitations and actual warnings in place; one
  explicit Connect action imports its credential and activates that context.
  Discovery and selection alone never store credentials or contact the cluster.
- **Native direction:** preserve the Apple category standard in PRODUCT.md:
  system type, table, sidebar, toolbar, inspector, menus, semantic surfaces, no
  invented visual identity. The important moment is choosing a real context and
  reaching a useful resource table without intermediate screens.
- **Constraints:** retain draft guards, explicit permission failures, honest
  freshness, foreground cancellation and dry-run/confirm boundaries. Do not settle
  the PRD's open auth/version/distribution decisions or expand into M6/M7.

- **Tabs:** one open view per connection and discovered resource kind. Each keeps
  its own namespace and search text. Only the selected tab instantiates a watcher;
  inactive tabs retain navigation choices, never resource snapshots. Closing the
  selected tab activates its neighbor. Tabs and connected sessions are window-local.
- **Adaptation:** Mac keeps a native sidebar and table. Compact screens use the
  navigator as a separate column and show readable resource rows. The reference's
  spaces rail, metrics, Helm and other unimplemented products are outside scope.

Implementation evidence and fixture instructions are recorded in
[UI_IMPLEMENTATION.md](UI_IMPLEMENTATION.md). This is a surface composition
contract within the existing native Apple standard, not a new design system.
Contexts from separate files or pasted text remain separate sources. A changed
staged source requires a new explicit import on Connect; already-open sessions
keep their original target. Resource tabs clear row/inspector selection when
activated, and switching connections still honors pending YAML drafts.

Wide native tables use kind-specific columns on macOS 14.4/iOS 17.4 and later;
the existing 14/17 deployment floors retain a fixed Details-column fallback.
Accessibility text sizes use readable rows. iPad exposes a navigator toggle;
touch tab actions have 44-point minimum targets and adapt to larger text.
