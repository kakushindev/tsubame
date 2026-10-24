# AGENTS.md

This file provides guidance to AI Agents when working with code in this repository.

## Project state

Tsubame is a native Kubernetes management app for macOS, iPadOS, and iOS (bundle ID `dev.kakushin.tsubame`, published by Kakushin.dev as free, open-source software). `PRD.md` is the source of truth for scope, behavior, and constraints. Read the relevant PRD section before implementing a feature.

The project is scaffolded: the app target and the KubeKit package build for both platforms and their tests pass. `docs/ARCHITECTURE.md` records the structure and the rules that keep it; `docs/IMPLEMENTATION_CHECKLIST.md` tracks what exists and what is outstanding, and lists the decisions the scaffold already took. Read both before adding a feature, and tick the checklist as items land.

The dot-directories (`.claude/`, `.agent/`, `.agents/`, `.gemini/`, `.hermes/`, `.opencode/`, `.codex/`, `.impeccable/`) hold vendored copies of the "impeccable" UI design skill and agent tooling config. They are not app code; don't edit them as part of feature work.

## Commands

```bash
xcodegen generate                                  # regenerate Tsubame.xcodeproj from project.yml
swift build  --package-path KubeKit                # build the package alone
swift test   --package-path KubeKit                # run the package tests
xcodebuild -project Tsubame.xcodeproj -scheme Tsubame -destination 'platform=macOS' build
xcodebuild -project Tsubame.xcodeproj -scheme Tsubame -destination 'platform=macOS' test
xcodebuild -project Tsubame.xcodeproj -scheme Tsubame -destination 'generic/platform=iOS Simulator' build
scripts/release/build-dmg.sh v1.2.3                # universal macOS DMG into build/release/
```

Releases are SemVer tags (`v1.2.3`, `v1.2.3-rc.1`); publishing a GitHub release runs
`.github/workflows/release.yml`. See `docs/RELEASING.md`.

Run `xcodegen generate` after adding or removing a source file; the `.xcodeproj` is a
build artifact and is git-ignored. Edit `project.yml`, never the generated project.
Signing is ad-hoc by default, so these commands need no Apple developer team.

## Planned architecture (from PRD §11)

- **Xcode project is generated** from `project.yml` with XcodeGen (`xcodegen generate`). Treat `project.yml` as the source of truth; the `.xcodeproj` is a build artifact and project settings must be reproducible from the command line.
- **App target**: thin SwiftUI presentation and platform-integration layer, one shared codebase for macOS, iPadOS, and iOS with device-adapted screens.
- **KubeKit** (local Swift package): kubeconfig parsing, cluster/context models, credential-handling interfaces, `URLSession`-based REST client, API discovery, resource operations, watch streams, and error mapping. It must not depend on SwiftUI, so it stays testable and reusable on its own.
- There is no third-party Swift Kubernetes client; Tsubame owns the whole client layer.
- Use typed models for core resources and a generic representation for unknown/custom resources. CRD views are schema-driven when the CRD publishes a usable OpenAPI schema, with a generic list/detail/YAML fallback.
- Keep UI state management separate from the HTTP/watch implementation.
- Provisional deployment targets are iOS/iPadOS 17+ and macOS 14+. Liquid Glass comes from standard SwiftUI controls on OS 26; wrap any custom glass APIs in availability checks. Liquid Glass must not raise the minimum OS.

## Non-obvious requirements that constrain implementation

**Kubernetes client behavior**
- Use list/watch with `resourceVersion`. On `410 Gone`, relist. Honor `Retry-After` on `429`. Use bounded backoff for network failures and paginate large lists.
- Watch only active or needed resource kinds. Cancel network work on context switches. Bound watch-event and log buffers. Duplicate events, backgrounding, and rapid navigation must not leak tasks or memory.
- Polling is allowed only as a documented, rate-limited fallback when watch is unavailable.
- The UI must distinguish live, reconnecting, stale, and disconnected data. Never present cached or stale data as live.

**Writes are always deliberate**
- YAML apply flow: validate syntax, identify the target, run a **server-side dry-run**, show the server result and a diff, then apply only after a separate explicit user action. The live apply must use the same manifest and operation as the dry-run.
- Use Server-Side Apply with a stable Tsubame field manager. Never force field-ownership conflicts silently. A conflict sends the user back to review.
- Delete, restart (workload template change for Deployments/StatefulSets/DaemonSets), and scale (scale subresource) require a confirmation that shows the cluster, namespace, kind, and name, with dry-run first where the API supports it.
- Preserve the user's draft after any dry-run, API, or RBAC failure. Never discard unsaved edits on resource or context switch.
- Connection testing never sends write requests and never silently changes the active context.

**Secrets and data handling (intentional design, don't "fix")**
- Secret values, YAML, diffs, and logs are shown **unmasked** to users whose RBAC allows access. Detail views decode text Secret data and leave binary values as base64. Raw YAML keeps the API representation. Don't add redaction or reveal steps to browsing or editing views.
- Separately, credentials (tokens, keys, certs, auth headers, sensitive kubeconfig fields) **must** be redacted from errors, logs, and diagnostics, and stored only in platform-protected storage (Keychain), never in preferences.
- Secret values, logs, and resource content must never reach analytics, diagnostics, or persistent caches. There is no Tsubame backend or telemetry.
- Surface RBAC denials explicitly; never show a denial as an empty result. Never request elevated credentials automatically.

**Platform differences in auth**
- macOS: auto-discovers `~/.kube/config` (manual import stays equally visible). Supports bearer token, client certs, supported OIDC, and kubeconfig exec credential plugins. Plugins run only after explaining the command and getting explicit user approval.
- iOS/iPadOS: bearer token, imported client certificates, and supported OIDC flows. Client-certificate support was confirmed on 20 October 2026; unencrypted RSA and P-256/P-384/P-521 identities stay in the device Keychain. No exec plugins and no local `kubectl`. Never imply otherwise in the UI. Watches and logs are foreground-only, with relist and reconnect on resume.
- Namespace defaults to `default` per context.

## Scope sequencing

MVP covers connect, browse (Pods, Deployments, Services, Namespaces, Events, ConfigMaps, Secrets, StatefulSets, DaemonSets, Jobs, CronJobs, plus discovered CRDs), live watch, logs, YAML dry-run/apply, delete/restart/scale, and an RBAC help screen with copyable least-privilege Role examples. Exec, metrics, and port-forwarding come later; don't build them early. Validate auth and watch reliability before expanding UI breadth.

Open decisions (PRD §15) include OIDC flow details, exec-plugin UX, minimum OS and Kubernetes versions, `KUBECONFIG` merge behavior, multi-document YAML handling, distribution channel, and license. Ask before settling any of these.
