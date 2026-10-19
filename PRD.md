# Tsubame — Product Requirements Document

**Working name:** Tsubame (燕, “swallow”)  
**Product:** Native Kubernetes management app for Apple platforms  
**Project / publisher:** Kakushin.dev  
**Bundle identifier:** `dev.kakushin.tsubame`  
**Status:** Draft  
**Last updated:** 19 October 2026

## 1. Summary

Tsubame is a native Kubernetes management app for macOS, iPadOS, and iOS, built from one shared Swift and SwiftUI codebase. It gives developers and operators a fast, approachable way to connect to Kubernetes clusters, inspect live resources, understand workload health, edit and apply YAML, and investigate problems through pod logs.

The first release includes cluster browsing, live resource updates, logs, YAML changes, and deliberate delete, restart, and scale actions. Container exec, metrics, and macOS port-forwarding are committed follow-on capabilities because they require more complex protocols and platform support.

The name is a small wordplay: the Japanese *amatsubame* refers to a swift/swallow, hinting at Swift without naming the programming language directly.

## 2. Problem and opportunity

Kubernetes desktop tools make cluster operations more accessible, but many are built on web runtimes and target desktop platforms. Users who prefer Apple-native software may want an app that behaves like a macOS app, uses system navigation and keyboard conventions, and is available on iPhone and iPad for lightweight cluster checks.

Tsubame’s opportunity is to combine a native Apple experience with direct Kubernetes API access and a shared codebase. Lower memory or CPU use is a product hypothesis to validate against comparable workflows, not a guaranteed outcome.

The main technical constraint is that Tsubame owns its Kubernetes client layer. There is no mature Swift client assumed for this project, so kubeconfig interpretation, authentication, REST requests, watches, and streaming behavior must be implemented and maintained carefully.

## 3. Product vision

Make routine Kubernetes inspection and troubleshooting feel at home on Apple devices: clear, quick, secure, and useful from a Mac, iPad, or iPhone.

## 4. Goals

- Connect to one or more Kubernetes clusters using supported kubeconfig credentials.
- Make common resources easy to find, filter, inspect, and follow as their state changes.
- Let users inspect and edit resource YAML, review a diff, and apply changes deliberately.
- Stream logs from a selected pod/container for troubleshooting, showing their content as returned by the cluster.
- Support confirmed YAML apply, delete, restart, and scale actions.
- Provide a consistent native experience across macOS, iPadOS, and iOS, adapted to each device.
- Keep cluster credentials protected and make the app’s access and write actions understandable.
- Build the networking and API logic in a reusable local Swift package, KubeKit.
- Validate the performance and usability advantages of a native app with real workflows.

## 5. Non-goals for the initial release

- Replacing `kubectl`, cloud CLIs, or every vendor-specific authentication plugin on every Apple platform.
- Full parity with Lens or Freelens, plugin ecosystems, Helm management, or cluster provisioning.
- Running arbitrary local commands or shelling out to `kubectl` on iOS/iPadOS.
- Container exec, port-forwarding, and metrics dashboards in the first release; all remain on the roadmap.
- A hosted service, account system, telemetry backend, or synchronization service.
- Guaranteeing that the app uses less memory or CPU before benchmarks establish it.

## 6. Target users and primary jobs

### Solo Kubernetes developer (primary launch user)

Needs to check whether a deployment rolled out, inspect pods/events, and view logs without leaving their development workflow.

### On-call engineer or platform operator

Needs a quick, trustworthy view of cluster health and resource state from a Mac or mobile device, with enough detail to decide whether to take action.

### Kubernetes learner or occasional operator

Needs a clear resource browser and readable YAML views that do not assume constant use of terminal commands.

### Primary jobs to be done

1. “When a workload is unhealthy, help me locate the affected resource and understand its current state.”
2. “When I need to make a configuration change, let me review exactly what I’m applying.”
3. “When I’m away from my Mac, let me safely check a cluster from my iPhone or iPad.”

## 7. Product principles

