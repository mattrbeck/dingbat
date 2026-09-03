#!/usr/bin/env python3
"""Captures every page of a gbaedge-auto.gba run through dingbat's screenshot
mode and writes what an emulator PREDICTS for each page: a PPM + PNG per
page and one transcription file in the hwprobe_expected.py format (hex
pages only; visual pages get their picture).

    hwprobe_capture.py <dingbat_test> <gbaedge-auto.gba> <outdir> [--pages a,b,c]
        [--bios <path>] [--start <frame>]

The -auto build flips pages every 64 frames once the boot-time probes have
run; the viewer start frame is found by scanning for the first frame whose
title row OCRs as page 00, then page N is shot 32 frames into its window.
The OCR is exact (tests/roms/hwprobe_ocr.py's font-bitmap matcher) so a
transcription line is only emitted when all 32 bytes + CRC read cleanly;
visual pages emit a `page NN NAME visual` line and their PNG.
"""
import os
import struct
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gbaedge import PAGES                                   # noqa: E402
from gbedge import GLYPHS, FONT_ORDER                       # noqa: E402

PAGE_FRAMES = 64


# hwprobe_ocr.py runs on import (module-level argv loop), so its two
# helpers are repeated here rather than imported.
def glyph_bitmap(ch):
    rows = []
    for y in range(8):
        bits = 0
        if ch != " " and y < 7:
            for x, c in enumerate(GLYPHS[ch][y]):
                if c == "1":
                    bits |= 0x80 >> (x + 1)
        rows.append(bits)
    return tuple(rows)


BITMAPS = {glyph_bitmap(ch): ch for ch in FONT_ORDER}


def read_ppm(path):
    data = open(path, "rb").read()
    toks = []
    i = 0
    while len(toks) < 4:
        while i < len(data) and data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while data[i:i + 1] != b"\n":
                i += 1
            continue
        j = i
        while j < len(data) and not data[j:j + 1].isspace():
            j += 1
        toks.append(data[i:j])
        i = j
    assert toks[0] == b"P6", toks
    w, h = int(toks[1]), int(toks[2])
    return w, h, data[i + 1:]


