#!/usr/bin/env python3
"""Perturb ONE scanline of cgb-acid-hell's source and compare the two emulators.

The ROM is fully unrolled: one block per scanline, each of which sets rLYC,
clears rIF, HALTs on the STAT LYC interrupt, writes rSCY, idles 17 nops and then
performs 16 `ld [hl], r` writes to LCDC (hl = $ff40), two M-cycles = 8 dots
apart. Lines 67..70 are byte-identical apart from rSCY. Because every line
re-anchors on its own halt, a nop inserted in one block moves that line's writes
4 dots later and leaves all 143 others untouched -- so the rest of the frame is
a control, and the answer to "how many dots is dingbat out on this line" can be
read directly off the screen.

    hellsrc.py <ly> <k> [--scy HEX]

Builds, runs both emulators, prints the block x=72..96 for ly-4..ly+4 from each.
See hellall.py for the whole-frame version, which is the one that measured the
constant.

---- Getting the source to build ----------------------------------------------

`git clone https://github.com/mattcurrie/cgb-acid-hell` into $ACID_HELL_SRC
(default $TMPDIR/cgb-acid-hell). It is an mgbdis disassembly written for a
pre-0.6 rgbds and needs four mechanical fixes to assemble with ours; with all
four it rebuilds the shipped ROM BYTE-EXACT, md5
cdf25d29ff8504d28a87bb8d20f7f698, which is the only thing that makes any
experiment below meaningful:

  1. `NAME: MACRO` -> `MACRO NAME`, in the .asm and in hardware.inc (which also
     spells one of them `name : MACRO`, with a space).
  2. hardware.inc's bare `X EQU y` / `X SET y` -> `DEF X EQU y` / `DEF X = y`.
  3. `ld [c], a` / `ld a, [c]` -> `ldh ...`, and `ldh a, [$34]` -> the full
     `ldh a, [$ff34]`.
  4. **A `nop` after every one of the 136 `halt`s.** Old rgbasm inserted it
     automatically and modern rgbasm does not. Miss it and the ROM is one byte
     short per halt -- which on this ROM is 4 dots of PPU phase per line, i.e.
     exactly the quantity under study.

---- Why the perturbation is a SUBSTITUTION and not an insertion --------------

ROM0 is exactly full ($4000) so nothing can be added, and the disassembly
carries 29 raw-address jumps (`jp $0150`), so nothing can be moved either --
delete one nop and the whole frame goes blank in BOTH emulators, which is what a
shifted `jp` target looks like. So k M-cycles of delay are bought by rewriting k
of a block's 17 idle `nop`s ($00, one byte, one M-cycle) as `ld a, [hl]` ($7E,
one byte, TWO). `a` is dead there -- it last carried SCY and is not read again
until the `ld a, $xx` that ends the block -- and `hl` is $ff40, so the read is of
LCDC and has no side effect.
"""
import os, re, subprocess, sys, shutil

TMP = os.environ.get("HELL_TMP", os.environ.get("TMPDIR", "/tmp"))
SRC = os.environ.get("ACID_HELL_SRC", TMP + "/cgb-acid-hell")
WORK = TMP + "/hellwork"
RG = os.environ.get("RGBDS", os.path.abspath(".scratch/rgbds"))
DINGBAT = os.environ.get("DINGBAT", "./dingbat_test")
SB = os.environ.get("SAMEBOY_RUNNER", "tools/gbfuzz/sameboy_runner")
BR = os.path.expanduser("~/code/SameBoy/build/bin/BootROMs")


def blocks(lines):
    out = []
    for i, l in enumerate(lines):
        if 'ldh [rLYC], a' in l:
            m = re.match(r'\s*ld a, \$([0-9a-fA-F]+)', lines[i - 1])
            out.append((int(m.group(1), 16) if m else None, i))
    return out


