#!/bin/bash
# Cross-tabulate the STAT-read IDIOM against which side of the round-3
# disagreement a row falls on. Takes the two gamall row files (before/after the
# field tail) plus the runner's own suites, and for every row that MOVED prints
# the idiom its ROM uses.
#
# The hypothesis under test: the parties that disagree about the field report
# use different read instructions. This is what makes that answerable over
# hundreds of rows instead of three.
#
#   tools/gbscx/idiomtab.sh <before.txt> <after.txt>
set -e
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
python3 - "$1" "$2" "$ROMS/gambatte" <<'EOF'
import sys, os, subprocess
sys.path.insert(0, "tools/gbscx")
from readidiom import scan

def load(p):
    d = {}
    for l in open(p):
        f = l.rstrip("\n").split("\t")
        if len(f) >= 2: d[f[1]] = f[0]
    return d

a, b = load(sys.argv[1]), load(sys.argv[2])
root = sys.argv[3]
index = {}
for dirpath, _, files in os.walk(root):
    for fn in files:
        if fn.endswith((".gb", ".gbc")):
            index.setdefault(os.path.splitext(fn)[0], os.path.join(dirpath, fn))

buckets = {}
for k in sorted(set(a) | set(b)):
    if a.get(k) == b.get(k): continue
    name = k.split(" [")[0].split("/")[-1]
    p = index.get(name)
    if not p: continue
    forms = sorted({h[1] for h in scan(p)})
    key = (",".join(forms) or "none", "GAINED" if b.get(k) == "PASS" else "LOST")
    buckets.setdefault(key, []).append(k)
for (form, side), rows in sorted(buckets.items()):
    print("%-6s  %-24s %d rows   e.g. %s" % (side, form, len(rows),
                                             rows[0].split(" [")[0]))
EOF
