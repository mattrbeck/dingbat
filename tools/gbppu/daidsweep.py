#!/usr/bin/env python3
"""Perturb daid's ppu_scanline_bgp source and run it through two dingbat
builds and the sameboy_runner.

The ROM takes one STAT LYC interrupt out of `halt`, discards the return
address and free-runs a 114-M loop (10 BGP writes 4 M apart + 70 nops + jp)
for the whole frame, so its band edges rule the palette write's phase against
one anchor. Two knobs, both one line of source:

  --lyc N   which line the anchor fires on. 0 (shipped) is the LY 153 -> 0
            snapback; anything else is a normal line.
  k         nops between statInt's `ei` and `ld hl, data` (shipped: 1). The
            ROM is not full and has no raw-address jumps, so nops can simply
            be inserted or removed.

The oracle runs with GBFUZZ_MODEL=cgb: the cart is DMG-flagged and the
captured machine is a CGB in compatibility mode (a CGB header flag would boot
native mode, a different machine).

Building the source: it ships with the shootout at testroms/daid/. Copy
ppu_scanline_bgp.asm, common.inc, hardware.inc and font.bin into $DAID_SRC,
apply the pre-0.6-rgbds fixes listed in hellsrc.py, and in BOTH the .asm and
common.inc rewrite `ld a, [rXX]` / `ld [rXX], a` as `ldh` (modern rgbasm no
longer shortens them, and the long form costs an M-cycle per access). The
rebuild must be byte-exact: md5 16ec1c02eaed01bf16616e268428d4a8.
"""
import os, re, subprocess, sys, shutil

TMP = os.environ.get("HELL_TMP", os.environ.get("TMPDIR", "/tmp"))
SRC = os.environ.get("DAID_SRC", TMP + "/daidsrc")
WORK = TMP + "/daidwork"
W = os.environ.get("DINGBAT_ROOT", os.path.abspath("."))
RG = W + "/.scratch/rgbds"
OFF = W + "/dingbat_test"          # shipping: CGB_HALT_PPU_LEAD=0
ON = os.environ.get("DINGBAT_LEAD", TMP + "/dt_lead")              # CGB_HALT_PPU_LEAD=1
SB = W + "/tools/gbfuzz/sameboy_runner"
BR = os.path.expanduser("~/code/SameBoy/build/bin/BootROMs")
SHOTS = 600


def build(lyc, k):
    os.makedirs(WORK, exist_ok=True)
    for f in ("ppu_scanline_bgp.asm", "common.inc", "hardware.inc", "font.bin"):
        shutil.copy(SRC + "/" + f, WORK + "/" + f)
    p = WORK + "/ppu_scanline_bgp.asm"
    L = open(p).read().split("\n")
    out, i = [], 0
    while i < len(L):
        l = L[i]
        # the anchor line: `xor a` immediately before `ldh [rLYC], a`
        if l.strip() == "xor a" and i + 1 < len(L) and "[rLYC]" in L[i + 1]:
            out.append("  ld a, %d" % lyc)
            i += 1
            continue
        # statInt's idle nop between `ei` and `ld hl, data`
        if l.strip() == "nop" and i + 1 < len(L) and "ld hl, data" in L[i + 1]:
            out.extend(["  nop"] * k)
            i += 1
            continue
        out.append(l)
        i += 1
    open(p, "w").write("\n".join(out))
    for cmd in ([RG + "/rgbasm", "ppu_scanline_bgp.asm", "-o", "t.o"],
                [RG + "/rgblink", "t.o", "-o", "t.gb"],
                [RG + "/rgbfix", "-v", "t.gb", "-p", "0xff"]):
        r = subprocess.run(cmd, cwd=WORK, capture_output=True)
        if r.returncode:
            sys.exit(r.stderr.decode()[:500])
    return WORK + "/t.gb"


def ding(binary, rom, out):
    subprocess.run([binary, rom, "--mode=screenshot", "--cgb", "--model=cgbe",
                    "--color", "--timeout=%d" % SHOTS, "--screenshot=" + out],
                   capture_output=True)
    return open(out, "rb").read()


def sameboy(rom, pre):
    e = dict(os.environ, GBFUZZ_MODEL="cgb")
    subprocess.run([SB, rom, BR, pre, "", str(SHOTS)], capture_output=True, env=e)
    return open("%s.f%04d.ppm" % (pre, SHOTS), "rb").read()


def npx(a, b):
    return sum(1 for i in range(0, min(len(a), len(b)), 3)
               if a[i:i+3] != b[i:i+3])


print("%-14s %14s %14s" % ("config", "lead OFF", "lead ON"))
for lyc in [int(x) for x in (sys.argv[1] if len(sys.argv) > 1 else "0").split(",")]:
    for k in [int(x) for x in (sys.argv[2] if len(sys.argv) > 2 else "1").split(",")]:
        rom = build(lyc, k)
        o = sameboy(rom, WORK + "/o")
        a = ding(OFF, rom, WORK + "/a.ppm")
        b = ding(ON, rom, WORK + "/b.ppm")
        print("LYC=%-3d k=%-3d %11d px %11d px%s"
              % (lyc, k, npx(a, o), npx(b, o),
                 "   <- lead ON matches" if npx(b, o) == 0 and npx(a, o) else
                 ("   <- lead OFF matches" if npx(a, o) == 0 and npx(b, o) else
                  ("   <- both match" if npx(a, o) == 0 and npx(b, o) == 0 else ""))))
