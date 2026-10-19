# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

One shared Swift/SwiftUI codebase ships to macOS, iPadOS, and iOS. All three follow Apple HIG. macOS is a co-primary target with Mac conventions: menus, multiple windows, keyboard shortcuts. iPadOS uses adaptive split views and supports touch, pointer, and keyboard. iOS covers fast, focused checks.

## Stack

Swift and SwiftUI. The Xcode project is generated from `project.yml` with XcodeGen. Networking and Kubernetes API logic live in a local Swift package, KubeKit, which uses `URLSession` and has no SwiftUI dependency. No third-party Swift Kubernetes client is used. The standard SwiftUI controls pick up Liquid Glass on OS 26 and keep the native system look on older releases. Provisional targets are iOS/iPadOS 17+ and macOS 14+, pending a real build.

## Users

- **Solo Kubernetes developer (primary launch audience).** Checks whether a deployment rolled out, inspects pods and events, and reads logs without leaving their dev workflow, mostly on a Mac.
- **On-call engineer / platform operator.** Needs a quick, trustworthy view of cluster health from a Mac or a mobile device, with enough detail to decide whether to act.
- **Kubernetes learner / occasional operator.** Needs a clear resource browser and readable YAML that don't assume constant terminal use.

Core jobs:
1. When a workload is unhealthy, find the affected resource and understand its current state.
2. When making a configuration change, review exactly what will be applied.
3. When away from the Mac, safely check a cluster from an iPhone or iPad.

## Product Purpose

Tsubame is a native Kubernetes management app for Apple platforms. Users can connect to clusters with kubeconfig credentials, browse resources that update live, read pod logs, edit and apply YAML after a server-side dry-run and diff, and delete, restart, or scale resources after confirming. The aim is to make routine Kubernetes inspection and troubleshooting feel at home on a Mac, iPad, or iPhone: clear, quick, and secure.

Success: a new user can import a kubeconfig and reach a resource list without external docs. The active cluster and namespace stay visible at all times. Lists recover from network interruptions and show how fresh their data is. Every write shows its target and the proposed result before it happens.

## Positioning

Tsubame is a Kubernetes manager built for Apple platforms that runs on Mac, iPad, and iPhone from one codebase. It talks to the Kubernetes API directly through its own Swift client. Writes are deliberate and reviewable. Comparable tools such as Freelens and Lens are desktop apps built on web runtimes.

Lower memory, CPU, or battery use is **an unproven hypothesis, not a claim**. Don't state it publicly until a benchmark against a defined Freelens workflow on the same Mac and cluster supports it.

## Operating Context

- Users connect from a kubeconfig. macOS finds `~/.kube/config` automatically, file and paste import are available on every platform, and iOS/iPadOS also offer guided manual setup.
- Auth: macOS supports bearer token, client certificates, supported OIDC, and kubeconfig exec credential plugins (each runs only after the user approves it). iOS/iPadOS support bearer token and supported OIDC only, with no exec plugins and no local `kubectl`.
- On mobile, watches and logs run only in the foreground. The app relists and reconnects on resume. Continuous background monitoring is out of scope.
- Users may be on call, away from their desk, on unreliable networks.
- Freelens is the category reference and the coverage checklist, not a parity target.

## Capabilities and Constraints

**MVP:** kubeconfig import, context and namespace selection (defaults to `default`), connection test with actionable errors, and browsing of Pods, Deployments, Services, Namespaces, Events, ConfigMaps, Secrets, StatefulSets, DaemonSets, Jobs, CronJobs, plus discovered CRDs (schema-driven when a usable schema exists, generic otherwise). It also includes live list/watch with freshness states, foreground pod logs, YAML editing (server-side dry-run, diff, separate apply), confirmed delete, restart, and scale, and an RBAC help screen with copyable least-privilege Role examples.

**Later:** container exec (macOS first), metrics, and macOS port-forwarding.

