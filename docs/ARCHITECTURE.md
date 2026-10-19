# Architecture

How Tsubame's code is organized, and the rules that keep it that way. PRD §11 sets
the shape; this document records the decisions made while scaffolding it.

## Layout

```
tsubame/
├── project.yml                 XcodeGen source of truth; .xcodeproj is generated
├── App/
│   ├── Sources/
│   │   ├── App/                Entry point, composition root, root view
│   │   ├── Navigation/         Selection and routing state
│   │   ├── DesignSystem/       Shared views and presentation vocabulary
│   │   ├── Platform/           Per-platform capability boundaries
│   │   └── Features/           One folder per feature area
│   │       └── Clusters/       <Feature>Model.swift + <Feature>View.swift
│   ├── Resources/              Info.plist, Assets.xcassets
│   └── Tests/
├── KubeKit/                    Local Swift package; no SwiftUI anywhere in it
│   ├── Sources/
│   │   ├── KubeModels/         Data types only
│   │   ├── KubeKit/            Transport, auth contracts, kubeconfig, errors
│   │   ├── KubeKeychain/       Keychain implementation of CredentialStore
│   │   └── KubeTestSupport/    Test doubles shared by the test targets
│   └── Tests/
└── docs/
```

## Dependency direction

```
Features ──▶ App (composition root) ──▶ KubeKeychain ──▶ KubeKit ──▶ KubeModels
     └──────────────────────────────────────────────────┘
```

One way only. The compiler enforces it, which is the reason the layers are separate
targets rather than folders:

- **KubeModels** imports Foundation and nothing else. Putting a URL request in it
  would not compile, which is how "models never reach the network" stays true.
- **KubeKit** owns the client layer and declares its contracts (`KubernetesTransport`,
  `CredentialProvider`, `CredentialStore`, `KubeconfigParsing`). It never imports
  SwiftUI or Security-backed storage, so every test runs without a cluster or a
  keychain.
- **KubeKeychain** is the platform-backed implementation of one KubeKit contract.
  It is separate so KubeKit stays testable and so nothing else can reach storage
  directly.
- **The app target** is presentation and platform integration. It is the only place
  that constructs a transport, a credential provider, or a store.

Feature folders do not import each other. Shared presentation goes in `DesignSystem`;
shared state goes through `AppEnvironment` or `NavigationModel`.

## The composition root

`AppEnvironment` builds every collaborator and hands them out. Feature models take
their dependencies through `init`, never from a singleton or a global.

```swift
ClusterListModel(environment: environment)                  // live
ClusterListModel(environment: .inMemory(), discovery: ...)  // test
```

`AppEnvironment.live()` uses the Keychain; `AppEnvironment.inMemory()` uses an
in-memory store. Previews use the latter, so a preview never touches real storage.

## Feature shape

Each feature folder holds a model and a view:

- `<Feature>Model.swift` — `@MainActor @Observable final class`. Owns state,
  performs work, exposes a state enum the view renders. Never imports SwiftUI.
- `<Feature>View.swift` — reads the model and renders it. No parsing, no requests,
  no decisions the model should be making.

This keeps PRD §11's "UI state management separate from the HTTP/watch
implementation" literal: the model talks to KubeKit, the view talks to the model.

## Object-oriented conventions

- **Protocols define collaborators; classes and actors implement them.** Every
  boundary that could be a network, a keychain, or a clock is a protocol, so each
  side is testable alone. Concrete types are `final` unless subclassing is designed
  for, which so far it is not.
- **Reference types hold identity and lifetime**: clients, transports, credential
  providers, feature models. Shared mutable state lives in an `actor`
  (`BearerTokenCredentialProvider`, `KeychainCredentialStore`, `StubTransport`),
  not behind a lock.
- **Value types hold data**: every type in KubeModels, plus requests, options, and
  policies. They are `Sendable` and `Hashable` so they cross isolation boundaries
  without defensive copying.
- **No `Utils`, `Helpers`, `Extensions`, or `Common` folder.** Behavior belongs on
  the type that owns the data, or on the object whose job it is. A free function
  that is used once is inlined; a free function used in several places is a method
  on a type that owns the concept. Extensions are allowed where they add behavior
  to a type the package owns and live in that type's file.
- **One concept, one owner.** `KubernetesErrorMapper` is the only place an HTTP
  status becomes an error. `KubernetesCoder` is the only place JSON coding is
  configured. `CredentialRedactor` is the only place credentials are stripped.
  `AppEnvironment.platformKubeconfigDiscovery` is the only place kubeconfig
  discovery branches on platform. Duplicating any of these is the bug, not the fix.

## Concurrency

Swift 6 language mode with complete strict concurrency, in both the package and the
app target. Feature models and views are `@MainActor`; everything in KubeKit is
`Sendable` and isolation-free, so a watch can run off the main actor and deliver to
it. Streams are `AsyncThrowingStream` with `onTermination` wired to cancellation, so
closing a view closes its connection.

## Platform differences

Platform branching is confined to `App/Sources/Platform` and to the composition
root. `KubeconfigDiscovery` is the pattern: a protocol, a macOS implementation, an
iOS implementation that reports nothing, and one `#if` in `AppEnvironment` that
picks between them. Feature code contains no `#if os(...)`.

## Project generation

`project.yml` is the source of truth; `Tsubame.xcodeproj` is generated and git-ignored.
Signing defaults to ad-hoc (`CODE_SIGN_IDENTITY = "-"`, manual style, no profile) so
the project builds and runs on any Mac with no Apple developer team. Device builds
and distribution need a real `DEVELOPMENT_TEAM`.
