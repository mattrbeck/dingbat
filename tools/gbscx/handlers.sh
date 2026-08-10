#!/bin/bash
# Prints the STAT handler ($1000) of every scx_during_m3 ROM under one
# directory, which is where the family's whole variation lives: the prologue
# at $150 is byte-identical across the set and only the NOP counts between the
# SCX writes change.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
D="$ROMS/gambatte/scx_during_m3/$1"
for f in "$D"/*.gbc "$D"/*.gb; do
  [ -e "$f" ] || continue
  echo "=== $(basename "$f")"
  python3 "$WORKTREE/tools/gbscx/disasm.py" "$f" 0x1000 40
done
