# Releasing

Publishing a GitHub release builds the macOS DMG and attaches it to that release.
`.github/workflows/release.yml` does the work; `scripts/release/` holds the steps,
so a release can be reproduced on a Mac with the same commands.

macOS is the only installer for now. iOS and iPadOS need a signed build through the
App Store or TestFlight, which waits on the distribution decision (PRD §15).

## Versioning

Versions follow [Semantic Versioning 2.0.0](https://semver.org), written as a tag
with a `v` prefix:

| Tag | Meaning |
|---|---|
| `v1.2.3` | Stable release |
| `v1.2.3-beta.1`, `v1.2.3-rc.2` | Pre-release of 1.2.3 |

Bump MAJOR for a change that breaks users (a dropped OS version, a removed
feature, an incompatible settings migration), MINOR for new features, PATCH for
fixes. Before 1.0.0, MINOR may carry breaking changes.

`scripts/release/version.sh` checks the tag. It rejects leading zeros, missing or
extra components, and build metadata (`+…`), which SemVer excludes from precedence
and which does not survive in a download URL.

The tag sets the app's versions; `MARKETING_VERSION` in `project.yml` is only the
default for local builds.

- `CFBundleShortVersionString` is `MAJOR.MINOR.PATCH`. Apple allows only three
  integers, so `v1.2.3-beta.1` ships as `1.2.3`.
- `CFBundleVersion` is the commit count at the tag, so it rises with every release
  and comes out the same on any machine.
- The full version, pre-release part included, names the DMG:
  `Tsubame-1.2.3-beta.1.dmg`.

## Cutting a release

1. Make sure `main` is green.
2. Draft a release on GitHub with a new tag such as `v0.2.0` on `main`. Write the
   notes.
3. Tick **Set as a pre-release** if, and only if, the tag has a pre-release part.
   The workflow fails when the checkbox and the tag disagree, so a release candidate
   is never presented as the latest stable version.
4. Publish it.

The workflow then:

1. checks the tag (`Check version`);
2. runs the full CI suite against the tag (`Test`);
3. builds a universal (arm64 + x86_64) Release archive, packs it into a DMG with an
   Applications shortcut, signs and notarizes it when the secrets below exist, and
   uploads `Tsubame-<version>.dmg` and `Tsubame-<version>.dmg.sha256` to the release;
4. updates the Homebrew cask, for stable releases once a tap is configured.

To rebuild the assets of an existing release, run **Release** from the Actions tab
with its tag. The new files replace the old ones.

To build the DMG locally:

```bash
brew install xcodegen xcbeautify
scripts/release/build-dmg.sh v0.2.0     # writes build/release/Tsubame-0.2.0.dmg
```

## Signing and notarization

Without signing, the DMG holds the project's ad-hoc signed app. It runs, but
Gatekeeper blocks the first launch: users have to open **System Settings › Privacy &
Security** and choose **Open Anyway**. That is acceptable for early builds only.

Signing needs an Apple Developer Program membership. Add these repository secrets
and the next release is signed and notarized with no workflow change:

| Secret | Contents |
|---|---|
| `MACOS_CERTIFICATE_P12` | A **Developer ID Application** certificate and its private key, exported from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password chosen at export |
| `MACOS_SIGNING_IDENTITY` | The identity's full name, e.g. `Developer ID Application: Kakushin.dev (ABCDE12345)` |
| `APPLE_TEAM_ID` | The 10-character team ID |
| `NOTARY_KEY_P8` | Contents of an App Store Connect API key (`AuthKey_XXXX.p8`) with the Developer role |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the API keys list |

The workflow imports the certificate into a temporary keychain and deletes it,
and the API key file, when the job ends. The certificate without the notary key
gives a signed but unnotarized DMG, which Gatekeeper still blocks.

The app has the hardened runtime and no entitlements, which is what notarization
needs. The App Sandbox stays off (see the scaffold decisions in
`IMPLEMENTATION_CHECKLIST.md`); Developer ID distribution allows that, the Mac App
Store would not.

## Homebrew

The plan is a project tap, `kakushindev/homebrew-tap`, so users install with:

```bash
brew install --cask kakushindev/tap/tsubame
```

`packaging/homebrew/tsubame.rb` is the cask template. After each stable release the
`homebrew` job downloads the published DMG, computes its checksum, renders the cask
into the tap's `Casks/tsubame.rb` and pushes it. Pre-releases never reach the cask.

The job is off until it is configured:

1. Create the public repository `kakushindev/homebrew-tap` with an empty `Casks/`
   directory. Homebrew requires the `homebrew-` prefix.
2. Create a fine-grained personal access token (or GitHub App token) with
   **Contents: read and write** on that repository only. Store it as the
   `HOMEBREW_TAP_TOKEN` secret here.
3. Set the repository **variable** `HOMEBREW_TAP_REPO` to `kakushindev/homebrew-tap`.
4. Run **Release** by hand for the latest stable tag to seed the cask.

Ship the cask only once releases are signed and notarized. An unsigned cask
installs an app Gatekeeper blocks on first launch, exactly like the DMG, which is a
worse surprise after `brew install`. Submitting to the official `homebrew/cask`
repository is a later step with its own notability and signing requirements; its
maintainers then own the cask file, so this job would stop.