- **Native first:** Use platform navigation, menus, keyboard shortcuts, accessibility, and adaptive layouts.
- **Read clearly; write carefully:** Browsing is easy. Mutations show the target, scope, and consequences before they happen.
- **Show freshness:** Distinguish live, reconnecting, stale, and disconnected data.
- **Least surprise:** Use Kubernetes namespaces, resource names, and API semantics directly; do not hide important context.
- **Secure by default:** Keep connection credentials in platform-protected storage and keep browsed resource content out of analytics and diagnostics.
- **Useful offline:** Preserve only safe, clearly marked last-known context when disconnected; never imply cached data is live.

## 8. Scope and release plan

### Foundation: technical and product validation

- Establish the shared app and KubeKit package structure and XcodeGen project generation.
- Prove kubeconfig parsing and API access against representative clusters.
- Confirm supported TLS, proxy, certificate, and credential-provider behavior before promising broad compatibility.
- Build basic macOS navigation and verify resource-list performance with realistic object counts.

### MVP: connect, browse, troubleshoot, and change resources

- Import kubeconfig from a file or pasted text. On macOS, automatically discover `~/.kube/config` while keeping manual import equally visible. On iOS/iPadOS, import or manually set up a cluster.
- Select context and namespace, default to the `default` namespace, test the connection, and show actionable errors.
- Browse the initial standard resource set and discovered custom resources, with schema-driven CRD presentation where a usable schema is available.
- Watch supported resources for live changes, with reconnect and stale-state indicators.
- View resource details and YAML without masking values, including Secret resources when the user's RBAC permissions allow access.
- Edit YAML, run server-side dry-run, review the resulting diff, and explicitly apply.
- Delete, restart, and scale supported resources through confirmed actions, with dry-run where the API supports it.
- Stream pod logs in the foreground on all three platforms.
- Provide an RBAC preflight/help screen and copyable least-privilege policy examples.
- Support the same core read and write actions across macOS, iPadOS, and iOS with device-appropriate screens.

### Release 1: operational troubleshooting

- Improve log controls, including previous-container logs, timestamps, and bounded history.
- Improve mobile layouts, navigation, and connection resilience.
- Broaden standard resource coverage using the Freelens comparison inventory below.

### Later

- Container exec, initially macOS-first and subject to API/protocol validation.
- Resource metrics, with clear requirements for Metrics Server or other data sources.
- Port-forwarding on macOS.
- Further standard resource coverage and custom-resource actions.

Phases are capability groupings, not committed dates. The first implementation should validate authentication and watch reliability before expanding UI breadth.

## 9. Functional requirements

### 9.1 Cluster connection and kubeconfig

- Users can add a cluster by importing a kubeconfig file or pasting kubeconfig text; iOS/iPadOS also offer guided manual setup.
- macOS automatically detects `~/.kube/config` at first launch and when configuration changes, while file and paste import remain first-class options. The supported merge behavior for `KUBECONFIG` paths must be documented.
- The app presents available contexts with cluster and user identity details sufficient to distinguish them.
- The selected namespace defaults to `default` for each context; users can choose another namespace or all namespaces when permitted.
- The app tests connectivity and identifies common failures: invalid configuration, DNS/network failure, TLS trust failure, expired/invalid credential, authorization denial, and unsupported authentication method.
- macOS supports bearer tokens, client certificates, supported OIDC flows, and kubeconfig exec credential plugins where the executable is installed. The app explains and asks before it first runs a plugin command imported from kubeconfig.
- iOS/iPadOS support imported bearer tokens and supported OIDC sign-in/refresh flows. Executable credential plugins and local `kubectl` are unsupported. Client-certificate import on mobile is deferred unless a real target cluster requires it.
- The OIDC support matrix must name working issuers/flows and required setup fields; the presence of an OIDC-related kubeconfig entry alone does not guarantee a usable mobile sign-in flow.
- Imported credentials are stored using platform-protected storage. Users can remove a cluster and its stored credentials.
- The app never silently changes the active context or sends a write request as part of connection testing.

### 9.2 Resource browsing

