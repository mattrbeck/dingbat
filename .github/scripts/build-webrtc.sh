#!/bin/sh
# Build the desktop app's online-link stack as one static library under
# PREFIX, as ios/build-webrtc.sh does for the phone: libdatachannel (data
# channels only: no media, no WebSocket) over libjuice (ICE) and usrsctp
# (SCTP), with mbedTLS for DTLS. The signaling socket (src/dingbat/frontend/
# rtc_shim.c) uses the same mbedTLS for its verified TLS.
#
#   .github/scripts/build-webrtc.sh PREFIX            native (macOS, Linux)
#   .github/scripts/build-webrtc.sh PREFIX --mingw    Windows x64, mingw-w64
#
# Installs PREFIX/lib/libwebrtcdc.a, PREFIX/include/rtc/rtc.h and the mbedTLS
# headers. Licences: libdatachannel and libjuice MPL-2.0, usrsctp
# BSD-3-Clause, mbedTLS Apache-2.0 (THIRD_PARTY_NOTICES.md).
set -eu

LIBDATACHANNEL_TAG=v0.24.6
MBEDTLS_TAG=v3.6.7

PREFIX=${1:?usage: build-webrtc.sh PREFIX [--mingw]}
shift
here=$(cd "$(dirname "$0")" && pwd)
work=${WEBRTC_WORK:-$(mktemp -d)}
mkdir -p "$work" "$PREFIX"
PREFIX=$(cd "$PREFIX" && pwd)

toolchain=""
mingw=0
if [ "${1:-}" = "--mingw" ]; then
  shift
  mingw=1
  cat >"$work/mingw.cmake" <<'EOF'
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER x86_64-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++)
set(CMAKE_RC_COMPILER x86_64-w64-mingw32-windres)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
EOF
  toolchain="-DCMAKE_TOOLCHAIN_FILE=$work/mingw.cmake"
fi

fetch() {
  # $1 = dir, $2 = url, $3 = tag
  if [ ! -d "$work/$1/.git" ]; then
    "$here/retry.sh" 3 git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$3" --recurse-submodules \
      --shallow-submodules "$2" "$work/$1"
  fi
}
fetch libdatachannel https://github.com/paullouisageneau/libdatachannel.git "$LIBDATACHANNEL_TAG"
fetch mbedtls https://github.com/Mbed-TLS/mbedtls.git "$MBEDTLS_TAG"
# libdatachannel's DTLS transport uses the SRTP extension API even without
# media; mbedTLS leaves it out by default.
python3 "$work/mbedtls/scripts/config.py" -f "$work/mbedtls/include/mbedtls/mbedtls_config.h" set MBEDTLS_SSL_DTLS_SRTP

stage="$work/prefix"
mkdir -p "$stage"
gen=""
command -v ninja >/dev/null 2>&1 && gen="-G Ninja"
# shellcheck disable=SC2086
common="$gen $toolchain -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_INSTALL_PREFIX=$stage -DCMAKE_PREFIX_PATH=$stage \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_FIND_ROOT_PATH=$stage"
case "$(uname -s)" in
  Darwin) common="$common -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.0}" ;;
esac
log="$work/build.log"
# shellcheck disable=SC2086
cmake -S "$work/mbedtls" -B "$work/build-mbedtls" $common \
  -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DMBEDTLS_FATAL_WARNINGS=OFF >>"$log" 2>&1 || { tail -40 "$log"; exit 1; }
cmake --build "$work/build-mbedtls" --target install --parallel >>"$log" 2>&1 || { tail -40 "$log"; exit 1; }
# shellcheck disable=SC2086
cmake -S "$work/libdatachannel" -B "$work/build-libdatachannel" $common \
  -DUSE_MBEDTLS=ON -DNO_MEDIA=ON -DNO_WEBSOCKET=ON -DNO_EXAMPLES=ON -DNO_TESTS=ON >>"$log" 2>&1 || { tail -40 "$log"; exit 1; }
cmake --build "$work/build-libdatachannel" --target install --parallel >>"$log" 2>&1 || { tail -40 "$log"; exit 1; }

libs=$(find "$stage/lib" "$stage/lib64" -name '*.a' 2>/dev/null | sort)
mkdir -p "$PREFIX/lib" "$PREFIX/include"
out="$PREFIX/lib/libwebrtcdc.a"
rm -f "$out"
if [ "$(uname -s)" = Darwin ] && [ $mingw = 0 ]; then
  # shellcheck disable=SC2086
  libtool -static -o "$out" $libs
else
  ar=ar
  [ $mingw = 1 ] && ar=x86_64-w64-mingw32-ar
  { echo "CREATE $out"; for l in $libs; do echo "ADDLIB $l"; done; echo SAVE; echo END; } | $ar -M
fi
cp -R "$stage/include/rtc" "$stage/include/mbedtls" "$stage/include/psa" "$PREFIX/include/"
echo "$(echo $libs | wc -w | tr -d ' ') libraries -> $out"
test -f "$out"
test -f "$PREFIX/include/rtc/rtc.h"
