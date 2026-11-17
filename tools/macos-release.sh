#!/usr/bin/env bash
# Sign and notarize the macOS .app and .dmg on this Mac, with your own
# Developer ID: what CI does once its secrets are set (docs/dev/macos-signing.md).
#
#   tools/macos-release.sh [--dry-run] [--no-notarize] [--version V] [--out DIR] [BINARY|DMG]
#
# BINARY: a -d:macdist build. DMG: an unsigned dingbat-macos.dmg from CI, whose
# binary is bundled again. Neither: builds one, which needs the static
# /opt/homebrew/lib/libSDL3.a (docs/building.md).
#
# Identity: MACOS_SIGN_IDENTITY (SHA-1 or name), else the one Developer ID
# Application identity in your keychains. Notary: MACOS_NOTARY_PROFILE
# (default "dingbat", made by `xcrun notarytool store-credentials dingbat`),
# or the API key variables in .github/scripts/macos-sign.sh.
#
# --dry-run still bundles the unsigned .app and .dmg, but only prints each
# codesign, notarytool, stapler and spctl step.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

dry=0 notarize=1 version="" out="dist/macos" input=""
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) dry=1 ;;
    --no-notarize) notarize=0 ;;
    --version) version=${2:?}; shift ;;
    --out) out=${2:?}; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) input=$1 ;;
  esac
  shift
done

if [ -z "$version" ]; then
  tag=$(git describe --tags --exact-match --match 'v*' 2> /dev/null || true)
  version=${tag:+${tag#v}}
  version=${version:-0.0.0}
fi

if [ -z "${MACOS_SIGN_IDENTITY:-}" ]; then
  ids=$(security find-identity -v -p codesigning | grep '"Developer ID Application: ' || true)
  n=$(printf '%s' "$ids" | grep -c . || true)
  if [ "$n" -eq 1 ]; then
    MACOS_SIGN_IDENTITY=$(awk '{print $2}' <<< "$ids")
    echo "signing as: $(cut -d'"' -f2 <<< "$ids") ($MACOS_SIGN_IDENTITY)"
  elif [ "$n" -eq 0 ] && [ "$dry" = 1 ]; then
    MACOS_SIGN_IDENTITY="Developer ID Application: (none in your keychains yet)"
    echo "no Developer ID Application identity found; continuing the dry run"
  elif [ "$n" -eq 0 ]; then
    echo "no Developer ID Application identity in your keychains (docs/dev/macos-signing.md)" >&2
    exit 1
  else
    echo "more than one Developer ID Application identity; pick yours by SHA-1:" >&2
    echo "$ids" >&2
    echo "  MACOS_SIGN_IDENTITY=<SHA-1> $0 ..." >&2
    exit 1
  fi
fi
export MACOS_SIGN_IDENTITY

if [ "$notarize" = 0 ]; then
  unset MACOS_NOTARY_KEY MACOS_NOTARY_PROFILE
elif [ -z "${MACOS_NOTARY_KEY:-}" ]; then
  export MACOS_NOTARY_PROFILE=${MACOS_NOTARY_PROFILE:-dingbat}
fi
if [ "$dry" = 1 ]; then export DRY_RUN=1; fi

mkdir -p "$out"
bin="$out/dingbat_dist"
case $input in
  "")
    [ -f /opt/homebrew/lib/libSDL3.a ] || {
      echo "no /opt/homebrew/lib/libSDL3.a: pass a binary or CI's .dmg instead (docs/building.md)" >&2
      exit 1
    }
    MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.0} \
      nim c -d:release -d:macdist --hints:off -o:"$bin" src/dingbat.nim
    ;;
  *.dmg)
    mnt=$(mktemp -d)
    hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint "$mnt" "$input"
    cp "$mnt/dingbat.app/Contents/MacOS/dingbat" "$bin"
    hdiutil detach -quiet "$mnt"
    rmdir "$mnt"
    xattr -c "$bin"
    ;;
  *)
    cp "$input" "$bin"
    ;;
esac

.github/scripts/make-macos-app.sh "$bin" "$version" "$out"
rm -f "$bin"
if [ "$dry" = 1 ]; then echo "dry run: nothing was signed or submitted"; fi
