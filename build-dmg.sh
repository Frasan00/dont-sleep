#!/usr/bin/env bash
# Usage: ./build-dmg.sh [version-or-tag]   e.g. ./build-dmg.sh v1.2.0
# Produces dist/DontSleep-<version>.dmg (drag-to-Applications layout) and a .sha256 next to it.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}([-+.][0-9A-Za-z.]+)?$ ]] || { echo "Invalid version: $VERSION" >&2; exit 1; }

VERSION="$VERSION" ./build.sh

DMG="dist/DontSleep-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p dist
rm -f "$DMG" "$DMG.sha256"

cp -R DontSleep.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Dont Sleep" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Built $DMG"
