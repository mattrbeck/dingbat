#!/bin/sh
# Build both wasm cores and serve this checkout's web/ over HTTPS on the LAN,
# for trying DS games on a phone or another Mac (docs/nds/web.md).
#
#   tools/serve_nds_dev.sh            # build, then serve https://<LAN IP>:8443/
#   tools/serve_nds_dev.sh --no-build # serve what is built
#   PORT=9443 IFACE=en1 tools/serve_nds_dev.sh
#
# HTTPS because iOS runs plain-http LAN pages without the JIT (and without a
# secure context there is no AudioWorklet). The certificate is self-signed
# for the current LAN address and is regenerated when the address changes;
# accept it once on each device. Needs emsdk on PATH (emcc) for the build.
set -e
cd "$(dirname "$0")/.."
PORT="${PORT:-8443}"
IFACE="${IFACE:-en0}"
CERTS="${DINGBAT_DEV_CERTS:-$HOME/.cache/dingbat-dev-certs}"
NIMCACHE="${DINGBAT_NIMCACHE:-$HOME/.cache/dingbat-nimcache}"

ip=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)
if [ -z "$ip" ]; then
  echo "no address on $IFACE (set IFACE=...)" >&2
  exit 1
fi

if [ "$1" != "--no-build" ]; then
  command -v emcc >/dev/null 2>&1 || { echo "emcc not on PATH (source emsdk_env.sh)" >&2; exit 1; }
  echo "building web/em.{js,wasm} (GB/GBA)..."
  nim c -d:emscripten --hints:off --warnings:off --nimcache:"$NIMCACHE/em" src/dingbat_wasm.nim
  echo "building web/nds/nds.{js,wasm} (DS)..."
  nim c -d:emscripten --hints:off --warnings:off --nimcache:"$NIMCACHE/nds" src/dingbat_nds_wasm.nim
fi

mkdir -p "$CERTS"
cert="$CERTS/$ip.pem"
key="$CERTS/$ip.key"
if [ ! -f "$cert" ] || [ ! -f "$key" ]; then
  echo "making a self-signed certificate for $ip..."
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout "$key" -out "$cert" -subj "/CN=dingbat dev $ip" \
    -addext "subjectAltName=IP:$ip,DNS:localhost,IP:127.0.0.1" \
    -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1
fi

echo
echo "  https://$ip:$PORT/          (the app; accept the certificate once)"
echo "  https://$ip:$PORT/nds.html  (the DS dev page)"
echo
exec python3 web/serve.py --dev --https --host 0.0.0.0 --port "$PORT" --cert "$cert" --key "$key"
