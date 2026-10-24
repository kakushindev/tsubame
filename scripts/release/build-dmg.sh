#!/usr/bin/env bash
# Builds the universal macOS app in Release and packs it into a drag-to-install DMG.
#
#   scripts/release/build-dmg.sh v1.2.3
#
# writes build/release/Tsubame-1.2.3.dmg and its .sha256 next to it. It runs the
# same way on a Mac as in the release workflow, so a release can be reproduced.
#
# Signing is opt-in through the environment. With nothing set, the app keeps the
# project's ad-hoc signature: it runs, but Gatekeeper blocks the first launch
# until the user allows it in System Settings.
#
#   SIGNING_IDENTITY   e.g. "Developer ID Application: Kakushin.dev (TEAMID)"
#   DEVELOPMENT_TEAM   the team that identity belongs to
#   SIGNING_KEYCHAIN   keychain holding the identity (optional; CI uses a temporary one)
#
# Notarization additionally needs an App Store Connect API key. It only runs when
# the app is signed, since Apple rejects ad-hoc signatures.
#
#   NOTARY_KEY_PATH    path to the AuthKey_XXXX.p8 file
#   NOTARY_KEY_ID      the key's ID
#   NOTARY_ISSUER_ID   the issuer ID
#
# BUILD_NUMBER overrides CFBundleVersion, which defaults to the commit count so it
# rises with every release and is the same wherever the tag is built.
set -euo pipefail

cd "$(dirname "$0")/../.."

tag="${1:?usage: build-dmg.sh <tag>}"
versions="$(scripts/release/version.sh "$tag")"
version="$(sed -n 's/^version=//p' <<<"$versions")"
marketing_version="$(sed -n 's/^marketing_version=//p' <<<"$versions")"
build_number="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"

out="build/release"
archive="$out/Tsubame.xcarchive"
staging="$out/dmg"
dmg="$out/Tsubame-$version.dmg"

rm -rf "$out"
mkdir -p "$out"

echo "Building Tsubame $version ($marketing_version, build $build_number)"

xcodegen generate

signing_args=()
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  echo "Signing with: $SIGNING_IDENTITY"
  code_sign_flags="--timestamp"
  if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
    code_sign_flags+=" --keychain $SIGNING_KEYCHAIN"
  fi
  signing_args=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM is required with SIGNING_IDENTITY}"
    OTHER_CODE_SIGN_FLAGS="$code_sign_flags"
  )
else
  echo "warning: SIGNING_IDENTITY is not set; the app keeps an ad-hoc signature" >&2
fi

# `set -o pipefail` keeps a failing xcodebuild from hiding behind xcbeautify.
formatter=(cat)
if command -v xcbeautify >/dev/null; then
  formatter=(xcbeautify)
fi

xcodebuild archive \
  -project Tsubame.xcodeproj \
  -scheme Tsubame \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  ${signing_args[@]+"${signing_args[@]}"} \
  | "${formatter[@]}"

app="$archive/Products/Applications/Tsubame.app"
codesign --verify --deep --strict --verbose=2 "$app"
lipo -archs "$app/Contents/MacOS/Tsubame"

# The DMG opens to the app beside an Applications shortcut, so installing is one drag.
mkdir -p "$staging"
ditto "$app" "$staging/Tsubame.app"
ln -s /Applications "$staging/Applications"

hdiutil create \
  -volname "Tsubame $version" \
  -srcfolder "$staging" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$dmg"
rm -rf "$staging"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  keychain_args=()
  if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
    keychain_args=(--keychain "$SIGNING_KEYCHAIN")
  fi
  codesign --sign "$SIGNING_IDENTITY" --timestamp ${keychain_args[@]+"${keychain_args[@]}"} "$dmg"

  if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    echo "Notarizing $dmg"
    xcrun notarytool submit "$dmg" \
      --key "$NOTARY_KEY_PATH" \
      --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required with NOTARY_KEY_PATH}" \
      --issuer "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required with NOTARY_KEY_PATH}" \
      --wait
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
  else
    echo "warning: NOTARY_KEY_PATH is not set; the DMG is signed but not notarized" >&2
  fi
fi

# Name only, no directory, so `shasum -c` works from wherever the files are downloaded.
(cd "$out" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")

echo "Built $dmg"
cat "$dmg.sha256"
