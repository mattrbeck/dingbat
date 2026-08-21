#!/usr/bin/env python3
"""Move daid's `ppu_scanline_bgp` anchor off the LY 153 -> 0 snapback, and ask
SameBoy which dingbat build is right on the DMG.

WHY THIS EXISTS
---------------
`daid/ppu_scanline_bgp` is the only instrument in the tree that pins the mode-3
pixel pipeline's phase against something other than the mode 2 interrupt. It
takes ONE STAT `LYC = 0` interrupt out of `ei ; halt`, pops the return address
and never returns, then free-runs a 114-M-cycle loop of BGP writes -- exactly
one scanline -- for the whole frame. One anchor, 144 lines of ruler.

That makes it two measurements welded together: the pipeline's phase AND the
dot its anchor fires on. For two rounds its DMG frame was read as a refusal of
`M3_PIPE_AHEAD = 1`, and it is not one -- it is the snapback wake that is out.
Separating them needs nothing more than arming a different LYC.

`daidsweep.py` next door does the same thing by rebuilding the cart from source
with rgbds. This does it with ONE PATCHED BYTE and no toolchain:

    ld a, IEF_LCDC | IEF_VBLANK   ; 3E 03   <- A is $03 from here
    ldh [rIE], a                  ; E0 FF
    xor a                         ; AF      <- $178, the byte we patch
    ldh [rLYC], a                 ; E0 45

so `AF` -> `3C` (`inc a`) arms LYC = 4 and `AF` -> `3D` (`dec a`) arms LYC = 2,
both ordinary lines, with the instruction length, the header checksum and every
other cycle of the ROM untouched. Nothing else in the cart reads A there.

WHAT IT ANSWERED, 2026-08-20 (dingbat DMG, wrong pixels vs SameBoy)

    anchor                  M3_PIPE_AHEAD=0    =1     =1 + LYC_SETTLE_HALT_SKIP
    LYC = 0  (snapback)         0            2656              0
    LYC = 2  (normal line)   2655               0              0
    LYC = 4  (normal line)   2655               0              0

SameBoy reproduces the shootout's own `ppu_scanline_bgp_1.dmg.png` exactly at
LYC = 0, so the oracle is anchored to the reference before it is asked anything.

TWO THINGS TO KNOW BEFORE READING A NUMBER OUT OF THIS
------------------------------------------------------
* SameBoy's DMG panel colours are $FF/$AD/$52/$00 and the reference PNGs' are
  $FF/$AA/$55/$00. Compare SHADE RANK, not RGB, or every pixel differs.
* dingbat's `dmg0` boot table is a different machine and matches neither the
  reference nor the oracle (928 px at LYC = 0). `dmgABC` (the default) and
  `mgb` are identical to each other and are what the shootout scores.

USAGE
    tools/gbppu/daidanchor.py <dingbat_test> [<dingbat_test> ...]
"""
import os
import subprocess
import sys
import tempfile

SHOOT = os.environ.get("SHOOTOUT",
                       os.path.expanduser("~/code/GBEmulatorShootout")) + "/testroms"
SB = os.environ.get("SAMEBOY_RUNNER",
                    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "..", "gbfuzz", "sameboy_runner"))
BR = os.environ.get("SAMEBOY_BOOT",
                    os.path.expanduser("~/code/SameBoy/build/bin/BootROMs"))
ROM = SHOOT + "/daid/ppu_scanline_bgp.gb"
SHOTS = 600

# LYC value -> the byte that replaces `xor a` at $178. A holds $03 there.
PATCH = {0: 0xAF, 2: 0x3D, 4: 0x3C}
LYC_PATCH_OFFSET = 0x178


def rom_for(lyc, work):
    d = bytearray(open(ROM, "rb").read())
    assert d[LYC_PATCH_OFFSET:LYC_PATCH_OFFSET + 3] == b"\xAF\xE0\x45", \
        "unexpected bytes at $178 -- is this daid's ppu_scanline_bgp.gb?"
    d[LYC_PATCH_OFFSET] = PATCH[lyc]
    p = "%s/lyc%d.gb" % (work, lyc)
    open(p, "wb").write(bytes(d))
    return p


def ppm(path):
    """Raw RGB bytes out of a binary PPM, header skipped."""
    b = open(path, "rb").read()
    i, fields = 0, 0
    while fields < 4:
        if b[i:i + 1] == b"#":
            while b[i:i + 1] != b"\n":
                i += 1
        elif b[i:i + 1].isspace():
            i += 1
        else:
            while not b[i:i + 1].isspace():
                i += 1
            fields += 1
    return b[i + 1:]


def shades(buf):
    """RGB -> shade rank 0..3, so the two LCD tints compare."""
    return bytes(0 if buf[i] > 200 else 1 if buf[i] > 130 else
                 2 if buf[i] > 40 else 3 for i in range(0, len(buf), 3))


def npx(a, b):
    a, b = shades(a), shades(b)
    return sum(1 for i in range(min(len(a), len(b))) if a[i] != b[i])


def sameboy(rom, prefix):
    env = dict(os.environ, GBFUZZ_MODEL="dmg")
    r = subprocess.run([SB, rom, BR, prefix, "", str(SHOTS)],
                       capture_output=True, env=env)
    f = "%s.f%04d.ppm" % (prefix, SHOTS)
    if not os.path.exists(f):
        sys.exit("sameboy_runner produced nothing: " + r.stderr.decode()[:400])
    return ppm(f)


def ding(binary, rom, out, model, work):
    subprocess.run([binary, rom, "--mode=screenshot", "--timeout=%d" % SHOTS,
                    "--screenshot=" + out, "--nosave", "--model=" + model],
                   cwd=work, capture_output=True)
    return ppm(out)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__.rstrip().rsplit("USAGE", 1)[-1].strip())
    work = tempfile.mkdtemp(prefix="daidanchor-")
    models = os.environ.get("DMG_MODELS", "dmg").split(",")
    print("%-8s %s" % ("anchor", "  ".join(
        "%s/%s" % (os.path.basename(b), m) for b in sys.argv[1:] for m in models)))
    for lyc in (0, 2, 4):
        rom = rom_for(lyc, work)
        oracle = sameboy(rom, work + "/sb%d" % lyc)
        cells = []
        if lyc == 0:
            for i in range(3):
                ref = ppm_from_png(SHOOT + "/daid/ppu_scanline_bgp_%d.dmg.png" % i)
                cells.append("ref_%d:%d" % (i, npx(oracle, ref)))
        for b in sys.argv[1:]:
            for m in models:
                cells.append("%s/%s:%d" % (os.path.basename(b), m,
                                           npx(ding(b, rom, work + "/d.ppm", m, work),
                                               oracle)))
        print("LYC=%-4d %s" % (lyc, "  ".join(cells)))


def ppm_from_png(path):
    from PIL import Image
    im = Image.open(path).convert("RGB")
    return b"".join(bytes(im.getpixel((x, y)))
                    for y in range(im.height) for x in range(im.width))


if __name__ == "__main__":
    main()
