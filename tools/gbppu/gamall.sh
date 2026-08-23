#!/bin/bash
# Score the whole gambatte suite with the local ./dingbat_test, sharded, and
# print one pass count per subdirectory. Same rows and verdicts as the runner's
# gambatte pass, ~6 s, and it does not touch tests/results*.md.
#
#   tools/gbppu/gamall.sh /tmp/g_before      # on main
#   tools/gbppu/gamall.sh /tmp/g_after       # with the change
#   diff <(cut -f1,2 /tmp/g_before.txt) <(cut -f1,2 /tmp/g_after.txt)
#
# Writes <prefix>.txt as `verdict<TAB>row name<TAB>detail`, one line per row.
set -e
cd "$(dirname "$0")/../.."
PFX=$1
N=${N:-10}
GAMNAMES=$PFX.names python3 tools/gbppu/gamlist.py '*' > "$PFX.tsv"
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
  ./dingbat_test --mode=gambatte --list="$PFX.shard$i.tsv" > "$PFX.shard$i.raw" 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait $p; done
python3 - "$PFX" "$N" <<'EOF'
import sys, collections
pfx, n = sys.argv[1], int(sys.argv[2])
names = [l.rstrip("\n") for l in open(pfx + ".names")]
res = {}
for s in range(n):
    idxs = [i for i in range(len(names)) if i % n == s]
    for line in open("%s.shard%d.raw" % (pfx, s)):
        if not line.startswith("GAM "): continue
        p = line.split(" ", 3)
        res[idxs[int(p[1])]] = (p[2], p[3].strip() if len(p) > 3 else "")
out = open(pfx + ".txt", "w")
grp = collections.Counter(); tot = collections.Counter(); np = 0
for i, nm in enumerate(names):
    v = res.get(i, ("MISSING", ""))
    g = nm.split("/")[0] if "/" in nm else "(root)"
    tot[g] += 1
    if v[0] == "PASS": np += 1; grp[g] += 1
    out.write("%s\t%s\t%s\n" % (v[0], nm, v[1]))
out.close()
for g in sorted(tot): print("%-24s %d/%d" % (g, grp[g], tot[g]))
print("TOTAL %d/%d  -> %s.txt" % (np, len(names), pfx))
EOF