- Initial built-in views include Pods, Deployments, Services, Namespaces, Events, ConfigMaps, Secrets, StatefulSets, DaemonSets, Jobs, and CronJobs. Later standard kinds are listed in the resource inventory below.
- CRDs are discovered from the connected API. Prefer schema-driven columns, field descriptions, and YAML validation when the CRD publishes a usable OpenAPI schema; fall back to generic list/detail/YAML when it does not.
- Kubernetes Secret objects appear in resource browsing when the user's RBAC permissions allow access. Their values are displayed without masking: decode text values in the detail view, retain base64 for binary values, and preserve the API representation in raw YAML.
- Users can filter by namespace and search visible resources by name; lists should remain usable with large result sets.
- Lists show resource kind, name, namespace when relevant, and a concise state summary appropriate to that kind.
- Details show key metadata, status, labels/annotations, owner references, and raw YAML where available.
- Empty, loading, permission-denied, partial, and error states are explicit.

### 9.3 Live updates

- The client uses Kubernetes list/watch patterns and resource versions to maintain current lists.
- Watches reconnect after interruption and recover from expired resource versions using a fresh list.
- UI indicates last update time and when information may be stale.
- Duplicate events, cancellation, backgrounding, and rapid navigation must not create unbounded tasks or memory growth.
- Polling may be used only as a documented fallback when watch is unavailable; it must be rate-limited.

### 9.4 YAML view and editing

- Users can view and copy YAML for supported resources exactly as presented by the Kubernetes API, including Secrets when authorized. The app does not mask values in YAML or diffs.
- Authorized users can edit YAML and apply it to the currently connected cluster.
- Before applying, the app validates syntax, identifies the resource and namespace, submits the intended write as a server-side dry-run, and displays the server's proposed result and diff. A failed dry-run blocks apply and preserves the draft.
- After a successful dry-run, apply requires a separate explicit user action and confirms the destination cluster and resource. The live apply uses the same manifest and operation as the dry-run. If the object changed in between, show the new conflict and ask for another review.
- Use Server-Side Apply with a stable Tsubame field manager for declarative YAML changes. Never force a field-ownership conflict silently.
- The editor uses the actual resource values throughout review and apply; it never substitutes display placeholders for data.
- On API rejection, preserve the user's draft and show the server error in useful terms.
- The editor must avoid silently discarding unsaved changes when switching resources or contexts.

### 9.5 Resource actions

- Delete is available only for supported resources and requires the active cluster, namespace, kind, and name in the confirmation. Offer API dry-run when supported, then send the delete only after confirmation.
- Restart is available for Deployments, StatefulSets, and DaemonSets through a deliberate workload-template change; show the expected rollout target and run dry-run before the live change where supported.
- Scale is available for scalable workloads through the scale subresource where available. Show current and proposed replica counts, run dry-run where supported, and confirm before applying.
- Actions unavailable under the user's RBAC permissions are disabled or return an explicit permission error; the app never asks for elevated credentials automatically.

### 9.6 Pod logs

- Users can select a pod and container and start/stop a live log stream.
- Where supported, users can request previous-container logs and select timestamps or a bounded starting window.
- Log rendering is bounded in memory, handles long lines and reconnections, shows output without masking, and exposes whether output is current or interrupted.
- Logs are not written to analytics or diagnostic logs by default.

### 9.7 RBAC help

- A preflight/help screen explains which read, watch, log, apply, delete, restart, and scale permissions are needed for the selected workflow.
- The app provides copyable example Roles/ClusterRoles with the minimum relevant verbs and resource scopes. It explains that an administrator must review and install these policies; Tsubame does not grant itself permissions.
- If a capability check is unavailable or inconclusive, the UI says so rather than promising an action will succeed.

### 9.8 Later operational features

- **Exec:** interactive terminal into a selected container, with explicit target confirmation, platform-specific capability disclosure, and secure stream handling.
- **Metrics:** show only metrics from a known source and clearly state when Metrics Server or another provider is unavailable.
- **Port-forward:** macOS-first workflow with local port selection, lifecycle controls, and clear indication while a forwarding session is active.

## 10. Platform requirements

