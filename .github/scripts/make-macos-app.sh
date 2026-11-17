#!/usr/bin/env bash
# Bundle the self-contained dingbat binary into a distributable .app and .dmg.
# Requires macOS tools: plutil, hdiutil (both built in). The binary must
# already be a -d:macdist build (static SDL3, no Homebrew dependency).
#
# Usage: .github/scripts/make-macos-app.sh <binary> <version> <out_dir>
#
# Unsigned unless MACOS_SIGN_IDENTITY is set: then the app and the .dmg are
# signed, and notarized and stapled given notary credentials (macos-sign.sh).
set -euo pipefail

SIGN="$(dirname "$0")/macos-sign.sh"

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
cp .github/scripts/dingbat.icns "$APP/Contents/Resources/dingbat.icns"

# One exported type per ROM kind: <identifier> <description> <extensions...>
rom_type() {
  id=$1 desc=$2
  shift 2
  exts=""
  for e in "$@"; do exts="$exts<string>$e</string>"; done
  printf '<dict><key>UTTypeIdentifier</key><string>%s</string>' "$id"
  printf '<key>UTTypeDescription</key><string>%s</string>' "$desc"
  printf '<key>UTTypeConformsTo</key><array><string>public.data</string></array>'
  printf '<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key>'
  printf '<array>%s</array></dict></dict>' "$exts"
}
ROM_TYPES="$(rom_type com.mattrbeck.dingbat.gba-rom "Game Boy Advance ROM" gba)
    $(rom_type com.mattrbeck.dingbat.gb-rom "Game Boy ROM" gb)
    $(rom_type com.mattrbeck.dingbat.gbc-rom "Game Boy Color ROM" gbc cgb sgb)
    $(rom_type com.mattrbeck.dingbat.nds-rom "Nintendo DS ROM" nds)"

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
  <!-- ROMs open from Finder (Open With, a drop on the Dock icon) and land in
       the system's recent documents. The ROM types are dingbat's own; zips
       are Alternate so dingbat never becomes the default for them. -->
  <key>UTExportedTypeDeclarations</key>
  <array>
    ${ROM_TYPES}
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>    <string>Game ROM</string>
      <key>CFBundleTypeRole</key>    <string>Viewer</string>
      <key>LSHandlerRank</key>       <string>Default</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.mattrbeck.dingbat.gba-rom</string>
        <string>com.mattrbeck.dingbat.gb-rom</string>
        <string>com.mattrbeck.dingbat.gbc-rom</string>
        <string>com.mattrbeck.dingbat.nds-rom</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>    <string>Zipped ROM</string>
      <key>CFBundleTypeRole</key>    <string>Viewer</string>
      <key>LSHandlerRank</key>       <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.zip-archive</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then
  "$SIGN" app "$APP"
  # Stapled before it goes in the .dmg, so a copy dragged out of it opens
  # offline too.
  "$SIGN" notarize "$APP"
fi

# Read-only compressed .dmg containing the .app.
DMG="$OUT/dingbat-macos.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "dingbat" -srcfolder "$APP" -ov -format UDZO "$DMG"

if [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then
  "$SIGN" dmg "$DMG"
  "$SIGN" notarize "$DMG"
fi

echo "Built $APP and $DMG"
