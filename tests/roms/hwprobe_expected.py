#!/usr/bin/env python3
"""Renders expected-result PNGs for the hwprobe ROMs from a hardware
transcription file.

The probe ROMs (gbedge.gb / gbaedge.gba) display raw observed values; real
hardware is the oracle.  Once a console run has been transcribed (see
tests/roms/expected/*.txt), this script re-renders every page exactly as
the ROM's own viewer would draw it — same font, same cell layout, same
colors — so the committed PNGs show *hardware truth*, including on pages
an emulator currently gets wrong.  A dingbat screenshot of a page is
byte-identical to the PNG if and only if dingbat agrees with hardware on
that page (and on the ALL line, with the whole run).

Usage:
    python3 hwprobe_expected.py expected/agb-sp-1.txt [outdir]

Transcription format (one file per console run):
    platform: gba                    # gba | gb (gb: 160x144, same idea)
    console: GBA SP AGS-001, EverDrive GBA, 2026-08-10
    all: F54C
    page 00 IDENT crc 985C
    7F 18 AE BA 80 00 00 00 ... (32 bytes, whitespace/newlines free)
    page 08 MSRTBIT crc DCB3
    ...
    page 08+ MSRTBIT crc 6DA2 all 1512    # '+' = post-START variant;
    ...                                   # per-page 'all' overrides
"""
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gbedge import font_1bpp, tile_of                     # noqa: E402
from gbaedge import PAGES as GBA_PAGES                    # noqa: E402

WHITE, BLACK = (255, 255, 255), (0, 0, 0)


def parse(path):
    meta, pages, cur = {}, [], None
    for raw in open(path):
        line = raw.split("#")[0].strip()
        if not line:
            continue
        if ":" in line and cur is None and not line.startswith("page"):
            k, v = line.split(":", 1)
            meta[k.strip()] = v.strip()
            continue
        if line.startswith("page "):
            t = line.split()
            num, post = (t[1].rstrip("+"), t[1].endswith("+"))
            page = {"num": int(num, 16), "post": post, "name": t[2],
                    "crc": t[t.index("crc") + 1],
                    "all": t[t.index("all") + 1] if "all" in t else None,
                    "bytes": []}
            pages.append(page)
            cur = page
            continue
        cur["bytes"] += [int(b, 16) for b in line.split()]
    for p in pages:
        assert len(p["bytes"]) == 32, (p["num"], len(p["bytes"]))
    return meta, pages


def write_png(path, pix, w, h):
    raw = b"".join(b"\x00" + bytes(v for px in row for v in px)
                   for row in pix)
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + \
            struct.pack(">I", zlib.crc32(c))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


class Grid:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.font = font_1bpp()
        self.pix = [[WHITE] * w for _ in range(h)]

    def glyph(self, cx, cy, tile):
        for r in range(8):
            bits = self.font[tile * 8 + r]
            for c in range(8):
                if bits & (0x80 >> c):
                    self.pix[cy * 8 + r][cx * 8 + c] = BLACK

    def text(self, cx, cy, s):
        for i, ch in enumerate(s):
            self.glyph(cx + i, cy, tile_of(ch))

    def hex8(self, cx, cy, v):
        self.glyph(cx, cy, (v >> 4) + 1)      # print_hex8: tile = nibble+1
        self.glyph(cx + 1, cy, (v & 0xF) + 1)


def render_gba(page, all_crc, ident):
    g = Grid(240, 160)
    g.text(0, 0, "GBAEDGE V1")
    g.text(15, 0, "P")
    g.hex8(16, 0, page["num"])
    g.text(0, 2, GBA_PAGES[page["num"]].ljust(10))
    for off in range(0, 32, 4):
        y = 4 + off // 4
        g.hex8(0, y, off)
        for col in range(4):
            g.hex8(3 + col * 3, y, page["bytes"][off + col])
    g.text(0, 13, "CRC ")
    g.hex8(4, 13, int(page["crc"], 16) >> 8)
    g.hex8(6, 13, int(page["crc"], 16) & 0xFF)
    g.text(0, 14, "ALL ")
    g.hex8(4, 14, int(all_crc, 16) >> 8)
    g.hex8(6, 14, int(all_crc, 16) & 0xFF)
    if page["num"] == 8:
        g.text(0, 15, "PRESS START")
    g.text(0, 16, "MODEL ")
    g.hex8(6, 16, ident[1])
    g.hex8(9, 16, ident[0])
    return g


def main():
    src = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) > 2 else \
        os.path.join(os.path.dirname(src) or ".",
                     os.path.splitext(os.path.basename(src))[0])
    meta, pages = parse(src)
    assert meta["platform"] == "gba", "gb rendering lands with gb hardware"
    os.makedirs(outdir, exist_ok=True)
    ident = next(p for p in pages if p["num"] == 0 and not p["post"])
    for p in pages:
        g = render_gba(p, p["all"] or meta["all"], ident["bytes"])
        name = f"p{p['num']:02d}{'-post' if p['post'] else ''}.png"
        write_png(os.path.join(outdir, name), g.pix, g.w, g.h)
        print(os.path.join(outdir, name))


if __name__ == "__main__":
    main()
