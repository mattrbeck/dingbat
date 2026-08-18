#!/usr/bin/env python3
"""Perturb daid's ppu_scanline_bgp source and ask which dingbat build SameBoy agrees with.

The ROM is 91 lines. It takes ONE STAT LYC interrupt out of `halt`, discards the
return address and free-runs a 114-M loop (10 BGP writes 4 M apart + 70 nops +
jp) that stays scanline-locked for the whole frame, so its 1440 band edges are a
ruler for the palette write's phase against ONE anchor.

Two knobs, both one line of source:

  --lyc N   which line the anchor fires on. 0 (shipped) is the LY 153 -> 0
            SNAPBACK, which dingbat special-cases; anything else is a normal
            line, which is what cgb-acid-hell's 144 anchors are. This is the
            candidate discriminator between the two ROMs.
  k         M-cycles of delay before the loop, spent as the count of nops
            between statInt's `ei` and `ld hl, data` (shipped: 1). Unlike
            acid-hell this ROM is not full and has no raw-address jumps, so
            these can simply be inserted or removed.

Prints, per config, which of dingbat-lead-off / dingbat-lead-on reproduces
SameBoy exactly. SameBoy is run with GBFUZZ_MODEL=cgb because the cart is
DMG-flagged and the machine under test is a CGB in COMPATIBILITY mode; it
reproduces daid's own reference pixel-exactly there. (That env var was added to
tools/gbfuzz/sameboy_runner.c for this: the runner otherwise picks its model off
byte $143 and would answer a DMG's question. Setting the CGB flag in the header
instead boots CGB-NATIVE, which is a third machine and not the one captured.)

The answer it gave, 2026-08-18:

    LYC = 0  (the LY 153 -> 0 snapback)   lead OFF exact, lead ON 2304 px
    LYC = 1, 8, 40, 100 (normal lines)    lead ON exact, lead OFF 1920-2304 px

which is what put CGB_HALT_LEAD_SKIP_LYC0 in gb.nim, and what reconciled this
ROM with cgb-acid-hell.

---- Getting the source to build ----------------------------------------------

It ships WITH the shootout, at testroms/daid/. Copy ppu_scanline_bgp.asm,
common.inc, hardware.inc and font.bin into $DAID_SRC, then apply the same
pre-0.6-rgbds fixes cgb-acid-hell needs (see hellsrc.py) plus, in BOTH the .asm
and common.inc, `ld a, [rXX]` / `ld [rXX], a` -> `ldh ...`: old rgbasm optimised
those to the two-byte form automatically and modern rgbasm emits the three-byte
LD A,(nn), which is a whole extra M-cycle per access. With those and the
halt-nops the rebuild is byte-exact, md5 16ec1c02eaed01bf16616e268428d4a8 --
check that before trusting any number out of this script.

Unlike acid-hell this ROM is not full and has no raw-address jumps, so nops here
can simply be inserted or deleted.
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
