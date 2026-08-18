#!/usr/bin/env bash
# read_g1 -- read a probe (e) hardware photo end to end.
#
#   tools/gbprobe/read_g1.sh <photo.jpg>
#
# photowarp's own lit-frame detector gives up on these GBA SP shots, so the
# quad comes from find_panel.py (largest connected bright region) and is passed
# in explicitly. read_probe_e.py then measures each bar against the header
# inside the same frame, so the quad only has to be good enough to get the
# glyphs and the bars into the same 160x144 -- a translation error cancels.
set -euo pipefail
cd "$(dirname "$0")/../.."
PHOTO=$1
OUT=${TMPDIR:-/tmp}/$(basename "${PHOTO%.*}").ppm
CORNERS=$(python3 tools/gbprobe/find_panel.py "$PHOTO")
echo "corners: $CORNERS"
python3 tools/gbprobe/photowarp.py "$PHOTO" "$OUT" --corners "$CORNERS" >/dev/null
python3 tools/gbprobe/read_probe_e.py "$OUT"
