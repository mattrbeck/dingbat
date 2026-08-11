#!/bin/bash
# For each ROM named, print the SCORED line's mode-3 facts: every SCX store on
# that line with its dot, the fine scroll the line latched, mode 3's length,
# the dot of the 3->0 edge, and the dot the ROM reads STAT on with the value it
# got. The filename carries what hardware answers, so the pair turns a
# pass/fail row into "hardware's edge is in this dot range and ours is here".
#
# State is reset at every line boundary rather than keyed to LY: a trace covers
# several frames and `ly = 0` recurs in each of them, so matching on LY alone
# silently reports a different frame's line.
#
#   tools/gbscx/edgemap.sh ./dt_all [--cgb] <rom>...
set -e
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
DT=$1; shift
DEV=""
if [ "$1" = "--cgb" ]; then DEV="--cgb --color"; shift; fi
for rom in "$@"; do
  "$DT" "$rom" --mode=screenshot --timeout=6 $DEV 2>/dev/null \
    | python3 -c '
import sys, os
rom = os.path.basename(sys.argv[1])
cur = dict(stores=[], latch=None, mlen=None, edge=None, ly=None)
def clear(ly):
    cur.update(stores=[], latch=None, mlen=None, edge=None, ly=ly)
out = None
nreads = [0]
for line in sys.stdin:
    tag = line[:5]
    f = {}
    for p in line.split():
        if "=" in p:
            k, v = p.split("=", 1)
            f[k] = v
    if line.startswith("MODE") and "->2" in line:
        clear(f.get("ly"))
    elif line.startswith("MODE") and "->1" in line:
        clear(f.get("ly"))
    elif tag == "SCX l":
        cur["stores"].append("%s@%s" % (f.get("new"), f.get("dot")))
    elif tag == "LATCH":
        cur["latch"] = f.get("scx")
    elif tag == "M3LEN":
        cur["mlen"] = f.get("len")
    elif line.startswith("MODE") and "3->0" in line:
        cur["edge"] = f.get("dot")
    elif "a=FF41" in line:
        out = (f, dict(cur))
        nreads[0] += 1
    elif tag == "LCDC " and f.get("new") == "00":
        break
if out is None:
    print("%-56s NO STAT READ" % rom); raise SystemExit
rd, c = out
print("%-56s ly=%-3s store=%-14s latch=%-3s len=%-4s edge=%-4s read=%-4s got=%s"
      % (rom, rd.get("ly"), ",".join(c["stores"]) or "-", c["latch"] or "?",
         c["mlen"] or "?", c["edge"] or "-", rd.get("dot"),
         rd.get("v")) + "  reads=%d" % nreads[0])
' "$rom"
done
