#!/usr/bin/env bash
# Bundle the self-contained dingbat binary into a distributable .app and .dmg.
# Requires macOS tools: plutil, hdiutil (both built in). The binary must
# already be a -d:macdist build (static SDL3, no Homebrew dependency).
#
# Usage: ci/make-macos-app.sh <binary> <version> <out_dir>
set -euo pipefail

BIN="${1:?binary path}"
VERSION="${2:-0.0.0}"
OUT="${3:-dist/macos}"

APP="$OUT/dingbat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/dingbat"
chmod +x "$APP/Contents/MacOS/dingbat"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

# The icon, drawn at every size by tools/logo_flap/flap.py (pixel art doesn't resample).
cp ci/dingbat.icns "$APP/Contents/Resources/dingbat.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>dingbat</string>
  <key>CFBundleDisplayName</key>     <string>dingbat</string>
  <key>CFBundleIdentifier</key>      <string>com.mattrbeck.dingbat</string>
  <key>CFBundleVersion</key>         <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleExecutable</key>      <string>dingbat</string>
  <key>CFBundleIconFile</key>        <string>dingbat</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>LSMinimumSystemVersion</key>  <string>11.0</string>
  <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Read-only compressed .dmg containing the .app.
DMG="$OUT/dingbat-macos.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "dingbat" -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "Built $APP and $DMG"