Use the current Xcode and SDK to adopt Liquid Glass through standard SwiftUI navigation and controls on iOS/iPadOS 26 and macOS 26. Keep a coherent native system appearance on older supported releases; wrap any custom glass APIs in availability checks. Provisional deployment targets are iOS/iPadOS 17+ and macOS 14+, subject to a real build and compatibility review. Liquid Glass alone must not force the minimum OS to 26. [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

### macOS

- Multi-window/native window behavior where practical, menu commands, keyboard navigation, and shortcuts for common navigation and refresh actions.
- Automatic `~/.kube` discovery plus visible file and paste import.
- Support for the broadest authentication set, including user-approved exec credential plugins.
- Full YAML editing; later exec and port-forwarding target.

### iPadOS

- Adaptive split-view navigation and efficient use of larger screens.
- Support touch, keyboard, and pointer input where available.
- Foreground browsing and logs, with YAML editing and confirmed resource actions adapted to touch and keyboard input.

### iOS

- Fast context and namespace selection, resource browsing, detail inspection, foreground log viewing, and deliberate resource actions.
- Manual cluster import/setup with bearer token or a supported OIDC flow.
- Clear connectivity status and recovery when suspended or network changes.
- Watches and logs are foreground sessions; relist and reconnect on resume. Continuous background monitoring is outside scope.
- Do not imply support for local executable auth plugins.

All platforms share KubeKit APIs and domain models where platform facilities allow; UI may adapt to device capabilities.

## 11. Architecture and technical constraints

- **App target:** thin SwiftUI presentation and platform integration layer.
- **KubeKit local Swift package:** kubeconfig parsing, cluster/context models, credential handling interfaces, REST client using `URLSession`, API discovery, resource operations, watch streams, and testable error mapping.
- **Project generation:** Xcode project generated from `project.yml` with XcodeGen; project settings and dependencies should be reproducible from the command line.
- Keep UI state management separate from HTTP/watch implementation.
- Use typed models for core Kubernetes resources and a generic representation for unknown/custom resources.
- Avoid coupling the package to SwiftUI so it can be tested and reused independently.
- Document supported Kubernetes API behavior and auth limitations.

## 12. Security, privacy, and reliability requirements

- Store tokens, private keys, and client certificates in appropriate protected storage; do not persist secrets in ordinary preferences or logs.
- Display resource content, including Secret values and log lines, as returned by the cluster when the user has permission to access it. No automatic redaction, hidden-value controls, or reveal step is applied in browsing and editing views.
- Do not persist Secret values or logs in app preferences, analytics, or diagnostic reports. Keep active views in memory only unless the user explicitly copies or exports content.
- Apply least-privilege access: request only the API permissions needed for the selected action; surface RBAC denials rather than disguising them as empty results.
- Make the active cluster and namespace visible before write operations.
- Redact credentials, authorization headers, and sensitive kubeconfig fields from errors and diagnostics.
- Use TLS verification by default; any trust exceptions require deliberate, clearly explained configuration.
- Never transmit cluster configuration or telemetry to a Tsubame service in the initial product.
- Cancel network work on context switches and bound buffers for watch events and logs.
- Handle offline, app suspension, token expiry, and API-server restarts without presenting stale state as current.

## 13. Success measures

### MVP quality gates

- A new user can import a supported kubeconfig, select a context, and reach a resource list without external documentation.
- On macOS, a supported context from `~/.kube/config` is discovered without a manual file picker.
- Users can identify the selected cluster and namespace at all times in the main browsing flow.
- New contexts open in the `default` namespace and can switch to an authorized namespace.
- Supported resource lists recover from temporary network interruption and show freshness accurately.
- Applying YAML always completes a successful server-side dry-run and presents the target and proposed diff before the live request is sent.
- Delete, restart, and scale require explicit confirmation with the target cluster and object visible.
- The RBAC help screen offers copyable least-privilege examples without granting permissions itself.
- No credential values appear in app logs or user-visible error details.
- Authorized users can browse Secret objects and see their values without masking; resource values do not enter analytics or diagnostics.
- Common list and detail workflows remain responsive on representative clusters, measured on supported devices.

### Product measures to establish after internal/beta use

- Connection setup completion rate and time to first resource list.
- Successful watch recovery rate after network interruption.
- Time to locate a named resource and reach its detail view.
- YAML apply completion and failure rates, including validation and RBAC errors.
- Log stream startup latency and session stability.
- App memory, CPU, and battery use compared with a defined Freelens workflow and equivalent cluster/task setup.
- Qualitative satisfaction across Mac, iPad, and iPhone workflows.

Avoid collecting cluster names, resource content, logs, or credentials for product analytics.

## 14. Key risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Hand-built client misses Kubernetes protocol edge cases | Incorrect or unreliable resource state | Start with limited resource types; validate against multiple cluster versions; test watch reconnect and resource-version recovery. |
| Authentication varies by cluster and provider | Users cannot connect despite valid kubeconfig | Publish a per-platform support matrix; support user-approved exec plugins on macOS and token/OIDC on mobile; provide precise unsupported-auth errors. |
| Mobile networking and app suspension interrupt watches | Stale data or confusing connection behavior | Treat foreground connectivity as primary; show freshness; reconnect and relist on resume. |
| YAML edits and quick actions can cause operational damage | Unintended cluster changes | Dry-run where supported; show cluster/context, object identity, and proposed result; require explicit confirmation; preserve drafts after failures. |
| CRDs have arbitrary schemas and shapes | Generic views may be hard to understand | Use published schemas when available and reliable generic views when absent or incomplete. |
| Native performance advantage is assumed | Positioning may be unsupported | Benchmark memory, CPU, responsiveness, and battery for the same representative workflows. |
| Feature ambition expands before core reliability | Delayed or brittle MVP | Deliver connection, list/watch, logs, and safe mutations first; sequence exec, metrics, and port-forward afterward. |

## 15. Confirmed product decisions and remaining implementation choices

### Confirmed

- Kakushin.dev publishes Tsubame as a free, public, open-source app under bundle identifier `dev.kakushin.tsubame`.
- macOS automatically discovers `~/.kube/config`; all platforms offer manual import, and mobile also offers guided setup.
- macOS has the broadest authentication support. iOS/iPadOS launch support is bearer token plus supported OIDC flows.
- YAML changes use server-side dry-run, review, then a separate live apply action.
- Delete, restart, and scale are expected in the initial product.
- Kubernetes Secret objects and values appear as-is for authorized users; logs and YAML are not masked while browsing.
- The namespace starts as `default` and can be changed.
- Mobile browsing and logs work in the foreground; background monitoring is not required.
- CRD schemas take priority when available, with a generic fallback.
- An RBAC preflight/help screen and copyable least-privilege policy examples are required.
- Solo developers are the primary launch audience.
- Exec, metrics, and port-forwarding are all on the roadmap.
- Standard SwiftUI controls should use Liquid Glass on current Apple releases and maintain native appearance on older supported systems.
- No special VPN, bastion, or enterprise-proxy workflow is required for the first release. Normal direct connectivity and kubeconfig CA handling remain necessary.

### Still to decide during prototype validation

- Exact OIDC issuers/flows and how mobile users enter issuer, client ID, scopes, and redirect configuration.
- The supported macOS exec-plugin behavior and how user approval, plugin output, refresh, and failures are handled.
- Exact minimum Apple OS versions, after building with the current SDK on the provisional iOS/iPadOS 17+ and macOS 14+ targets.
- Kubernetes version floor and tested cluster distributions.
- Exact `KUBECONFIG` merge behavior on macOS, including multiple files and file-path references.
- Whether free distribution uses the App Store, direct downloads, or both; the source code will be public.
- How multi-document YAML is edited and applied safely.
- The licensing choice for the public repository.

## 16. Reference

Freelens is a free, open-source Kubernetes management UI available for desktop platforms. Tsubame uses it as a category reference while focusing on Apple-native interaction and mobile access. Feature details and support evolve; consult the project for current behavior: [freelensapp/freelens](https://github.com/freelensapp/freelens/).

### Resource inventory informed by Freelens

Freelens' published object/API surface includes core workloads, batch workloads, networking, storage, autoscaling, RBAC, and custom resources. Tsubame uses this as a coverage checklist, not a parity promise. [Freelens resource type discussion](https://github.com/freelensapp/freelens/issues/2365), [Freelens repository](https://github.com/freelensapp/freelens/)

| Category | Tsubame first release | Follow-on coverage to assess |
|---|---|---|
| Workloads | Pods, Deployments, StatefulSets, DaemonSets, Jobs, CronJobs | ReplicaSets, HorizontalPodAutoscalers |
| Cluster and configuration | Namespaces, Events, ConfigMaps, Secrets | Nodes, ServiceAccounts, ResourceQuotas, LimitRanges |
| Networking | Services | Ingresses, NetworkPolicies, EndpointSlices |
| Storage | — | PersistentVolumes, PersistentVolumeClaims, StorageClasses |
| Access | RBAC help and permission status | Roles, RoleBindings, ClusterRoles, ClusterRoleBindings as read-only views |
| Custom resources | CRD discovery and schema-first custom resource views | Pinned kinds, richer schema-aware actions |
| Sensitive resources | Authorized Secret browsing with unmasked values | Further Secret-specific workflows as needed |

## 17. Engineering requirements confirmed by research

### Kubernetes write semantics

Server-Side Apply tracks field ownership and rejects conflicts with other managers unless the client deliberately forces them. Tsubame uses a stable field manager, performs a server-side dry-run, shows the proposed result, and applies only after a second user action. Conflicts return the user to review; the app does not silently force ownership. The same pattern applies to delete, restart, and scale where the API supports dry-run. [Kubernetes API concepts](https://kubernetes.io/docs/reference/using-api/api-concepts/), [Server-Side Apply](https://kubernetes.io/docs/reference/using-api/server-side-apply/)

### Kubernetes watches and large lists

The client must relist after an expired `resourceVersion` (`410 Gone`), honor `Retry-After` on `429` responses, and use bounded backoff for network failures. Lists should use pagination for large result sets, cancel work after context changes, and keep only visible or needed resource kinds watched. [Kubernetes API concepts](https://kubernetes.io/docs/reference/using-api/api-concepts/)

### Credential boundaries

Kubeconfig can refer to external files and exec credential plugins. macOS may run an imported plugin only after explaining the command and getting explicit user approval. Mobile cannot rely on that mechanism, so token and supported OIDC setup are separate flows. Unsupported auth must be reported clearly. [Kubernetes authentication](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)

### Secret handling

Kubernetes states that listing or watching Secret objects reveals their contents. Tsubame follows the user's Kubernetes RBAC permissions: if access is granted, browsing shows Secret values and other resource content without masking. Raw YAML preserves the API representation; the detail view decodes text Secret data for readability and leaves binary values in base64. Secret values and logs are not included in analytics, diagnostics, or automatic persistent caches. [Kubernetes RBAC good practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)

### Mobile lifecycle and Liquid Glass

Mobile watches and logs run while the app is in the foreground; after resume, Tsubame refreshes the list and reconnects. Apple normally suspends background apps, so continuous monitoring is not a mobile promise. Standard SwiftUI controls adopt Liquid Glass on current OS releases while preserving the system appearance on older releases. [Apple background execution](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes), [Apple Liquid Glass guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

## 18. Plain-language defaults for the three unclear questions

### 13. How much cluster data should Tsubame handle?

This asks how the app behaves when a cluster has many resources. Use 100, 1,000, and 10,000 visible objects as small, medium, and large validation cases. Tsubame should show a first page promptly, load more as needed, watch only the active resource views, and keep memory bounded. Set a numerical speed and memory target after a prototype is measured on real devices and clusters.

### 16. How should the native performance claim be checked?

On the same Mac and cluster, perform the same tasks in Tsubame and Freelens: connect, open a pod list, inspect a pod, follow logs, and leave the app idle for ten minutes. Record time to first useful view, memory, active/idle CPU, and battery use where practical. Only publish a lower-resource-use claim if the results support it.

### 19. What does accessibility and localization mean for launch?

Proposed launch default: English interface; VoiceOver labels for navigation and actions; readable text at larger system text sizes; keyboard navigation on Mac and iPad; and support for Reduce Motion, Reduce Transparency, and increased contrast. Add translations when contributors or users can review them. These are usability requirements for the public app, not a demand for a large localization program at launch.

### Research sources

- [Kubernetes authentication and credential plugins](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)
- [Kubernetes API list/watch and write concepts](https://kubernetes.io/docs/reference/using-api/api-concepts/)
- [Kubernetes Server-Side Apply](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- [Kubernetes RBAC good practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
- [Apple background execution modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
- [Apple Liquid Glass guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
