#!/bin/bash
# Build CrowsNest.app -- a signed, self-contained menu bar app.
# No .xcodeproj: swiftc compiles the sources, then we assemble the bundle.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Ad-hoc signing by default ("-"), so the build works out of the box on any Mac
# and ships no one's identity in source. For a real signing identity, export
# your own: CROWSNEST_IDENTITY="Apple Development: you@example.com (TEAMID)".
IDENTITY="${CROWSNEST_IDENTITY:--}"
DEST="${CROWSNEST_DEST:-$HOME/Applications}"

# Assemble in a scratch dir, never in the source tree. This repo lives under
# Desktop, which iCloud syncs, and the file provider re-attaches
# com.apple.FinderInfo between `xattr -cr` and `codesign` -- codesign then
# rejects the bundle as "resource fork, Finder information, or similar
# detritus". Building outside the synced tree removes the race entirely.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/CrowsNest.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> compiling"
swiftc -O -parse-as-library \
    -target arm64-apple-macos14.0 \
    -o "$APP/Contents/MacOS/CrowsNest" \
    "$HERE"/Sources/*.swift

# collector.py ships inside the bundle so the app is self-contained; it is
# piped to the remote machine over stdin and never installed there.
cp "$HERE/collector.py" "$APP/Contents/Resources/collector.py"

# Without an icon macOS has nothing to draw beside a notification, so alerts
# arrive blank. Regenerate with tools/make-icon.sh if the artwork changes.
cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>CrowsNest</string>
  <key>CFBundleIdentifier</key><string>com.atwavetech.crowsnest</string>
  <key>CFBundleName</key><string>Crow's Nest</string>
  <key>CFBundleDisplayName</key><string>Crow's Nest</string>
  <key>NSUserNotificationAlertStyle</key><string>alert</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key><true/>
  <!--
    Required to reach a machine on the LAN. Without this key macOS cannot
    even PROMPT for Local Network access, so it silently denies: tccd logs
    "does not allow prompting; returning denied" and the spawned ssh dies
    with "No route to host". The app then shows an empty list with no error
    anywhere -- the exact silent failure this project exists to eliminate.
    Only bites apps launched by Finder/launchd; a shell-launched build
    inherits the terminal's grant and works, which makes this easy to
    misdiagnose as a code bug.
  -->
  <key>NSLocalNetworkUsageDescription</key><string>Crow's Nest connects to your development machine over SSH to read which Claude Code sessions are running.</string>
</dict></plist>
PLIST

echo "==> signing"
xattr -cr "$APP"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP" && echo "    signature OK"

echo "==> installing"
mkdir -p "$DEST"
rm -rf "$DEST/CrowsNest.app"
# ditto preserves the signature; cp -R does not reliably.
ditto "$APP" "$DEST/CrowsNest.app"
codesign --verify --strict "$DEST/CrowsNest.app" && echo "    installed signature OK"

echo
echo "Installed $DEST/CrowsNest.app"
echo "Run it:   open '$DEST/CrowsNest.app'"