def build(ly, nops, scy=None):
    os.makedirs(WORK, exist_ok=True)
    for f in ("cgb-acid-hell.asm", "hardware.inc"):
        shutil.copy(SRC + "/" + f, WORK + "/" + f)
    p = WORK + "/cgb-acid-hell.asm"
    L = open(p).read().split('\n')
    bl = blocks(L)
    idx = {v: i for i, (v, _) in enumerate(bl) if v is not None}
    start = bl[idx[ly]][1]
    end = bl[idx[ly] + 1][1] if idx[ly] + 1 < len(bl) else len(L)
    # rSCY write is the anchor inside the block; insert right after it.
    for i in range(start, end):
        if 'ldh [rSCY], a' in L[i]:
            if scy is not None:
                L[i - 1] = "    ld a, $%02x" % scy
            # BYTE-PRESERVING delay. ROM0 is exactly full ($4000) so nothing can
            # be added, and the disassembly carries 29 RAW-ADDRESS jumps
            # (`jp $0150` ...), so nothing can be moved either -- deleting one
            # nop blanks the whole frame in both emulators, which is what a
            # shifted `jp` target looks like.
            #
            # So substitute instead: `nop` is $00, one byte and one M-cycle;
            # `ld a, [hl]` is $7E, one byte and TWO. Swapping k of the block's
            # 17 idle nops delays its 16 LCDC writes by exactly k M-cycles = 4k
            # dots at identical size. `a` is dead here -- it last carried SCY
            # and is not read again until the `ld a, $xx` that ends the block --
            # and hl is $ff40, so the read is of LCDC and has no side effect.
            d = nops
            j = i + 1
            while d > 0 and j < end:
                if L[j].strip() == 'nop':
                    L[j] = "    ld a, [hl]  ; was nop: +1 M, same byte"
                    d -= 1
                j += 1
            if d:
                sys.exit("not enough idle nops in the LY %d block" % ly)
            break
    else:
        sys.exit("no rSCY write in the LY %d block" % ly)
    open(p, 'w').write('\n'.join(L))
    for cmd in ([RG + "/rgbasm", "-o", "h.o", "cgb-acid-hell.asm"],
                [RG + "/rgblink", "-o", "h.gbc", "h.o"],
                [RG + "/rgbfix", "-v", "-p", "255", "h.gbc"]):
        r = subprocess.run(cmd, cwd=WORK, capture_output=True)
        if r.returncode:
            sys.exit(r.stderr.decode()[:600])
    return WORK + "/h.gbc"


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
    return w, [[tuple(px[(y * w + x) * 3:(y * w + x) * 3 + 3])
                for x in range(w)] for y in range(144)]


def main():
    ly, nops = int(sys.argv[1]), int(sys.argv[2])
    scy = None
    if "--scy" in sys.argv:
        scy = int(sys.argv[sys.argv.index("--scy") + 1], 16)
    rom = build(ly, nops, scy)
    subprocess.run([DINGBAT, rom, "--mode=screenshot", "--cgb", "--color",
                    "--timeout=120", "--screenshot=" + WORK + "/d.ppm"],
                   capture_output=True)
    subprocess.run([SB, rom, BR, WORK + "/o", "", "240"], capture_output=True)
    _, A = read_ppm(WORK + "/d.ppm")
    _, B = read_ppm(WORK + "/o.f0240.ppm")
    keys, names = {}, "abcdefghijklmnopqrstuvwxyz"

    def k(c):
        if c not in keys:
            keys[c] = names[len(keys)]
        return keys[c]
    print("LY %d + %d nop%s%s" % (ly, nops, "" if nops == 1 else "s",
                                 "" if scy is None else "  scy=$%02x" % scy))
    for y in range(max(0, ly - 4), min(144, ly + 5)):
        a = "".join(k(A[y][x]) for x in range(72, 96))
        b = "".join(k(B[y][x]) for x in range(72, 96))
        print("  ly%3d ding %s   oracle %s %s"
              % (y, a, b, "" if a == b else "<<<"))
    print("  legend " + " ".join("%s=%s" % (v, c) for c, v in keys.items()))


main()
