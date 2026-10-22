#!/usr/bin/env bash
# Builds DontSleep.app as a universal (arm64 + x86_64) binary. VERSION sets the bundle version.
set -euo pipefail
cd "$(dirname "$0")"
APP=DontSleep.app
VERSION="${VERSION:-1.0.0}"
MIN_MACOS=14.0
# make-icon.swift is a separate build-time tool with its own entry point
SOURCES=(main.swift Core.swift CLI.swift CLIHelp.swift)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos$MIN_MACOS" "${SOURCES[@]}" -o "$TMP/DontSleep-$arch"
done
lipo -create "$TMP"/DontSleep-arm64 "$TMP"/DontSleep-x86_64 -output "$APP/Contents/MacOS/DontSleep"

swiftc -O make-icon.swift -o "$TMP/make-icon"
"$TMP/make-icon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Dont Sleep</string>
<key>CFBundleDisplayName</key><string>Dont Sleep</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>DontSleep</string>
<key>CFBundleIdentifier</key><string>local.dontsleep</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
<key>LSUIElement</key><true/>
</dict></plist>
PL
codesign -s - --force "$APP"
