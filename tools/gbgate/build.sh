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
  # `nim c` directly, NOT `nimble bench_build`: nimble reads the package's file
  # list through `git ls-files`, and the tree above was extracted from a git
  # archive, so it is not a repository and nimble aborts before it compiles
  # anything. Keep this line in step with dingbat.nimble's bench_build task
  # (-d:test_harness is a LINK flag first — see tests/README.md).
  # GBGATE_FLAGS_A / GBGATE_FLAGS_B add per-slot compile flags, so one side can
  # carry a `-d:` knob the other does not (e.g. -d:M3_PIPE_DELAY=3) without
  # needing a commit for every value swept.
  local extra
  eval "extra=\${GBGATE_FLAGS_$slot:-}"
  ( cd "$dir" && TMPDIR="$WORK/tmp$slot" \
      nim c -d:test_harness -d:release --path:src $extra \
        -o:dingbat_bench tests/dingbat_bench.nim ) >"$WORK/build-$slot.log" 2>&1
  if [ ! -x "$dir/dingbat_bench" ]; then
    echo "build $slot ($ref) FAILED, see $WORK/build-$slot.log" >&2
    exit 1
  fi
  git -C "$REPO" rev-parse "$ref" >"$dir/REV"
  echo "$slot = $ref @ $(cat "$dir/REV")"
}

build_one "$REF_A" A
build_one "$REF_B" B
