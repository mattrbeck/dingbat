#!/usr/bin/env bash
# For every DIVERGE row in a sweep's results, dump both builds' framebuffers at
# a spread of frames and report per-frame pixel equality. A hash stream cannot
# answer this on its own: the bench hash is *rolling*, so one differing frame
# poisons every later hash whether or not the picture ever differs again.
#
# Usage: tools/gbgate/classify.sh <workdir> <roms.txt> <tag> [frames...]
set -uo pipefail

WORK=$(cd "$1" && pwd); LIST=$2; TAG=$3; shift 3
FRAMES=${*:-"120 300 500 700 900 1200"}
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${GBGATE_SCRIPT:-}
OUT="$WORK/shots/$TAG"
mkdir -p "$OUT"

while IFS=$'\t' read -r name status first; do
  [ "$status" = DIVERGE ] || continue
  rom=$(grep -F "/$name" "$LIST" | head -1)
  [ -n "$rom" ] || continue
  echo "=== $name (first hash divergence: frame $first)"
  for f in $first $FRAMES; do
    printf '  frame %-5s ' "$f"
    "$HERE/shot.sh" "$WORK" "$rom" "$f" "$OUT/${name}.f${f}" "$SCRIPT"
  done
done <"$WORK/results-$TAG.tsv"
