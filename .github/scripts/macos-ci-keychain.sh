#!/usr/bin/env bash
# CI: put the Developer ID certificate and the notary API key where
# macos-sign.sh finds them, exporting its variables through $GITHUB_ENV.
# Without MACOS_CERT_P12 it does nothing and the build stays unsigned.
#
#   macos-ci-keychain.sh setup      (env: the secrets, see docs/dev/macos-signing.md)
#   macos-ci-keychain.sh cleanup    delete the keychain and the key file
set -euo pipefail

kc="$RUNNER_TEMP/dingbat-signing.keychain-db"
p8="$RUNNER_TEMP/dingbat-notary.p8"

if [ "${1:-}" = cleanup ]; then
  if [ -f "$kc" ]; then security delete-keychain "$kc"; fi
  rm -f "$p8"
  exit 0
fi

if [ -z "${MACOS_CERT_P12:-}" ]; then
  echo "::notice::no MACOS_CERT_P12 secret: the macOS build stays unsigned"
  exit 0
fi

# A throwaway keychain, never the runner's login one: random password,
# unlocked for the job, first in the search list so codesign finds the key.
pw=$(openssl rand -base64 24)
security create-keychain -p "$pw" "$kc"
security set-keychain-settings -lut 21600 "$kc"
security unlock-keychain -p "$pw" "$kc"
p12="$RUNNER_TEMP/dingbat-cert.p12"
base64 --decode <<< "$MACOS_CERT_P12" > "$p12"
security import "$p12" -k "$kc" -P "${MACOS_CERT_PASSWORD:-}" -f pkcs12 -T /usr/bin/codesign
rm -f "$p12"
# The intermediate, in case the .p12 was exported without it.
ca="$RUNNER_TEMP/DeveloperIDG2CA.cer"
if "$(dirname "$0")/retry.sh" 3 curl -fsSL -o "$ca" \
     https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer; then
  security import "$ca" -k "$kc" || true
fi
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$kc" > /dev/null
# shellcheck disable=SC2046
security list-keychains -d user -s "$kc" $(security list-keychains -d user | tr -d '"')

id=$(security find-identity -v -p codesigning "$kc" | awk '/"Developer ID Application: /{print $2; exit}')
if [ -z "$id" ]; then
  echo "::error::MACOS_CERT_P12 holds no Developer ID Application identity"
  security find-identity -v -p codesigning "$kc"
  exit 1
fi
{
  echo "MACOS_SIGN_IDENTITY=$id"
  echo "MACOS_SIGN_KEYCHAIN=$kc"
} >> "$GITHUB_ENV"
echo "signing with $id"

if [ -n "${MACOS_NOTARY_KEY_P8:-}" ] && [ -n "${MACOS_NOTARY_KEY_ID:-}" ] \
     && [ -n "${MACOS_NOTARY_ISSUER:-}" ]; then
  base64 --decode <<< "$MACOS_NOTARY_KEY_P8" > "$p8"
  {
    echo "MACOS_NOTARY_KEY=$p8"
    echo "MACOS_NOTARY_KEY_ID=$MACOS_NOTARY_KEY_ID"
    echo "MACOS_NOTARY_ISSUER=$MACOS_NOTARY_ISSUER"
  } >> "$GITHUB_ENV"
else
  echo "::warning::no notary API key secrets: signed, not notarized"
fi
