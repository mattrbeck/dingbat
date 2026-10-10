#!/bin/sh
# Build SDL 3 from its release source as a static library only and install it
# under PREFIX: the desktop builds link libSDL3.a so their binaries carry no
# SDL dependency (Homebrew's sdl3 and SDL's mingw devel package ship no static
# library, and Ubuntu 22.04 has no SDL 3 package at all).
#
#   .github/scripts/build-sdl3.sh PREFIX            native
#   .github/scripts/build-sdl3.sh PREFIX --mingw    Windows x64, mingw-w64
#
# SDL3_VERSION picks the release (default: the sdl3 package's, see
# dingbat.nimble). Any further arguments go to cmake. The camera subsystem is
# left out: dingbat has no use for it, and on macOS it alone needs
# AVFoundation and CoreMedia.
set -eu

VER=${SDL3_VERSION:-3.4.16}
PREFIX=${1:?usage: build-sdl3.sh PREFIX [--mingw] [cmake args...]}
shift
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
src="$work/SDL3-$VER"

"$here/retry.sh" 3 curl -fsSL -o "$work/sdl3.tar.gz" \
  "https://github.com/libsdl-org/SDL/releases/download/release-$VER/SDL3-$VER.tar.gz"
tar xzf "$work/sdl3.tar.gz" -C "$work"

toolchain=""
if [ "${1:-}" = "--mingw" ]; then
  shift
  toolchain="-DCMAKE_TOOLCHAIN_FILE=$src/build-scripts/cmake-toolchain-mingw64-x86_64.cmake"
fi

# shellcheck disable=SC2086
cmake -S "$src" -B "$work/build" $toolchain \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DSDL_STATIC=ON -DSDL_SHARED=OFF -DSDL_CAMERA=OFF \
  -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF "$@"
cmake --build "$work/build" --parallel
cmake --install "$work/build"
rm -rf "$work"
test -f "$PREFIX/lib/libSDL3.a"
test -f "$PREFIX/include/SDL3/SDL.h"
