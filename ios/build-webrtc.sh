#!/bin/sh
# Builds the WebRTC data-channel stack the iOS app links for online link
# play (the web build's WebRTC DataChannel, so an iPhone and a browser can
# trade): libdatachannel (data channels only: no media, no WebSocket) over
# libjuice (ICE) and usrsctp (SCTP), with mbedTLS for DTLS. Static, per
# platform, into the same lib/ the core uses:
#
#   ios/lib/iphoneos/libwebrtcdc.a          arm64 device
#   ios/lib/iphonesimulator/libwebrtcdc.a   arm64 simulator
#   ios/lib/include/rtc/rtc.h               the C API
#
# Sources are fetched at pinned tags into ios/deps (gitignored). Licences:
# libdatachannel and libjuice MPL-2.0, usrsctp BSD-3-Clause, mbedTLS
# Apache-2.0 (THIRD_PARTY_NOTICES.md).
#
# Usage: ios/build-webrtc.sh [device|sim]
set -eu

LIBDATACHANNEL_TAG=v0.24.6
MBEDTLS_TAG=v3.6.7

REPO=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DEPS=${DEPS:-$REPO/ios/deps}
OUT=${OUT:-$REPO/ios/lib}
MINVER=16.0
ONLY=${1:-all}

mkdir -p "$DEPS"
fetch() {
  # $1 = dir, $2 = url, $3 = tag
  if [ ! -d "$DEPS/$1/.git" ]; then
    git clone --quiet --depth 1 --branch "$3" --recurse-submodules --shallow-submodules "$2" "$DEPS/$1"
  fi
}
fetch libdatachannel https://github.com/paullouisageneau/libdatachannel.git "$LIBDATACHANNEL_TAG"
fetch mbedtls https://github.com/Mbed-TLS/mbedtls.git "$MBEDTLS_TAG"
# libdatachannel's DTLS transport uses the SRTP extension API even without
# media; mbedTLS leaves it out by default.
python3 "$DEPS/mbedtls/scripts/config.py" -f "$DEPS/mbedtls/include/mbedtls/mbedtls_config.h" set MBEDTLS_SSL_DTLS_SRTP

build_platform() {
  # $1 = sdk (iphoneos | iphonesimulator)
  B="$DEPS/build/$1"
  P="$B/prefix"
  mkdir -p "$B"
  common="-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=$1 -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$MINVER -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_PREFIX=$P -DCMAKE_PREFIX_PATH=$P \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_FIND_ROOT_PATH=$P \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH"
  # shellcheck disable=SC2086
  cmake -S "$DEPS/mbedtls" -B "$B/mbedtls" $common \
    -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DMBEDTLS_FATAL_WARNINGS=OFF >>"$B/build.log" 2>&1 || { tail -40 "$B/build.log"; exit 1; }
  cmake --build "$B/mbedtls" --target install >>"$B/build.log" 2>&1 || { tail -40 "$B/build.log"; exit 1; }
  # shellcheck disable=SC2086
  cmake -S "$DEPS/libdatachannel" -B "$B/libdatachannel" $common \
    -DUSE_MBEDTLS=ON -DNO_MEDIA=ON -DNO_WEBSOCKET=ON -DNO_EXAMPLES=ON -DNO_TESTS=ON >>"$B/build.log" 2>&1 || { tail -40 "$B/build.log"; exit 1; }
  cmake --build "$B/libdatachannel" --target install >>"$B/build.log" 2>&1 || { tail -40 "$B/build.log"; exit 1; }
  mkdir -p "$OUT/$1" "$OUT/include/rtc"
  libs=$(find "$P/lib" -name '*.a' | sort)
  # shellcheck disable=SC2086
  libtool -static -o "$OUT/$1/libwebrtcdc.a" $libs 2>>"$B/build.log" 2>&1 || { tail -40 "$B/build.log"; exit 1; }
  cp "$P/include/rtc/rtc.h" "$P/include/rtc/version.h" "$OUT/include/rtc/"
  echo "$1: $(echo $libs | wc -w | tr -d ' ') libraries -> $OUT/$1/libwebrtcdc.a"
}

case "$ONLY" in
  device) build_platform iphoneos ;;
  sim)    build_platform iphonesimulator ;;
  all)    build_platform iphoneos; build_platform iphonesimulator ;;
  *) echo "usage: $0 [device|sim]" >&2; exit 2 ;;
esac
