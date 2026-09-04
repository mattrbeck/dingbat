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
#   docboy    Docheinstein/docboy + our own devtools/docboy_shot.cpp
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
#  1. CGB support is a compile-time option (ENABLE_CGB), so DMG and CGB are
#     two binaries and there is no revision axis.
#  2. third_party/CMakeLists.txt add_subdirectory()s SDL and nativefiledialog
#     unconditionally, so a bare checkout will not configure without those
#     submodules; the scratch checkout guards them behind BUILD_SDL_FRONTEND.
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

  # Our own devtool rather than DocBoy's runtakeframebuffer (see docboy_shot.cpp).
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
  # probe (c) at SCX 0 (the setting the reference frames use), 3 and 7.
  "$HERE/mk.sh" probe_c_arbitrate -DSCXVAL=0
  GBPROBE_OUT=probe_c_arbitrate_scx3 "$HERE/mk.sh" probe_c_arbitrate -DSCXVAL=3
  GBPROBE_OUT=probe_c_arbitrate_scx7 "$HERE/mk.sh" probe_c_arbitrate -DSCXVAL=7
  # Photograph pages (README "Photograph pages"): the WY re-check on LCDC.5,
  # the per-register CGB write latencies, the OAM-DMA scan.
  GBPROBE_OUT=probe_g_wy0 "$HERE/mk.sh" probe_g_wyrecheck -DVARIANT=0
  GBPROBE_OUT=probe_g_wy1 "$HERE/mk.sh" probe_g_wyrecheck -DVARIANT=1
  GBPROBE_OUT=probe_h_scx   "$HERE/mk.sh" probe_h_latency -DPAGE=0
  GBPROBE_OUT=probe_h_scy   "$HERE/mk.sh" probe_h_latency -DPAGE=1
  GBPROBE_OUT=probe_h_wx    "$HERE/mk.sh" probe_h_latency -DPAGE=2
  # BGP is dead on a CGB running a CGB-flagged cart: compatibility-mode header.
  GBPROBE_CGB=0 GBPROBE_OUT=probe_h_bgp "$HERE/mk.sh" probe_h_latency -DPAGE=3
  GBPROBE_OUT=probe_h_lcdc4 "$HERE/mk.sh" probe_h_latency -DPAGE=4
  GBPROBE_OUT=probe_h_lcdc3 "$HERE/mk.sh" probe_h_latency -DPAGE=5
  "$HERE/mk.sh" probe_i_oamdma
  # probe (j): the window restart's cost, and the halt wake's phase on an
  # ordinary line against the LY 153 -> 0 snapback.
  "$HERE/mk.sh" probe_j_winrestart
  "$HERE/mk.sh" probe_j_haltlead
  # probe (k): the four pages that need a whole sweep before they draw.
  "$HERE/mk.sh" probe_k_serialdiv
  "$HERE/mk.sh" probe_k_lcdon
  "$HERE/mk.sh" probe_k_oamclass
  # hwprobe row 18: one ROM per arming regime, plus the SCX axis.
  GBPROBE_OUT=probe_k_winglitch_a0 "$HERE/mk.sh" probe_k_winglitch -DARM=0 -DAXIS=0
  GBPROBE_OUT=probe_k_winglitch_a1 "$HERE/mk.sh" probe_k_winglitch -DARM=1 -DAXIS=0
  GBPROBE_OUT=probe_k_winglitch_a2 "$HERE/mk.sh" probe_k_winglitch -DARM=2 -DAXIS=0
  GBPROBE_OUT=probe_k_winglitch_scx "$HERE/mk.sh" probe_k_winglitch -DARM=1 -DAXIS=1
}

# The photograph pages' dingbat predictions, one PNG per page and model,
# under expected/ -- what a hardware photo is compared against.
#
# Frame count per page: the probe (g), (h), (i) and (j) pages redraw the whole
# screen every frame, so any count past the first does; the probe (k) pages run
# a SWEEP first (up to 96 LCD enables) and only then draw themselves once, so
# each carries the count its sweep needs plus headroom.
build_expected() {
  build_dingbat
  mkdir -p "$HERE/expected"
  for entry in probe_g_wy0:40 probe_g_wy1:40 probe_h_scx:40 probe_h_scy:40 \
               probe_h_wx:40 probe_h_bgp:40 probe_h_lcdc4:40 probe_h_lcdc3:40 \
               probe_i_oamdma:40 probe_j_winrestart:40 probe_j_haltlead:40 \
               probe_k_winglitch_a0:40 probe_k_winglitch_a1:40 \
               probe_k_winglitch_a2:40 probe_k_winglitch_scx:40 \
               probe_k_serialdiv:60 probe_k_oamclass:100 probe_k_lcdon:200; do
    rom="${entry%%:*}"
    frames="${entry##*:}"
    for model in dmg cgbc cgbd agb; do
      "$HERE/bin/dingbat_shot" "$HERE/$rom.gb" "$model" "$frames" \
                               "$HERE/expected/$rom.$model.ppm"
      python3 "$HERE/ppm2png.py" "$HERE/expected/$rom.$model.ppm" \
                                 "$HERE/expected/$rom.$model.png"
      rm "$HERE/expected/$rom.$model.ppm"
    done
  done
}

case "${1:-all}" in
  roms)    build_roms ;;
  engines) build_dingbat; build_sameboy; build_docboy ;;
  docboy)  build_docboy ;;
  sameboy) build_sameboy ;;
  dingbat) build_dingbat ;;
  expected) build_roms; build_expected ;;
  all)     build_roms; build_dingbat; build_sameboy; build_docboy ;;
  *) echo "usage: build.sh [all|roms|engines|dingbat|sameboy|docboy|expected]"; exit 2 ;;
esac
echo "ok"