**Non-goals:** replacing `kubectl`, matching Lens/Freelens feature for feature, Helm, cluster provisioning, any hosted service, accounts, telemetry, or sync.

**Data rules:**
- Secret values, YAML, diffs, and logs are shown **unmasked** to users whose RBAC allows access.
- Credentials are kept in platform-protected storage and redacted from errors and diagnostics.
- Resource content and logs never reach analytics, diagnostics, or persistent caches.
- RBAC denials are shown explicitly, never as empty results.

**Terminology:** use Kubernetes terms directly: context, namespace, kind, resource, CRD, dry-run, Server-Side Apply, field manager.

**Undecided:** OIDC issuers and flows and mobile setup fields, exec-plugin approval UX, minimum OS and Kubernetes versions, `KUBECONFIG` merge behavior, multi-document YAML handling, distribution channel (App Store, direct download, or both), license.

## Brand Commitments

- **Publisher:** Kakushin.dev. Free, public, open source. Bundle ID `dev.kakushin.tsubame`.
- **Name:** Tsubame (燕), the swallow. It winks at Swift, since a swift is also a bird. Write "Tsubame" in UI, code, and docs, always with a capital T and never as "TSUBAME". When both forms appear together, write "Tsubame 燕".
- **Brand glyph:** 燕. It appears in the App Store subtitle, the About screen, marketing, and optionally the macOS menu bar.
- **Wordmark:** the Latin "Tsubame" is the primary wordmark, with 燕 as an optional secondary mark beside it. The kanji uses one typeface weight that matches the swallow's stroke weight.
- **Glyph rendering:** 燕 renders differently under Japanese and Chinese font fallbacks. Set the language to Japanese explicitly wherever 燕 appears, in the UI and on the marketing site, so it uses the Japanese glyph form. Check rendering in the system CJK fonts on all three platforms.
- **Tone rule (Japanese usage):** keep Japanese minimal and meaningful. 燕 appears only as the name. Don't use decorative or fake-kanji styling, and avoid "zen" marketing clichés.
- **Visual standard (standing preference):** every screen follows the native Apple category standard, executed at full craft, with no invented visual world. The quality bar is Apple's first-party apps (Xcode, Console, Activity Monitor, Finder) for native conventions and Linear and Raycast for speed, keyboard flow, and density. Later screens inherit this standard instead of choosing a new visual direction.
- **Discoverability:** 燕 is also a common surname and the name of a city in Niigata. Keep "Tsubame" in the App Store name and metadata.

Open brand items:
- Only tone rule 4 was supplied. Any rules 1–3 have not been recorded here.
- GitHub, App Store, domain, and trademark availability for the name have **not** been verified. Check before finalizing.

## Evidence on Hand

- `PRD.md` holds product requirements, scope, risks, and research sources.
- No code, screenshots, logo or icon files, benchmarks, users, testimonials, or press exist yet. Don't fabricate any of these, and don't claim a performance advantage.

## Product Principles

1. **Native first.** Use platform navigation, menus, shortcuts, accessibility, and adaptive layouts. Never ship anything that feels ported from a website.
2. **Read clearly; write carefully.** Browsing is effortless. Every mutation shows the cluster, namespace, object, and consequence before it happens.
3. **Show freshness honestly.** Live, reconnecting, stale, and disconnected states are always distinguishable. Cached data is never shown as live.
4. **Least surprise.** Kubernetes names, namespaces, and API semantics appear as they are. Important context is never hidden.
5. **Secure by default, transparent by permission.** Credentials stay protected. Resource content appears as the cluster returns it, to anyone RBAC permits.

## Accessibility & Inclusion

The launch interface is in English. Required for launch:
- VoiceOver labels on navigation and actions
- readable layouts at larger Dynamic Type sizes
- keyboard navigation on Mac and iPad
- support for Reduce Motion, Reduce Transparency, and Increase Contrast

Translations will be added when contributors or users can review them.
