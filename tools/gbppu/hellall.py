#!/usr/bin/env python3
"""Delay EVERY scanline's LCDC writes by k M-cycles and compare whole frames.

If dingbat's disagreement with silicon on cgb-acid-hell is one uniform
CPU-vs-PPU phase constant, then dingbat's frame with every line delayed by k
must equal the ORACLE's undelayed frame for the k that cancels it -- on all 144
lines at once, not just the two that happen to be sensitive. If instead only
lines 68/69 line up, the 4 dots are specific to those lines and the constant
theory is dead.

    hellall.py <k>            dingbat@k  vs  oracle@0   (and oracle@k as control)
"""
import os, re, subprocess, sys, shutil

TMP = os.environ.get("HELL_TMP", os.environ.get("TMPDIR", "/tmp"))
SRC = os.environ.get("ACID_HELL_SRC", TMP + "/cgb-acid-hell")
WORK = TMP + "/hellall"
RG = os.environ.get("RGBDS", os.path.abspath(".scratch/rgbds"))
DINGBAT = os.environ.get("DINGBAT", "./dingbat_test")
SB = os.environ.get("SAMEBOY_RUNNER", "tools/gbfuzz/sameboy_runner")
BR = os.path.expanduser("~/code/SameBoy/build/bin/BootROMs")


def build(k, tag):
    os.makedirs(WORK, exist_ok=True)
    for f in ("cgb-acid-hell.asm", "hardware.inc"):
        shutil.copy(SRC + "/" + f, WORK + "/" + f)
    p = WORK + "/cgb-acid-hell.asm"
    L = open(p).read().split('\n')
    n = 0
    POS = os.environ.get("HELL_POS", "writes")
    for i, l in enumerate(L):
        # "writes": delay only the 16 LCDC writes (the nops after the rSCY
        # write). "all": delay EVERYTHING the block does after the halt, by
        # spending the halt's own trailing nop -- rSCY included. If both give a
        # pixel-perfect frame the two hypotheses are indistinguishable here; if
        # only one does, acid-hell has separated them.
        if POS == "all" and l.strip() == 'halt':
            d, j = k, i + 1
            while d > 0 and j < len(L):
                if L[j].strip() == 'nop':
                    L[j] = "    ld a, [hl]"
                    d -= 1
                j += 1
            n += 1
            continue
        if POS == "writes" and 'ldh [rSCY], a' in l:
            d, j = k, i + 1
            while d > 0 and j < len(L):
                if L[j].strip() == 'nop':
                    L[j] = "    ld a, [hl]"
                    d -= 1
                j += 1
            n += 1
    open(p, 'w').write('\n'.join(L))
    for cmd in ([RG + "/rgbasm", "-o", "h.o", "cgb-acid-hell.asm"],
                [RG + "/rgblink", "-o", tag + ".gbc", "h.o"],
                [RG + "/rgbfix", "-v", "-p", "255", tag + ".gbc"]):
        r = subprocess.run(cmd, cwd=WORK, capture_output=True)
        if r.returncode:
            sys.exit(r.stderr.decode()[:600])
    return WORK + "/" + tag + ".gbc", n


def frame_ding(rom, out):
    subprocess.run([DINGBAT, rom, "--mode=screenshot", "--cgb", "--color",
                    "--timeout=120", "--screenshot=" + out], capture_output=True)
    return read_ppm(out)


def frame_sb(rom, pre):
    subprocess.run([SB, rom, BR, pre, "", "240"], capture_output=True)
    return read_ppm(pre + ".f0240.ppm")


def read_ppm(p):
    d = open(p, 'rb').read()
    parts, i = [], 0
    while len(parts) < 4:
        while d[i:i + 1].isspace():
            i += 1
        j = i
        while not d[j:j + 1].isspace():
            j += 1
        parts.append(d[i:j]); i = j
    w = int(parts[1])
    px = d[i + 1:]
    return [px[y * w * 3:(y + 1) * w * 3] for y in range(144)]


def cmp(a, b, label):
    bad = [y for y in range(144) if a[y] != b[y]]
    npx = sum(sum(1 for x in range(160)
                  if a[y][x * 3:x * 3 + 3] != b[y][x * 3:x * 3 + 3])
              for y in bad)
    print("  %-28s %4d px on %d lines %s"
          % (label, npx, len(bad), bad[:12] if bad else ""))


k = int(sys.argv[1])
r0, n = build(0, "k0")
o0 = frame_sb(r0, WORK + "/o0")
d0 = frame_ding(r0, WORK + "/d0.ppm")
rk, _ = build(k, "k%d" % k)
ok = frame_sb(rk, WORK + "/ok")
dk = frame_ding(rk, WORK + "/dk.ppm")
print("delayed %d block(s) by %d M-cycle(s)" % (n, k))
cmp(d0, o0, "dingbat@0 vs oracle@0")
cmp(dk, o0, "dingbat@%d vs oracle@0" % k)
cmp(dk, ok, "dingbat@%d vs oracle@%d" % (k, k))
cmp(d0, ok, "dingbat@0 vs oracle@%d" % k)
