#!/bin/bash
# Every row whose verdict moved between two gamall.sh row files, with the
# family of each move counted. "+" is a row that went green, "-" one that went
# red. A change that claims to be local has to answer for every line here.
#
#   tools/gbscx/gamdiff.sh .tmp/g_base.txt .tmp/g_after.txt
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
python3 - "$1" "$2" <<'EOF'
import sys
def load(p):
    d = {}
    for l in open(p):
        f = l.rstrip("\n").split("\t")
        if len(f) >= 2:
            d[f[1]] = f[0]
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
gained, lost = [], []
for k in sorted(set(a) | set(b)):
    if a.get(k) != b.get(k):
        (gained if b.get(k) == "PASS" else lost).append(k)
fam = {}
for k in gained: fam.setdefault(k.split("/")[0], [0, 0])[0] += 1
for k in lost:   fam.setdefault(k.split("/")[0], [0, 0])[1] += 1
print("moved rows: +%d / -%d" % (len(gained), len(lost)))
for f, (g, l) in sorted(fam.items()):
    print("  %-24s +%-4d -%d" % (f, g, l))
if lost:
    print("\nrows that went RED:")
    for k in lost: print("  " + k)
EOF
