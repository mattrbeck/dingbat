#!/bin/bash
# Score a subset of the gambatte suite by subdirectory.
#   tools/gamscore.sh sprites bgtiledata ...
# Writes per-row verdicts to /tmp/gamout.txt (with names), prints the summary.
set -o pipefail
cd "$(dirname "$0")/../.."
python3 tools/gbppu/gamlist.py "$@" > /tmp/gam.tsv || exit 1
./dingbat_test --mode=gambatte --list=/tmp/gam.tsv > /tmp/gamraw.txt 2>&1
rc=$?
python3 - <<'EOF'
import re
names = open("/tmp/gamnames.txt").read().splitlines()
out = []
npass = 0
for line in open("/tmp/gamraw.txt"):
    if not line.startswith("GAM "): continue
    p = line.split(" ", 3)
    i = int(p[1]); v = p[2]; d = p[3].strip() if len(p) > 3 else ""
    out.append((names[i], v, d))
    if v == "PASS": npass += 1
with open("/tmp/gamout.txt", "w") as f:
    for n, v, d in out:
        f.write("%s\t%s\t%s\n" % (v, n, d))
print("PASS %d / %d" % (npass, len(out)))
EOF
exit $rc
