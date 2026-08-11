#!/bin/bash
# Shoot one probe on every engine/model in a list and print each readout.
#
#   ./table.sh <rom.gb> <frames> <model> [model...]
#
# For each model, every engine that can be asked for it is shot and its screen
# is read back with readout.py. Engines whose model axis does not reach that
# far are skipped rather than silently answered with something else: DocBoy has
# no CGB revision axis at all, so it is shot once per CGB family, not once per
# revision.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROM="$1"; FRAMES="$2"; shift 2
NAME="$(basename "$ROM" .gb)"
SYM="$(dirname "$ROM")/$NAME.sym"
mkdir -p "$HERE/out"

DOCBOY_CGB_DONE=0
for model in "$@"; do
  for engine in dingbat sameboy docboy; do
    if [ "$engine" = docboy ]; then
      case "$model" in
        dmg*|mgb|sgb*) : ;;
        *) [ "$DOCBOY_CGB_DONE" = 1 ] && continue; DOCBOY_CGB_DONE=1 ;;
      esac
    fi
    out="$HERE/out/$NAME.$model"
    "$HERE/shoot.sh" "$ROM" "$model" "$FRAMES" "$out" "$engine" >/dev/null
    echo "=== $NAME  $engine  $model"
    python3 "$HERE/readout.py" "$out.$engine.ppm" "$ROM" --sym "$SYM"
    echo
  done
done
