#!/usr/bin/env bash
# Sign and notarize the macOS release; make-macos-app.sh calls it when
# MACOS_SIGN_IDENTITY is set.
#
#   macos-sign.sh app <dingbat.app>     hardened runtime, dingbat.entitlements
#   macos-sign.sh dmg <dingbat.dmg>     the disk image's own signature
#   macos-sign.sh notarize <app|dmg>    submit, wait, staple, assess
#
# Environment:
#   MACOS_SIGN_IDENTITY   Developer ID Application identity (SHA-1 or name);
#                         "-" signs ad hoc, for local checks (never notarized)
#   MACOS_SIGN_KEYCHAIN   keychain holding it (default: the search list)
#   Notary credentials, either (notarize is a no-op with neither):
#     MACOS_NOTARY_KEY, MACOS_NOTARY_KEY_ID, MACOS_NOTARY_ISSUER
#                         App Store Connect API key: .p8 path, key ID, issuer ID
#     MACOS_NOTARY_PROFILE
#                         a `xcrun notarytool store-credentials` profile
#   DRY_RUN=1             print codesign/notarytool/stapler/spctl, run nothing
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ID=${MACOS_SIGN_IDENTITY:?MACOS_SIGN_IDENTITY not set}

run() {
  echo "+ $*"
  [ "${DRY_RUN:-}" = 1 ] || "$@"
}

sign() {  # sign <path> [codesign args...]
  local path=$1
  shift
  local args=(--force --sign "$ID")
  [ "$ID" = "-" ] || args+=(--timestamp)
  [ -z "${MACOS_SIGN_KEYCHAIN:-}" ] || args+=(--keychain "$MACOS_SIGN_KEYCHAIN")
  run codesign "${args[@]}" "$@" "$path"
}

notary_auth() {
  if [ -n "${MACOS_NOTARY_KEY:-}" ]; then
    auth=(--key "$MACOS_NOTARY_KEY" --key-id "${MACOS_NOTARY_KEY_ID:?}"
          --issuer "${MACOS_NOTARY_ISSUER:?}")
  elif [ -n "${MACOS_NOTARY_PROFILE:-}" ]; then
    auth=(--keychain-profile "$MACOS_NOTARY_PROFILE")
  else
    return 1
  fi
}

# Gatekeeper's verdict. An unnotarized Developer ID signature is rejected, so
# before notarization this is informational only.
assess() {  # assess <path> fatal|info
  local how=(--assess -vv)
  case $1 in
    *.dmg) how+=(--type open --context context:primary-signature) ;;
    *) how+=(--type execute) ;;
  esac
  if [ "$2" = fatal ]; then run spctl "${how[@]}" "$1"
  else run spctl "${how[@]}" "$1" || echo "(not notarized yet: rejection expected)"
  fi
}

cmd=${1:?usage: macos-sign.sh app|dmg|notarize PATH}
target=${2:?usage: macos-sign.sh app|dmg|notarize PATH}

case $cmd in
  app)
    # Nested code before the bundle that seals it (none today: SDL is static).
    while IFS= read -r -d '' f; do
      sign "$f" --options runtime
    done < <(find "$target/Contents" -type f \( -name '*.dylib' -o -perm -u+x \) \
               ! -path "$target/Contents/MacOS/dingbat" -print0)
    sign "$target" --options runtime --entitlements "$here/dingbat.entitlements"
    run codesign --verify --deep --strict --verbose=2 "$target"
    if [ "${DRY_RUN:-}" != 1 ]; then
      [[ $(codesign -dv "$target" 2>&1) == *flags=*runtime* ]] \
        || { echo "error: $target lacks the hardened runtime" >&2; exit 1; }
    fi
    assess "$target" info
    ;;
  dmg)
    sign "$target"
    run codesign --verify --strict --verbose=2 "$target"
    ;;
  notarize)
    if [ "$ID" = "-" ]; then echo "ad hoc signature: not notarizing"; exit 0; fi
    if ! notary_auth; then echo "no notary credentials: not notarizing"; exit 0; fi
    submit=$target
    if [ -d "$target" ]; then
      # notarytool takes a .zip, .pkg or .dmg; the ticket covers the app inside.
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      submit="$work/$(basename "$target").zip"
      run ditto -c -k --keepParent "$target" "$submit"
    fi
    if [ "${DRY_RUN:-}" = 1 ]; then
      run xcrun notarytool submit "$submit" "${auth[@]}" --wait --timeout 30m
    else
      echo "+ xcrun notarytool submit $submit (credentials elided) --wait"
      out=$(xcrun notarytool submit "$submit" "${auth[@]}" --wait --timeout 30m \
              --output-format json) || true
      echo "$out"
      status=$(plutil -extract status raw -o - - <<< "$out" 2> /dev/null || echo unknown)
      if [ "$status" != Accepted ]; then
        sub=$(plutil -extract id raw -o - - <<< "$out" 2> /dev/null || true)
        [ -z "$sub" ] || xcrun notarytool log "$sub" "${auth[@]}" || true
        echo "error: notarization of $target: $status" >&2
        exit 1
      fi
    fi
    run xcrun stapler staple "$target"
    run xcrun stapler validate "$target"
    assess "$target" fatal
    ;;
  *)
    echo "usage: macos-sign.sh app|dmg|notarize PATH" >&2
    exit 2
    ;;
esac
