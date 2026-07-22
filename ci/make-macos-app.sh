#!/usr/bin/env bash
# Bundle the self-contained dingbat binary into a distributable .app and .dmg.
# Requires macOS tools: sips, iconutil, hdiutil (all built in). The binary must
# already be a -d:macdist build (static SDL2, no Homebrew dependency).
#
# Usage: ci/make-macos-app.sh <binary> <version> <out_dir>
set -euo pipefail

BIN="${1:?binary path}"
VERSION="${2:-0.0.0}"
OUT="${3:-dist/macos}"
ICON_SRC="web/web-app-manifest-512x512.png"

APP="$OUT/dingbat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/dingbat"
chmod +x "$APP/Contents/MacOS/dingbat"

# Build a .icns from the 512px app icon.
ICONSET="$(mktemp -d)/dingbat.iconset"
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z "$sz" "$sz"       "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}.png"    >/dev/null
  sips -z $((sz*2)) $((sz*2)) "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/dingbat.icns"

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
