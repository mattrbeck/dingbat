#!/bin/bash
# Build everything tools/gbprobe needs: the three headless engine runners, and
# the RGBDS toolchain that assembles the probe ROMs.
#
# Nothing is installed system-wide. Every third-party thing lands under
# <worktree>/.scratch, which is gitignored.
#
#   ./build.sh            # everything
#   ./build.sh roms       # just re-assemble the probe ROMs
#   ./build.sh engines    # just the three runners
#
# Engines, and what each one is:
#   dingbat   this tree, built straight from src/ (dingbat_shot.nim)
#   sameboy   LIJI32/SameBoy as a static lib + our own headless main
#   docboy    Docheinstein/docboy's own devtools/runtakeframebuffer
#
# SameBoy and DocBoy are ORACLES. We run ROMs in them and read the pixels back
# out; no constant and no line of either implementation is copied into dingbat.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRATCH="$ROOT/.scratch"
mkdir -p "$SCRATCH" "$HERE/bin"

RGBDS_VERSION=v1.0.3
DOCBOY_REPO=https://github.com/Docheinstein/docboy
SAMEBOY_REPO=https://github.com/LIJI32/SameBoy

# ---------------------------------------------------------------- rgbds ------
# The release zip carries pre-generated parser sources, so no bison is needed
# (macOS ships bison 2.3, which rgbds' own build refuses).
build_rgbds() {
  if [ -x "$SCRATCH/rgbds/rgbasm" ]; then echo "== rgbds (cached)"; return; fi
  echo "== rgbds $RGBDS_VERSION"
  case "$(uname -s)" in
    Darwin) ASSET=rgbds-macos.zip ;;
    Linux)  ASSET=rgbds-linux-x86_64.tar.xz ;;
    *) echo "no rgbds asset for $(uname -s)"; exit 1 ;;
  esac
  mkdir -p "$SCRATCH/rgbds"
  curl -fsSL -o "$SCRATCH/$ASSET" \
    "https://github.com/gbdev/rgbds/releases/download/$RGBDS_VERSION/$ASSET"
  case "$ASSET" in
    *.zip)    unzip -oq "$SCRATCH/$ASSET" -d "$SCRATCH/rgbds" ;;
    *.tar.xz) tar xf "$SCRATCH/$ASSET" -C "$SCRATCH/rgbds" --strip-components=1 ;;
  esac
  chmod +x "$SCRATCH/rgbds"/rgb* 2>/dev/null || true
}

