#!/bin/bash
# Does this ROM put any object on any drawn line? `-d:gb_m3_len`'s M3IN line
# carries the OBJ X list in fetch order, so an empty `objx=` on every line means
# the ROM's mode 3 has no object term at all.
#
# The question this answers is the whole of round 3's hypothesis: "base mode-3
# length up by K, first-object penalty down by K" can only separate two rows if
# one of them HAS an object. A refuser with no object refutes it outright.
#
#   tools/gbscx/hasobj.sh ./dt_all <rom>...
set -e
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
DT=$1; shift
for rom in "$@"; do
  n=$("$DT" "$rom" --mode=screenshot --timeout=4 2>/dev/null \
      | grep -c "objx=[0-9]" || true)
  printf '%-64s objlines=%s\n' "$(basename "$rom")" "$n"
done
