#!/bin/bash
# One ROM, one model, one frame count -> one framebuffer per engine.
#
#   ./shoot.sh <rom.gb> <model> <frames> <outprefix> [engines...]
#
# writes <outprefix>.<engine>.ppm (and .png) for each of dingbat, sameboy and
# docboy. With no engine list, all three are shot.
#
# Models, and what each engine can actually be asked for:
#
#   token   dingbat        sameboy        docboy
#   dmg     grDmgABC       GB_MODEL_DMG_B DMG build
#   cgb     grCgbC (dflt)  GB_MODEL_CGB_E CGB build
#   cgbC    grCgbC         GB_MODEL_CGB_C CGB build
#   cgbD    grCgbD         GB_MODEL_CGB_D CGB build
#   cgbE    grCgbE         GB_MODEL_CGB_E CGB build
#   agb     grAgb          GB_MODEL_AGB_A CGB build
#
# DocBoy has NO revision axis — CGB support is a compile-time switch and there
# is one CGB. So every cgb* token gives the same DocBoy binary, and a DocBoy
# column in a results table is one number for all of C/D/E by construction.
# Boot ROMs for the sameboy leg: $GBPROBE_BOOTROMS (default .scratch/bootroms).
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export GBPROBE_BOOTROMS="${GBPROBE_BOOTROMS:-$ROOT/.scratch/bootroms}"

if [ $# -lt 4 ]; then
  sed -n '2,25p' "$0"
  exit 2
fi
ROM="$1"; MODEL="$2"; FRAMES="$3"; OUT="$4"; shift 4
ENGINES="${*:-dingbat sameboy docboy}"

case "$(echo "$MODEL" | tr 'A-Z' 'a-z')" in
  dmg*|mgb|sgb*) DOCBOY_BUILD=dmg ;;
  *)             DOCBOY_BUILD=cgb ;;
esac

mkdir -p "$(dirname "$OUT")"

for e in $ENGINES; do
  case "$e" in
    dingbat) "$HERE/bin/dingbat_shot" "$ROM" "$MODEL" "$FRAMES" "$OUT.dingbat.ppm" ;;
    sameboy) "$HERE/bin/sameboy_shot" "$ROM" "$MODEL" "$FRAMES" "$OUT.sameboy.ppm" ;;
    docboy)  "$HERE/bin/docboy_shot_$DOCBOY_BUILD" "$ROM" "$FRAMES" "$OUT.docboy.ppm" ;;
    *) echo "unknown engine $e"; exit 2 ;;
  esac
  python3 "$HERE/ppm2png.py" "$OUT.$e.ppm" "$OUT.$e.png"
  echo "$OUT.$e.ppm"
done
