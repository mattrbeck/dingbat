#!/usr/bin/env bash
# Dump one frame from both builds and say whether they are pixel-identical.
# Usage: tools/gbgate/shot.sh <workdir> <rom> <frame> <out-prefix> [input-script]
set -uo pipefail

if [ $# -lt 4 ]; then
  echo "usage: $0 <workdir> <rom> <frame> <out-prefix> [input-script]" >&2
  exit 2
fi
WORK=$(cd "$1" && pwd); ROM=$2; FRAME=$3; PREFIX=$4; SCRIPT=${5:-}
HERE=$(cd "$(dirname "$0")" && pwd)
# The bench runs with its cwd inside the build dir, so a relative dump path
# would land there instead of next to the caller.
case "$PREFIX" in /*) ;; *) PREFIX="$PWD/$PREFIX" ;; esac
mkdir -p "$(dirname "$PREFIX")"

for slot in A B; do
  dir="$WORK/$slot"
  base=$(basename "$ROM")
  ln -sf "$ROM" "$dir/roms/$base"
  rm -f "$dir/roms/"*.sav
  (
    cd "$dir"
    TMPDIR="$WORK/tmp$slot" DINGBAT_BENCH_DUMP="$FRAME" \
      DINGBAT_BENCH_DUMP_PATH="$PREFIX.$slot.bin" \
      ./dingbat_bench "$dir/roms/$base" 1 0 ${SCRIPT:+"$SCRIPT"}
  ) >/dev/null 2>&1
  python3 "$HERE/fb2png.py" "$PREFIX.$slot.bin" "$PREFIX.$slot.png" >/dev/null
done

if cmp -s "$PREFIX.A.bin" "$PREFIX.B.bin"; then
  echo "frame $FRAME: PIXEL-IDENTICAL"
else
  differing=$(python3 - "$PREFIX.A.bin" "$PREFIX.B.bin" <<'PY'
import struct, sys
a = open(sys.argv[1], 'rb').read(); b = open(sys.argv[2], 'rb').read()
pa = struct.unpack('<%dH' % (len(a)//2), a); pb = struct.unpack('<%dH' % (len(b)//2), b)
print(sum(1 for x, y in zip(pa, pb) if x != y))
PY
)
  echo "frame $FRAME: DIFFERS in $differing / 23040 pixels"
fi
