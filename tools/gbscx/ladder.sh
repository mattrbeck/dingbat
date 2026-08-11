#!/bin/bash
# The `enable_display/ly0_late_scx7_m3stat_scx*` ladder, both devices, as dots.
# Each ROM sets SCX to its own initial value, enables the LCD, stores $07 a
# swept number of M-cycles later and reads STAT at a FIXED dot -- so the family
# brackets the dot the fine scroll is LATCHED on, read out as mode 3 against
# mode 0.
set -e
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
D="$ROMS/gambatte/enable_display"
for dev in dmg cgb; do
  echo "=== $dev"
  args=""
  [ "$dev" = cgb ] && args="--cgb"
  for f in "$D"/ly0_late_scx7*; do
    bash tools/gbscx/edgemap.sh "${DT:-./dt_all}" $args "$f"
  done
done
