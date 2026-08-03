#!/bin/bash
# Run the mode-3 length oracle over a set of gambatte ROMs.
#   tools/m3sweep.sh dmg <rom> [<rom> ...]
cd "$(dirname "$0")/../.."
dev="$1"; shift
for rom in "$@"; do
  echo "=== $(basename "$rom")"
  tools/gbppu/m3len.sh "$dev" "$rom" | python3 tools/gbppu/m3oracle.py
done
