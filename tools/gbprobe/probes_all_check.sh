#!/bin/bash
# The combined cart's verification gate: drive probes_all.gb's menu to each of
# the eighteen pages and prove the page renders exactly what its own .gb
# renders, on all four models.
#
#   ./probes_all_check.sh [page-tag ...]
#
# For each page: hold DOWN once per menu row, press A, let the page run its
# own frame count (build.sh's expected/ counts), and compare the frame with
# expected/<standalone>.<model>.png byte for byte. Any difference is a state
# leak from the launcher into the page and is the launcher's bug, not the
# page's.
#
# The BGP page is the exception: it is the one page whose own .gb carries NO
# CGB flag, and a cart has only one flag. It is checked against the compat-
# flagged build of the same cart (GBPROBE_CGB=0 ./build.sh probes_all), which
# is what proves the deviation is the header byte and nothing else.
#
# GBPROBE_CHECK_VIA=1 runs every page a second way: through page 56 (OAM class,
# the page that leaves the most behind -- OAM rewritten, WRAM results, a DMA
# trampoline in HRAM) and back out with START first. Same expected PNGs, so it
# is the launcher's return path that is being checked.
#
# Needs bin/dingbat_shot (./build.sh dingbat) and expected/ (./build.sh expected).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SHOT="$HERE/bin/dingbat_shot"
ROM="$HERE/probes_all.gb"
OUT="${GBPROBE_CHECK_OUT:-$HERE/build/probes_all_check}"
MODELS="${GBPROBE_CHECK_MODELS:-dmg cgbc cgbd agb}"
VIA="${GBPROBE_CHECK_VIA:-}"

COMPAT="$HERE/probes_all_compat.gb"

[ -x "$SHOT" ] || { echo "no $SHOT -- run ./build.sh dingbat"; exit 2; }
[ -f "$ROM" ]  || { echo "no $ROM -- run ./build.sh probes_all"; exit 2; }
[ -f "$COMPAT" ] || GBPROBE_CGB=0 "$HERE/build.sh" probes_all >/dev/null
mkdir -p "$OUT"

# Menu order, one row per line: row index, the standalone .gb it must match,
# and that page's frame count from build.sh's expected/ list.
PAGES="\
0:probe_g_wy0:40
1:probe_g_wy1:40
2:probe_h_scx:40
3:probe_h_scy:40
4:probe_h_wx:40
5:probe_h_bgp:40
6:probe_h_lcdc4:40
7:probe_h_lcdc3:40
8:probe_i_oamdma:40
9:probe_j_winrestart:40
10:probe_j_haltlead:40
11:probe_k_serialdiv:60
12:probe_k_winglitch_a0:40
13:probe_k_winglitch_a1:40
14:probe_k_winglitch_a2:40
15:probe_k_winglitch_scx:40
16:probe_k_lcdon:200
17:probe_k_oamclass:100"

fail=0
printf '%-22s %s\n' "page" "$MODELS"
while IFS=: read -r row name frames; do
  [ -n "$row" ] || continue
  if [ $# -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$name"; then continue; fi

  # InitVideo clears both VRAM banks a byte at a time, so the menu takes about
  # ten frames to come up (cold, and again on every return); presses before
  # that are simply not read. Then one DOWN edge per row, and A.
  script="20"
  if [ -n "$VIA" ]; then
    # Warm up on the last entry, page 56, and come back out on START; then the
    # cursor is on row 17 and the target is that many UPs away.
    i=0
    while [ "$i" -lt 17 ]; do script="$script,2:d,2"; i=$((i + 1)); done
    script="$script,2:a,120,4:s,20"
    i="$row"
    while [ "$i" -lt 17 ]; do script="$script,2:u,2"; i=$((i + 1)); done
  else
    i=0
    while [ "$i" -lt "$row" ]; do script="$script,2:d,2"; i=$((i + 1)); done
  fi
  script="$script,2:a"

  # Page 33 comes off the compat-flagged cart (see the header note).
  if [ "$name" = probe_h_bgp ]; then rom="$COMPAT"; else rom="$ROM"; fi

  line=""
  for model in $MODELS; do
    got="$OUT/$name.$model.ppm"
    "$SHOT" "$rom" "$model" "$frames" "$got" "$script"
    python3 "$HERE/ppm2png.py" "$got" "$OUT/$name.$model.png"
    if cmp -s "$OUT/$name.$model.png" "$HERE/expected/$name.$model.png"; then
      line="$line ok"
      rm -f "$got" "$OUT/$name.$model.png"
    else
      # Say how far off, in pixels, against the standalone render.
      "$SHOT" "$HERE/$name.gb" "$model" "$frames" "$OUT/$name.$model.want.ppm"
      n=$(python3 "$HERE/ppmdiff.py" "$got" "$OUT/$name.$model.want.ppm" \
          | grep -o '[0-9]* pixels' | head -1 | cut -d' ' -f1)
      line="$line DIFF(${n:-?}px)"
      fail=1
    fi
  done
  printf '%-22s%s\n' "$name" "$line"
done <<EOF
$PAGES
EOF

if [ "$fail" = 0 ]; then
  echo "all pages pixel-identical to their standalone renders"
else
  echo "differences left in $OUT"
fi
exit "$fail"
