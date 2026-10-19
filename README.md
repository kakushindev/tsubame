# Tsubame

A native Kubernetes management app for macOS, iPadOS, and iOS, built from one shared
Swift and SwiftUI codebase. Connect to a cluster with your kubeconfig, browse
resources that update live, read pod logs, review a server-side dry-run and diff
before applying YAML, and delete, restart, or scale after an explicit confirmation.

Published by Kakushin.dev as free, open-source software. Bundle identifier
`dev.kakushin.tsubame`.

The name is a small wordplay: *amatsubame* (燕) is the swallow, hinting at Swift
without naming the language.

## Status

**Early scaffold — not usable as an app yet.** The project builds for both platforms
and the test suites pass, but the feature surface is mostly outstanding. What exists
today is the client foundation: kubeconfig parsing, the `URLSession` transport, API
discovery, the list/watch loop with relist on `410 Gone`, error mapping, credential
redaction, the Keychain store, and a cluster sidebar.

[docs/IMPLEMENTATION_CHECKLIST.md](docs/IMPLEMENTATION_CHECKLIST.md) tracks item by
item what is done and what is not. Resource browsing, logs, the YAML editor, writes,
and the RBAC help screen are all still to come.

## Requirements

- macOS with Xcode 16 or newer (Swift 6 toolchain, Swift 6 language mode)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- No Apple developer team. Signing is ad-hoc by default, so the project builds and
  runs on any Mac and in the Simulator. Device builds and distribution need a real
  `DEVELOPMENT_TEAM` and `CODE_SIGN_STYLE = Automatic`.

Deployment targets are iOS/iPadOS 17+ and macOS 14+. These are provisional, pending
a compatibility review. Liquid Glass comes from standard SwiftUI controls on OS 26
and must never raise the minimum OS.

## Build and test

```bash
xcodegen generate                                  # regenerate Tsubame.xcodeproj
swift build  --package-path KubeKit                # build the package alone
swift test   --package-path KubeKit                # run the package tests

xcodebuild -project Tsubame.xcodeproj -scheme Tsubame -destination 'platform=macOS' build
xcodebuild -project Tsubame.xcodeproj -scheme Tsubame -destination 'platform=macOS' test
xcodebuild -project Tsubame.xcodeproj -scheme Tsubame -destination 'generic/platform=iOS Simulator' build
```

`project.yml` is the source of truth for the Xcode project; `Tsubame.xcodeproj` is a
generated build artifact and is git-ignored. Edit `project.yml`, never the generated
project, and run `xcodegen generate` after adding or removing a source file.

## Layout

```
tsubame/
├── project.yml     XcodeGen source of truth
├── App/            SwiftUI presentation and platform integration
│   ├── Sources/    App, Navigation, DesignSystem, Platform, Features
│   ├── Resources/  Info.plist, Assets.xcassets
│   └── Tests/
├── KubeKit/        Local Swift package; no SwiftUI anywhere in it
│   ├── Sources/
│   │   ├── KubeModels/     Data types only
│   │   ├── KubeKit/        Transport, auth contracts, kubeconfig, errors
│   │   ├── KubeKeychain/   Keychain implementation of CredentialStore
│   │   └── KubeTestSupport/
│   └── Tests/
└── docs/
```

Dependencies run one way, and the layers are separate targets so the compiler
enforces it:

```
Features ──▶ App (composition root) ──▶ KubeKeychain ──▶ KubeKit ──▶ KubeModels
```

Tsubame owns its whole Kubernetes client layer; there is no third-party Swift
Kubernetes client. The one external dependency is [Yams](https://github.com/jpsim/Yams)
for YAML.

## Design rules worth knowing before you contribute

- **Writes are deliberate.** YAML apply validates, runs a server-side dry-run, shows
  the result and a diff, and applies only after a separate explicit action, reusing
  the same manifest. Server-Side Apply uses a stable `tsubame` field manager and
  never forces a field-ownership conflict silently. Delete, restart, and scale
  confirm with cluster, namespace, kind, and name.
- **Freshness is always visible.** The UI distinguishes live, reconnecting, stale,
  and disconnected data, and never presents cached data as live.
- **Secret values are shown unmasked** to users whose RBAC allows access — in detail
  views, YAML, diffs, and logs. That is intentional; don't add redaction or reveal
  steps to browsing and editing.
- **Credentials are redacted everywhere else.** Tokens, keys, certs, and sensitive
  kubeconfig fields never appear in errors, logs, or diagnostics, and live only in
  the Keychain. Resource content, Secret values, and logs never reach a persistent
  cache. There is no backend and no telemetry.
- **RBAC denials are surfaced explicitly**, never as an empty result, and the app
  never asks for elevated credentials on its own.
- **Platform auth differs.** macOS discovers `~/.kube/config`, and supports bearer
  tokens, client certificates, supported OIDC, and kubeconfig exec plugins — the
  latter only after explaining the command and getting explicit approval.
  iOS/iPadOS support bearer tokens and supported OIDC only, with no exec plugins and
  no local `kubectl`, and watches and logs run in the foreground only.

## Documentation

- [PRD.md](PRD.md) — source of truth for scope, behavior, and constraints
- [PRODUCT.md](PRODUCT.md) — product framing, users, and positioning
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — structure and the rules that keep it
- [docs/IMPLEMENTATION_CHECKLIST.md](docs/IMPLEMENTATION_CHECKLIST.md) — what exists, what doesn't
- [AGENTS.md](AGENTS.md) — guidance for AI agents working in this repository

Read the relevant PRD section, plus both docs, before implementing a feature, and
tick the checklist as items land.

## Open decisions

Still undecided (PRD §15), so don't settle them in a pull request without asking:
OIDC issuers and flows, exec-plugin approval and refresh UX, the final minimum OS
versions, the Kubernetes version floor, `KUBECONFIG` multi-path merge behavior,
multi-document YAML handling, the distribution channel, and the license.

## License

Not yet chosen. The project is intended to be free and open source; the specific
license is one of the open decisions above, and no `LICENSE` file exists yet.
