#!/usr/bin/env bash
# Turns a release tag into the versions a build needs, or fails if the tag is not
# Semantic Versioning 2.0.0 (https://semver.org).
#
#   scripts/release/version.sh v1.4.0-beta.2
#
# prints `key=value` lines, ready to append to $GITHUB_OUTPUT:
#
#   version=1.4.0-beta.2      full SemVer, used in file names and the cask
#   marketing_version=1.4.0   CFBundleShortVersionString; Apple allows only three
#                             integers, so the pre-release part drops off
#   prerelease=true           whether the tag carries a pre-release identifier
#
# Tags take the conventional `v` prefix. A leading zero, a missing component or a
# four-part version is rejected rather than guessed at. So is build metadata
# (`+...`): SemVer gives it no precedence, so v1.0.0+a and v1.0.0+b would be two
# releases of one version, and a `+` does not survive in a download URL.
set -euo pipefail

tag="${1:?usage: version.sh <tag>}"

# The SemVer grammar without build metadata, with a mandatory `v` in front.
numeric='0|[1-9][0-9]*'
identifier='[0-9]*[A-Za-z-][0-9A-Za-z-]*'
prerelease="(${numeric}|${identifier})(\.(${numeric}|${identifier}))*"
pattern="^v(${numeric})\.(${numeric})\.(${numeric})(-(${prerelease}))?$"

if [[ ! "$tag" =~ $pattern ]]; then
  echo "error: '$tag' is not a release tag such as v1.2.3 or v1.2.3-beta.1" >&2
  exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

echo "version=${tag#v}"
echo "marketing_version=${major}.${minor}.${patch}"
if [[ "$tag" == *-* ]]; then
  echo "prerelease=true"
else
  echo "prerelease=false"
fi
