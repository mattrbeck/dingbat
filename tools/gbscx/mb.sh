#!/bin/bash
# Mealybug, per device, for one binary. The CGB arm runs the DMG carts on CGB
# hardware against the suite's own `_cgb_c` references and is the tree's main
# mid-mode-3 CGB oracle outside gambatte, so a mode-3 change has to report it
# even though the local runner already scores the DMG side.
#
#   tools/gbscx/mb.sh cgb ./dingbat_test
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
export MBROOT="$ROMS/mealybug-tearoom-tests/ppu"
exec python3 tools/gbppu/mbscore.py "${2:-./dingbat_test}" "${1:-cgb}"