def ocr(path):
    w, h, body = read_ppm(path)

    def lum(x, y):
        o = 3 * (y * w + x)
        return body[o] + body[o + 1] + body[o + 2]
    thr = (max(lum(x, y) for y in range(h) for x in range(0, w, 7)) +
           min(lum(x, y) for y in range(h) for x in range(0, w, 7))) // 2
    rows = []
    for row in range(h // 8):
        line = ""
        for col in range(w // 8):
            bits = []
            for y in range(8):
                b = 0
                for x in range(8):
                    if lum(col * 8 + x, row * 8 + y) < thr:
                        b |= 0x80 >> x
                bits.append(b)
            line += BITMAPS.get(tuple(bits), "?")
        rows.append(line)
    return rows


def write_png(path, ppm):
    w, h, body = read_ppm(ppm)
    raw = b"".join(b"\x00" + body[y * w * 3:(y + 1) * w * 3]
                   for y in range(h))

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + \
            struct.pack(">I", zlib.crc32(c))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def shoot(dingbat, rom, frames, out, bios):
    # --color: without it write_ppm greyscales the frame, which would throw
    # away the visual pages' colour legend (the OCR thresholds on luma
    # either way, so the hex pages read the same).
    cmd = [dingbat, rom, "--mode=screenshot", "--color",
           f"--timeout={frames}", f"--screenshot={out}"]
    if bios:
        cmd.append(f"--bios={bios}")
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)


def title_page(rows):
    # Hex pages put "GBAEDGE V1  Pnn" on row 0; a visual page draws it in
    # its BG0 footer (row 19), so every row is searched.
    for t in rows:
        i = t.find("GBAEDGE V1")
        if i < 0:
            continue
        t = t[i + 10:]
        if "P" not in t:
            continue
        try:
            return int(t.split("P")[-1][:2], 16)
        except ValueError:
            return None
    return None


def find_start(dingbat, rom, tmp, bios):
    """First frame on which page 00 is up (the viewer start), by a coarse
    scan then a 4-frame bisection."""
    # page 00 is up for 64 frames, so a 64-frame comb cannot miss it
    lo, hi = 0, PAGE_FRAMES
    while True:
        shoot(dingbat, rom, hi, tmp, bios)
        if title_page(ocr(tmp)) == 0:
            break
        lo, hi = hi, hi + PAGE_FRAMES
        if hi > 4096:
            raise SystemExit("viewer never started (page 00 not seen)")
    while hi - lo > 4:
        mid = (lo + hi) // 2
        shoot(dingbat, rom, mid, tmp, bios)
        lo, hi = (lo, mid) if title_page(ocr(tmp)) == 0 else (mid, hi)
    return hi


def parse_hex_page(rows):
    """-> (name, crc, all, bytes) or None when any cell failed to OCR."""
    try:
        name = rows[2][:10].strip()
        data = []
        for off in range(0, 32, 4):
            r = rows[4 + off // 4]
            assert r[:2] == f"{off:02X}"
            for col in range(4):
                data.append(int(r[3 + col * 3:5 + col * 3], 16))
        assert rows[13].startswith("CRC ")
        crc = rows[13][4:8]
        assert rows[14].startswith("ALL ")
        allc = rows[14][4:8]
        int(crc, 16)
        int(allc, 16)
        return name, crc, allc, data
    except (AssertionError, ValueError, IndexError):
        return None


def main():
    args = sys.argv[1:]
    bios = None
    only = None
    start = None
    pos = []
    i = 0
    while i < len(args):
        if args[i] == "--bios":
            bios = args[i + 1]
            i += 2
        elif args[i] == "--pages":
            only = [int(p) for p in args[i + 1].split(",")]
            i += 2
        elif args[i] == "--start":
            start = int(args[i + 1])
            i += 2
        else:
            pos.append(args[i])
            i += 1
    dingbat, rom, outdir = pos
    os.makedirs(outdir, exist_ok=True)
    tmp = os.path.join(outdir, "_scan.ppm")
    if start is None:
        start = find_start(dingbat, rom, tmp, bios)
    print(f"viewer start frame: {start}")
    lines = [f"# dingbat PREDICTION for {os.path.basename(rom)} — not hardware",
             "platform: gba", f"console: dingbat_test screenshot harness, "
             f"viewer start frame {start}, each page shot mid-window", ""]
    allc = None
    # A page is up for 64 viewer iterations plus however long its redraw
    # took (the ALL CRC alone is about a frame), so the period is a little
    # over 64 frames: shoot at the running estimate and walk forward in
    # 4-frame steps until the title row reads the wanted page.
    period = PAGE_FRAMES + 2
    est = start + period // 2
    last_n = 0
    for n in (only if only is not None else range(len(PAGES))):
        ppm = os.path.join(outdir, f"p{n:02d}.ppm")
        frame = est + period * (n - last_n)
        for attempt in range(24):
            shoot(dingbat, rom, frame, ppm, bios)
            rows = ocr(ppm)
            got = title_page(rows)
            if got == n:
                break
            if got is not None and got > n:
                frame -= 4
            else:
                frame += 4
        else:
            print(f"page {n:02d}: title row reads {rows[0]!r} (expected P{n:02X})")
        # The walk lands on the first frame whose title reads page n, which
        # is mid-redraw: a visual page repaints under forced blank for more
        # than a frame, so the top of the screen is still blank there. Take
        # the real shot 12 frames later, unless that has already flipped to
        # the next page (which means the walk approached from above and
        # this frame is near the END of the window: already fully drawn).
        settled = os.path.join(outdir, "_settle.ppm")
        shoot(dingbat, rom, frame + 12, settled, bios)
        settled_rows = ocr(settled)
        if title_page(settled_rows) == n:
            os.replace(settled, ppm)
            rows = settled_rows
        elif os.path.exists(settled):
            os.unlink(settled)
        est, last_n = frame, n
        write_png(os.path.join(outdir, f"p{n:02d}.png"), ppm)
        parsed = parse_hex_page(rows)
        if parsed is None:
            lines.append(f"page {n:02X} {PAGES[n]} visual   # p{n:02d}.png")
            print(f"page {n:02d} {PAGES[n]}: visual/unparsed -> p{n:02d}.png")
            continue
        name, crc, allc, data = parsed
        lines.append(f"page {n:02X} {name} crc {crc}")
        for off in range(0, 32, 16):
            lines.append(" ".join(f"{b:02X}" for b in data[off:off + 16]))
        print(f"page {n:02d} {name}: crc {crc} all {allc}")
    if allc:
        lines.insert(3, f"all: {allc}")
    with open(os.path.join(outdir, "pages.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    if os.path.exists(tmp):
        os.unlink(tmp)


if __name__ == "__main__":
    main()
