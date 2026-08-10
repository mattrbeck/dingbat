#!/bin/sh
# hellline.sh <pxtag> <ly> -- the last frame's BG bitplane reads and LCDC.4
# change dots for ONE line of cgb-acid-hell, from one px-trace build.
#
# The question it is for: cgb-acid-hell's glitched reads and mealybug's are the
# same mechanism, so their write-to-read displacement has to agree. This prints
# the displacement directly (dot of the read, dot the LCDC.4 change went live)
# rather than inferring it from the picture.
set -e
W=/Users/matt/code/dingbat/.claude/worktrees/agent-a23f3fac6bc332556
TAG=$1; LY=$2
export XDG_CACHE_HOME=$W/.cache
export DINGBAT_ROM_CACHE=$W/.romcache
export TMPDIR=$W/.tmp/tmp-$TAG
mkdir -p "$TMPDIR"
cd "$W"
R=$W/.romcache/game-boy-test-roms/cgb-acid-hell/cgb-acid-hell.gbc
"./dt_px-$TAG" "$R" --mode=screenshot --timeout=120 --cgb --color --nosave \
    --screenshot="$TMPDIR/hell.ppm" 2>/dev/null \
  | awk -v ly="$LY" '
      /^LATCH ly=0 / { n = 0; delete buf; next }
      /^FDATA / && $2 == "ly=" ly { buf[n++] = $0 }
      END { for (i = 0; i < n; i++) print buf[i] }'
