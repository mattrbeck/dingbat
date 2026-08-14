#!/bin/bash
# Speed-switch sweep: build ./dingbat_test with one set of -d: defines, score a
# chosen set of gambatte subdirectories, and write a row file.
#
#   tools/gbppu/sssweep.sh <outprefix> "<defines>" [subdir ...]
#
# Everything is keyed off <outprefix> so two sessions can sweep at once; the
# binary is <outprefix>.bin and the rows land in <outprefix>.txt in the same
# `verdict<TAB>row<TAB>detail` shape gamall.sh writes, so famflip.py and
# gamall's own diff recipe read it unchanged. Defaults to the four
# speed-switch-carrying subdirectories; pass `'*'` for the whole suite.
set -e
cd "$(dirname "$0")/../.."
PFX=$1; DEFS=$2; shift 2
set -f   # the subdir list is a glob for gamlist.py, not for this shell
SUBS=${*:-speedchange lcd_offset dma oamdma}
N=${N:-10}
nim c -d:test_harness -d:release --path:src $DEFS -o:"$PFX.bin" \
      tests/dingbat_test.nim >/dev/null 2>&1
GAMNAMES=$PFX.names python3 tools/gbppu/gamlist.py $SUBS > "$PFX.tsv"
rm -f "$PFX".shard*
python3 - "$PFX" "$N" <<'EOF'
import sys
pfx, n = sys.argv[1], int(sys.argv[2])
lines = open(pfx + ".tsv").read().splitlines()
fs = [open("%s.shard%d.tsv" % (pfx, i), "w") for i in range(n)]
for i, l in enumerate(lines): fs[i % n].write(l + "\n")
for f in fs: f.close()
EOF
pids=()
for i in $(seq 0 $((N-1))); do
  "$PFX.bin" --mode=gambatte --list="$PFX.shard$i.tsv" > "$PFX.shard$i.raw" 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait $p; done
python3 - "$PFX" "$N" <<'EOF'
import sys
pfx, n = sys.argv[1], int(sys.argv[2])
names = [l.rstrip("\n") for l in open(pfx + ".names")]
res = {}
for s in range(n):
    idxs = [i for i in range(len(names)) if i % n == s]
    for line in open("%s.shard%d.raw" % (pfx, s)):
        if not line.startswith("GAM "): continue
        p = line.split(" ", 3)
        res[idxs[int(p[1])]] = (p[2], p[3].strip() if len(p) > 3 else "")
out = open(pfx + ".txt", "w"); np = 0
for i, nm in enumerate(names):
    v = res.get(i, ("MISSING", ""))
    if v[0] == "PASS": np += 1
    out.write("%s\t%s\t%s\n" % (v[0], nm, v[1]))
out.close()
print("%s  PASS %d / %d" % (pfx, np, len(names)))
EOF
