#!/usr/bin/env bash
# Build the docboy and dingbat headless GB/GBC runners for differential testing.
#
# Prerequisites, all outside this repo (ROMs and boot ROMs must never be
# committed here):
#   $GBDIFF_DOCBOY   a docboy checkout WITH SUBMODULES, default ~/code/docboy
#                    git clone https://github.com/Docheinstein/docboy --recurse-submodules
#   <bootromdir>/{dmg,cgb}_boot.bin   passed to the runners at run time
#
# Usage: tools/gbdiff/build.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=$PWD
DOCBOY=${GBDIFF_DOCBOY:-$HOME/code/docboy}

if [ ! -d "$DOCBOY/src/docboy" ]; then
  echo "no docboy checkout at $DOCBOY (set GBDIFF_DOCBOY)" >&2
  exit 1
fi
if [ ! -f "$DOCBOY/third_party/SDL/CMakeLists.txt" ]; then
  echo "docboy submodules are not checked out; run:" >&2
  echo "  git -C $DOCBOY submodule update --init --recursive" >&2
  exit 1
fi

# The runner is added to docboy's tree as an extra frontend rather than
# compiled standalone against libdocboy.a. docboy sets ENABLE_CGB, ENABLE_CGB,
# ENABLE_BOOTROM and friends as PUBLIC compile definitions on the `docboy`
# target, and several of them change struct layouts; a standalone compile that
# got one of them wrong would link cleanly and then read garbage. Inheriting
# them from the target it links against makes that class of mistake impossible.
echo "== staging runner into $DOCBOY"
mkdir -p "$DOCBOY/src/frontend/gbdiff"
cp "$REPO/tools/gbdiff/docboy_gb_runner.cpp" "$DOCBOY/src/frontend/gbdiff/main.cpp"
cat >"$DOCBOY/src/frontend/gbdiff/CMakeLists.txt" <<'EOF'
add_executable(docboy-gbdiff)
target_sources(docboy-gbdiff PRIVATE main.cpp)
target_link_libraries(docboy-gbdiff PRIVATE docboy utils extra)
EOF
if ! grep -q 'frontend/gbdiff\|add_subdirectory(gbdiff)' "$DOCBOY/src/frontend/CMakeLists.txt"; then
  printf '\nif (BUILD_NOGUI_FRONTEND)\n    add_subdirectory(gbdiff)\nendif()\n' \
    >>"$DOCBOY/src/frontend/CMakeLists.txt"
fi

# docboy's third_party/CMakeLists.txt adds SDL and nativefiledialog
# unconditionally, even for a NoGUI build, and nfd is Objective-C on macOS
# while docboy's project() never enables that language. Enabling it from the
# outside leaves docboy's own CMake untouched.
OBJC_SHIM=$DOCBOY/.gbdiff-objc.cmake
if [ "$(uname)" = "Darwin" ]; then
  printf 'enable_language(OBJC)\nenable_language(OBJCXX)\n' >"$OBJC_SHIM"
else
  : >"$OBJC_SHIM"
fi

# ENABLE_RTC_SYSTEM_TIME defaults ON and seeds the MBC3 clock from the wall
# clock, which would make every run of an RTC title differ; OFF.
# ENABLE_AUDIO off: nothing here reads samples.
build_one() {
  local slot=$1 cgb=$2
  echo "== docboy-gbdiff ($slot)"
  local log="$DOCBOY/gbdiff-build-$slot.log"
  if ! cmake -S "$DOCBOY" -B "$DOCBOY/build-gbdiff-$slot" -G Ninja \
      -DCMAKE_PROJECT_TOP_LEVEL_INCLUDES="$OBJC_SHIM" \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_NOGUI_FRONTEND=ON \
      -DENABLE_BOOTROM=ON \
      -DENABLE_CGB="$cgb" \
      -DENABLE_AUDIO=OFF \
      -DENABLE_RTC_SYSTEM_TIME=OFF \
      -DENABLE_ASSERTS=OFF >"$log" 2>&1; then
    echo "cmake configure failed for $slot, see $log" >&2
    tail -20 "$log" >&2
    exit 1
  fi
  if ! ninja -C "$DOCBOY/build-gbdiff-$slot" docboy-gbdiff >>"$log" 2>&1; then
    echo "build failed for $slot, see $log" >&2
    tail -30 "$log" >&2
    exit 1
  fi
  cp "$DOCBOY/build-gbdiff-$slot/docboy-gbdiff" "$REPO/tools/gbdiff/docboy_gb_runner_$slot"
  echo "   -> tools/gbdiff/docboy_gb_runner_$slot"
}

build_one dmg OFF
build_one cgb ON

# dingbat's side is tools/gbfuzz/dingbat_gb_nav, which has the same CLI
# contract and boot-ROM handling.
echo "== dingbat_gb_nav"
nim c -d:release --path:src --hints:off \
  --nimcache:"$(mktemp -d)" \
  -o:tools/gbfuzz/dingbat_gb_nav tools/gbfuzz/dingbat_gb_nav.nim

echo "all built"
