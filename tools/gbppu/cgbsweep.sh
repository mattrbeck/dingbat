#!/bin/bash
# Build one setting of the CGB write-latency constants and score the whole
# gambatte suite against a baseline run, printing only the subdirectories that
# moved. See CGB_WX_LATENCY in gb/gb.nim.
#
#   tools/gbppu/cgbsweep.sh <tag> <baseline .txt> -d:CGB_WX_LATENCY=1 ...
set -e
cd "$(dirname "$0")/../.."
TAG=$1; shift
BASE=$1; shift
DEF="-d:CGB_WX_LATENCY=0 -d:CGB_WY_LATENCY=0 -d:CGB_SCY_LATENCY=0 -d:CGB_SCX_LATENCY=0 \
     -d:CGB_LCDC_LATENCY=0 -d:CGB_LCDC_TDSEL_LATENCY=0 -d:CGB_WY_LATCH_LATENCY=0"
mkdir -p /tmp/nc_wl/$TAG
nim c -d:test_harness -d:release --path:src --nimcache:/tmp/nc_wl/$TAG \
  $DEF "$@" -o:dingbat_test tests/dingbat_test.nim > /tmp/build_$TAG.log 2>&1 \
  || { echo "BUILD FAILED $TAG"; tail -20 /tmp/build_$TAG.log; exit 1; }
tools/gbppu/gamall.sh /tmp/g_$TAG > /tmp/sum_$TAG.txt 2>&1
echo "== $TAG: $* =="
tail -1 /tmp/sum_$TAG.txt
diff <(cut -f1,2 "$BASE") <(cut -f1,2 /tmp/g_$TAG.txt) > /tmp/rows_$TAG.txt || true
python3 - "$TAG" <<'EOF'
import sys, collections, re
tag = sys.argv[1]
up = collections.Counter(); dn = collections.Counter()
for l in open("/tmp/rows_%s.txt" % tag):
    if l.startswith("<") or l.startswith(">"):
        parts = l[2:].rstrip("\n").split("\t")
        if len(parts) < 2: continue
        v, nm = parts[0], parts[1]
        g = nm.split("/")[0] if "/" in nm else "(root)"
        if l[0] == "<" and v == "PASS": dn[g] += 1
        if l[0] == ">" and v == "PASS": up[g] += 1
for g in sorted(set(up) | set(dn)):
    print("  %-24s +%d -%d" % (g, up[g], dn[g]))
EOF
