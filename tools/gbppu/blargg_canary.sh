#!/bin/bash
# blargg canary: all eleven cpu_instrs frames pixel-identical to SameBoy at
# frame 1200, with the real CGB boot ROM on both sides. See tests/README.md
# ("blargg's on-screen text is NOT an oracle") for why this comparison, and not
# a glyph check, is the gate after a GB timing change.
#
#   tools/blargg_canary.sh [<dingbat_test>] [<sameboy_runner>] [<bootdir>]
cd "$(dirname "$0")/../.."
H="${1:-./dingbat_test}"
SB="${2:-/tmp/sameboy_runner}"
BOOT="${3:-/tmp/boot}"
D=/tmp/dingbat-test-roms/game-boy-test-roms/blargg/cpu_instrs/individual
W=$(mktemp -d)
ok=0; n=0
for rom in "$D"/*.gb; do
  b=$(basename "$rom" .gb)
  n=$((n+1))
  "$SB" "$rom" "$BOOT" "$W/sb" "" 1200 >/dev/null 2>&1
  "$H" "$rom" --mode=screenshot --timeout=1200 --screenshot="$W/db.ppm" \
       --bios="$BOOT/cgb_boot.bin" --nosave >/dev/null 2>&1
  if cmp -s "$W/sb.f1200.ppm" "$W/db.ppm"; then
    echo "$b: IDENTICAL"; ok=$((ok+1))
  else
    d=$(python3 - "$W/sb.f1200.ppm" "$W/db.ppm" <<'PY'
import sys
def rd(p):
    d = open(p, 'rb').read(); return d[d.index(b'255\n')+4:]
a = rd(sys.argv[1]); b = rd(sys.argv[2])
print(sum(1 for k in range(min(len(a), len(b))//3)
          if a[k*3:k*3+3] != b[k*3:k*3+3]))
PY
)
    echo "$b: DIFFERS in $d pixels"
  fi
done
rm -rf "$W"
echo "blargg canary: $ok/$n identical to SameBoy at frame 1200"
