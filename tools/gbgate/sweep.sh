#!/usr/bin/env bash
# Compare the per-frame framebuffer hash streams of the two builds in <workdir>
# across every ROM in <roms.txt>.
# Usage: tools/gbgate/sweep.sh <workdir> <roms.txt> [frames] [warmup] [input-script]
set -uo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <workdir> <roms.txt> [frames] [warmup] [input-script]" >&2
  exit 2
fi
WORK=$(cd "$1" && pwd); LIST=$2
FRAMES=${3:-1200}; WARMUP=${4:-120}; SCRIPT=${5:-}
TAG=${GBGATE_TAG:-default}
DEADLINE=${GBGATE_TIMEOUT:-300}

mkdir -p "$WORK/hashes/$TAG"
RESULTS="$WORK/results-$TAG.tsv"
: >"$RESULTS"

# Run one build over one ROM under a watchdog. The child's stdout goes to a
# file and the watchdog polls; it never shares a pipe with the child, so a ROM
# that hangs cannot also wedge the harness by holding a descriptor open.
run_one() {
  local slot=$1 rom=$2 out=$3
  local dir="$WORK/$slot"
  local base link
  base=$(basename "$rom")
  link="$dir/roms/$base"
  ln -sf "$rom" "$link"
  rm -f "$dir/roms/"*.sav
  (
    cd "$dir"
    TMPDIR="$WORK/tmp$slot" DINGBAT_BENCH_HASH=1 \
      ./dingbat_bench "$link" "$FRAMES" "$WARMUP" ${SCRIPT:+"$SCRIPT"}
  ) >"$out" 2>"$out.err" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$DEADLINE" ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

# read -r over the list: a ROM path with a space (most of them) must not be
# split, and an early EOF must not look like a clean finish.
n=0
while IFS= read -r rom; do
  case "$rom" in ''|'#'*) continue ;; esac
  [ -f "$rom" ] || { printf '%s\tMISSING\t-\n' "$rom" >>"$RESULTS"; continue; }
  n=$((n + 1))
  name=$(basename "$rom")
  ha="$WORK/hashes/$TAG/$name.A"; hb="$WORK/hashes/$TAG/$name.B"
  run_one A "$rom" "$ha"; ra=$?
  run_one B "$rom" "$hb"; rb=$?
  if [ $ra -eq 124 ] || [ $rb -eq 124 ]; then
    status=TIMEOUT; first=-
  elif [ $ra -ne 0 ] || [ $rb -ne 0 ]; then
    status=ERROR; first="A=$ra B=$rb"
  elif cmp -s "$ha" "$hb"; then
    status=IDENTICAL; first=-
  else
    status=DIVERGE
    # each line is "<frame> <hash>"; the first differing line names the frame
    first=$(diff "$ha" "$hb" | grep -m1 '^< ' | awk '{print $2}')
    [ -n "$first" ] || first="?"
  fi
  printf '%s\t%s\t%s\n' "$name" "$status" "$first" | tee -a "$RESULTS"
done <"$LIST"

echo "--- $n ROMs, tag=$TAG, frames=$FRAMES warmup=$WARMUP script='${SCRIPT}' ---"
awk -F'\t' '{c[$2]++} END {for (k in c) print k, c[k]}' "$RESULTS"
