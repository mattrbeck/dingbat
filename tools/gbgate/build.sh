#!/usr/bin/env bash
# Build two revisions of dingbat_bench into <workdir>/A and <workdir>/B.
# Usage: tools/gbgate/build.sh <ref-A> <ref-B> <workdir>
set -euo pipefail

if [ $# -lt 3 ]; then
  echo "usage: $0 <ref-A> <ref-B> <workdir>" >&2
  exit 2
fi
REF_A=$1; REF_B=$2; WORK=$3
REPO=$(git rev-parse --show-toplevel)

mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)

build_one() {
  local ref=$1 slot=$2
  local dir="$WORK/$slot"
  rm -rf "$dir"; mkdir -p "$dir" "$WORK/tmp$slot" "$dir/roms"
  # git archive, not a checkout: neither side can see the other's build
  # artifacts or a stray file in the working tree.
  git -C "$REPO" archive "$ref" -o "$WORK/$slot.tar"
  tar -x -f "$WORK/$slot.tar" -C "$dir"
  rm -f "$WORK/$slot.tar"
  ( cd "$dir" && TMPDIR="$WORK/tmp$slot" nimble bench_build ) >"$WORK/build-$slot.log" 2>&1
  if [ ! -x "$dir/dingbat_bench" ]; then
    echo "build $slot ($ref) FAILED, see $WORK/build-$slot.log" >&2
    exit 1
  fi
  git -C "$REPO" rev-parse "$ref" >"$dir/REV"
  echo "$slot = $ref @ $(cat "$dir/REV")"
}

build_one "$REF_A" A
build_one "$REF_B" B