# --------------------------------------------------------------- sameboy -----
build_sameboy() {
  SAMEBOY="${GBPROBE_SAMEBOY:-$HOME/code/SameBoy}"
  if [ ! -d "$SAMEBOY" ]; then
    SAMEBOY="$SCRATCH/SameBoy"
    [ -d "$SAMEBOY" ] || git clone --depth 1 "$SAMEBOY_REPO" "$SAMEBOY"
  fi
  if [ ! -f "$SAMEBOY/build/lib/libsameboy.a" ]; then
    echo "== sameboy lib"
    make -C "$SAMEBOY" lib -j"$(getconf _NPROCESSORS_ONLN)"
  fi
  # SameBoy has no skip-boot entry point, so this leg needs real boot ROMs.
  # SameBoy's own are in-tree and assemble with the RGBDS we already fetched;
  # they land in .scratch/bootroms so nothing outside the worktree is needed
  # at run time.
  if [ ! -f "$SCRATCH/bootroms/cgb_boot.bin" ]; then
    echo "== sameboy bootroms"
    build_rgbds
    PATH="$SCRATCH/rgbds:$PATH" make -C "$SAMEBOY" bootroms \
      -j"$(getconf _NPROCESSORS_ONLN)"
    mkdir -p "$SCRATCH/bootroms"
    cp "$SAMEBOY"/build/bin/BootROMs/*.bin "$SCRATCH/bootroms/"
  fi
  echo "== sameboy_shot"
  cc -O2 -std=gnu11 -I"$SAMEBOY" -D_GNU_SOURCE -DGB_VERSION='"gbprobe"' \
     "$HERE/sameboy_shot.c" "$SAMEBOY/build/lib/libsameboy.a" \
     -lm -o "$HERE/bin/sameboy_shot"
}

# ---------------------------------------------------------------- docboy -----
# Two things make DocBoy awkward as a harness target, and build.sh handles both:
#
#  1. CGB support is a COMPILE-TIME option (ENABLE_CGB), not a runtime model
#     selector, so DMG and CGB are two separate binaries. There is no
#     revision axis at all — DocBoy models one CGB, not CGB-C/D/E.
#  2. third_party/CMakeLists.txt add_subdirectory()s SDL and nativefiledialog
#     unconditionally, even for a devtools-only build, so a bare checkout will
#     not configure without those (large) submodules. We guard them behind
#     BUILD_SDL_FRONTEND in the scratch checkout.
build_docboy() {
  DOCBOY="$SCRATCH/docboy"
  [ -d "$DOCBOY" ] || git clone --depth 50 "$DOCBOY_REPO" "$DOCBOY"
  (cd "$DOCBOY" && git submodule update --init --depth 1 \
      third_party/args third_party/tui third_party/zlib third_party/libpng >/dev/null)

  # Idempotent guard patch (see note 2 above).
  python3 - "$DOCBOY/third_party/CMakeLists.txt" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if 'if (BUILD_SDL_FRONTEND)' in s:
    raise SystemExit(0)
i, j = s.index('# SDL'), s.index('# Catch2')
mid = s[i:j].rstrip()
body = '\n'.join(('    ' + l) if l.strip() else l for l in mid.split('\n'))
open(p, 'w').write(
    s[:i] + 'if (BUILD_SDL_FRONTEND)\n' + body +
    '\nelse()\n    set(ENABLE_NFD OFF PARENT_SCOPE)\nendif()\n\n' + s[j:])
PY

  # Our own devtool, rather than DocBoy's runtakeframebuffer: see the header
  # comment in docboy_shot.cpp for why (testutils forces ENABLE_TESTS, and the
  # stock tool counts ticks where we want frames).
  cp "$HERE/docboy_shot.cpp" "$DOCBOY/devtools/docboy_shot.cpp"
  if ! grep -q docboy_shot "$DOCBOY/devtools/CMakeLists.txt"; then
    cat >> "$DOCBOY/devtools/CMakeLists.txt" <<'CM'

add_executable(docboy_shot docboy_shot.cpp)
target_link_libraries(docboy_shot PRIVATE docboy utils extra)
CM
  fi

  for m in cgb dmg; do
    [ "$m" = cgb ] && C=ON || C=OFF
    echo "== docboy ($m)"
    cmake -S "$DOCBOY" -B "$DOCBOY/build-$m" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_DEVTOOLS=ON -DBUILD_NOGUI_FRONTEND=ON \
      -DENABLE_CGB=$C -DENABLE_AUDIO=OFF -DENABLE_BOOTROM=OFF >/dev/null
    cmake --build "$DOCBOY/build-$m" --target docboy_shot >/dev/null
    cp "$DOCBOY/build-$m/docboy_shot" "$HERE/bin/docboy_shot_$m"
  done
}

# --------------------------------------------------------------- dingbat -----
build_dingbat() {
  echo "== dingbat_shot"
  nim c -d:release --path:"$ROOT/src" --hints:off --warnings:off \
     -o:"$HERE/bin/dingbat_shot" "$HERE/dingbat_shot.nim"
}

# ------------------------------------------------------------------ roms -----
build_roms() {
  build_rgbds
  echo "== roms"
  "$HERE/mk.sh" scratch_font
  "$HERE/mk.sh" probe_a_statidiom
  "$HERE/mk.sh" probe_b_scxm3
  # probe (c) at the three fine scrolls worth having. SCX=0 is the setting the
  # existing reference frames use; 3 and 7 exist because SCX_FINE_BORROW says
  # the fetch grid's column carries a borrow off the fine scroll and no
  # reference frame in existence exercises that.
  "$HERE/mk.sh" probe_c_arbitrate -DSCXVAL=0
  GBPROBE_OUT=probe_c_arbitrate_scx3 "$HERE/mk.sh" probe_c_arbitrate -DSCXVAL=3
  GBPROBE_OUT=probe_c_arbitrate_scx7 "$HERE/mk.sh" probe_c_arbitrate -DSCXVAL=7
}

case "${1:-all}" in
  roms)    build_roms ;;
  engines) build_dingbat; build_sameboy; build_docboy ;;
  docboy)  build_docboy ;;
  sameboy) build_sameboy ;;
  dingbat) build_dingbat ;;
  all)     build_roms; build_dingbat; build_sameboy; build_docboy ;;
  *) echo "usage: build.sh [all|roms|engines|dingbat|sameboy|docboy]"; exit 2 ;;
esac
echo "ok"
