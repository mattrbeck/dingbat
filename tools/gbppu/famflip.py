#!/usr/bin/env python3
"""Turn a gamall.sh row file into per-family flip points.

A gambatte `_1/_2/_3...` family is one ROM with one write moved by one CPU
M-cycle per step, so the step at which its expected value changes IS the
measurement. This prints, per family and per device, the expected sequence and
what the build under test produced -- which is what says whether a latency is
too early, too late, or right.

    tools/gbppu/famflip.py /tmp/g_base.txt 'window/arg/late_wy_*'
"""
import sys, re, fnmatch, collections

path = sys.argv[1]
pats = sys.argv[2:] or ['*']

rows = []
for line in open(path):
    v, name, detail = (line.rstrip("\n").split("\t") + ["", ""])[:3]
    m = re.match(r'^(.*) \[(dmg|cgb)\]$', name)
    if not m:
        continue
    rom, dev = m.group(1), m.group(2)
    # Strip the device/expectation tags. `_out` takes 1-20 hex digits
    # (tests/README.md): a single-digit match leaves the tail glued to the
    # family name and splits every family that contains a flip.
    base = re.sub(r'_(dmg08|cgb04c|dmg08_cgb04c)(_out[0-9a-fA-F]+)?', '', rom)
    base = re.sub(r'_out[0-9a-fA-F]+', '', base)
    mm = re.match(r'^(.*?)_(\d+)$', base)
    if mm:
        fam, idx = mm.group(1), int(mm.group(2))
    else:
        fam, idx = base, -1
    got = exp = None
    if v == "PASS":
        got = exp = detail.strip()
    else:
        g = re.match(r'got (\S+), expected (\S+)', detail)
        if g:
            got, exp = g.group(1), g.group(2)
    rows.append((fam, idx, dev, v, got, exp))

fams = collections.defaultdict(dict)
for fam, idx, dev, v, got, exp in rows:
    fams[fam][(idx, dev)] = (v, got, exp)

for fam in sorted(fams):
    if not any(fnmatch.fnmatch(fam, p) for p in pats):
        continue
    idxs = sorted({k[0] for k in fams[fam]})
    print(fam)
    for dev in ("dmg", "cgb"):
        exp = []
        got = []
        for i in idxs:
            e = fams[fam].get((i, dev))
            exp.append(e[2] if e and e[2] is not None else "?")
            got.append(e[1] if e and e[1] is not None else "?")
        if all(x == "?" for x in exp):
            continue
        bad = "".join("." if a == b else "X" for a, b in zip(exp, got))
        print("  %s  n=%-22s exp=%-22s got=%-22s %s" %
              (dev, ",".join(str(i) for i in idxs),
               ",".join(exp), ",".join(got), bad))
