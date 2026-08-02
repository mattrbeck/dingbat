#!/usr/bin/env bash
# Answer the only question a diverging frame really poses: is build B showing
# the same picture at a different animation phase, or a different picture?
# Dumps B at frame N and A across N-k..N+k, and reports which A frame (if any)
# B matches exactly.
# Usage: tools/gbgate/phase.sh <workdir> <rom> <frame> [radius]
set -uo pipefail

WORK=$(cd "$1" && pwd); ROM=$2; FRAME=$3; RADIUS=${4:-4}
# The same script the sweep used, or the runs are not comparable to it.
SCRIPT=${GBGATE_SCRIPT:-}
TMP="$WORK/phase"; mkdir -p "$TMP"
base=$(basename "$ROM")

dump() { # slot frame outfile
  local slot=$1 f=$2 out=$3 dir="$WORK/$1"
  ln -sf "$ROM" "$dir/roms/$base"
  rm -f "$dir/roms/"*.sav
  ( cd "$dir"; TMPDIR="$WORK/tmp$slot" DINGBAT_BENCH_DUMP="$f" \
      DINGBAT_BENCH_DUMP_PATH="$out" \
      ./dingbat_bench "$dir/roms/$base" 1 0 ${SCRIPT:+"$SCRIPT"} ) >/dev/null 2>&1
}

dump B "$FRAME" "$TMP/b.bin"
hit=""
for k in $(seq $((FRAME - RADIUS)) $((FRAME + RADIUS))); do
  [ "$k" -ge 0 ] || continue
  dump A "$k" "$TMP/a.bin"
  if cmp -s "$TMP/a.bin" "$TMP/b.bin"; then hit=$k; break; fi
done

if [ -n "$hit" ]; then
  echo "B@$FRAME == A@$hit  (phase offset $((hit - FRAME)) frames)"
else
  echo "B@$FRAME matches no A frame in +/-$RADIUS -- not a pure phase shift"
fi
