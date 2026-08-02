#!/usr/bin/env bash
# Assemble a shot.sh/sweep.sh workdir from two already-built dingbat_bench
# binaries, so a bisect can re-pair existing builds without rebuilding.
# Usage: tools/gbgate/pair.sh <new-workdir> <bench-A> <bench-B>
set -euo pipefail
WORK=$1; A=$2; B=$3
mkdir -p "$WORK/A/roms" "$WORK/B/roms" "$WORK/tmpA" "$WORK/tmpB"
cp "$A" "$WORK/A/dingbat_bench"
cp "$B" "$WORK/B/dingbat_bench"
echo "paired: A=$A B=$B -> $WORK"
