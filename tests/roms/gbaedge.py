#!/usr/bin/env python3
"""Builds gbaedge.gba (+ gbaedge-auto.gba) — the GBA hardware edge-case
probe ROM.  Sibling of gbedge.py, same philosophy: every probe records RAW
observed values into a 32-byte result slot, a viewer pages through hex
dumps (LEFT/RIGHT or A/B), and real hardware is the oracle.  The -auto
variant flips pages every 64 frames for input-less screenshot harnesses.

The assembly lives in gbaedge.s; this script generates the font/name-table
include from gbedge.py's glyph set (so ocr.py can read both platforms'
screenshots), assembles with arm-none-eabi-as, links at 0x08000000, and
patches a valid cart header (Nintendo logo + complement) so the ROM boots
on real hardware from a flash cart.

Requires arm-none-eabi-{as,ld,objcopy} (Homebrew: gcc-arm-embedded or
binutils build — the same ones the other .s ROMs here document).
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gbedge import FONT_ORDER, font_1bpp, tile_of        # noqa: E402

PAGES = ["IDENT", "OPENBUS", "BIOSPROT", "SWITIME", "TIMERS", "DMALATCH",
         "LDMSTM", "MULFLAGS", "MSRTBIT", "PPUSTAT", "PSGSTAT", "WAITSTATE",
         "PFPHASE", "SWIREGION", "CONTEND", "IRQLAT", "IORW", "CPSRBITS",
         "THUMBPC", "LDMUSER", "IRQWIN", "DMAEDGE", "CAPDMA", "SWEEPQ",
         "BXDECODE", "THUMBPC2", "IRQWIN2", "IOBYTE"]

# The compressed Nintendo logo every bootable cart carries at 0x04-0x9F.
LOGO = bytes.fromhex(
    "24ffae51699aa2213d84820a84e409ad11248b98c0817f21a352be199309ce"
    "2010464a4af82731ec58c7e83382e3cebf85f4df94ce4b09c194568ac01372"
    "a7fc9f844d73a3ca9a615897a327fc039876231dc7610304ae56bf38840040"
    "a70efdff52fe036f9530f197fbc08560d68025a963be03014e38e2f9a234ff"
    "bb3e0344780090cb88113a9465c07c6387f03cafd625e48b380aac7221d4f8"
    "07")


def gen_inc():
    lines = [f".equ NPAGES, {len(PAGES)}", ""]
    lines.append(".global font_data")
    lines.append("font_data:")
    fd = font_1bpp()
    for i in range(0, len(fd), 8):
        lines.append("    .byte " + ",".join(f"0x{b:02X}" for b in fd[i:i+8]))
    lines.append("")
    lines.append(".global name_table")
    lines.append("name_table:")
    for name in PAGES:
        tiles = [tile_of(c) for c in name.ljust(10)]
        lines.append("    .byte " + ",".join(str(t) for t in tiles) +
                     f"   @ {name}")
    for label, text in (("str_title", "GBAEDGE V1"), ("str_crc", "CRC "),
                        ("str_all", "ALL "), ("str_model", "MODEL "),
                        ("str_press", "PRESS START"),
                        ("str_ran", "RAN-SEE 00")):
        lines.append(f".global {label}")
        lines.append(f"{label}:")
        lines.append("    .byte " +
                     ",".join(str(tile_of(c)) for c in text))
        lines.append(f".equ {label}_len, {len(text)}")
    lines.append(".align 2")
    with open(os.path.join(HERE, "gbaedge_gen.inc"), "w") as f:
        f.write("\n".join(lines) + "\n")


def build(auto):
    out = "gbaedge-auto" if auto else "gbaedge"
    defs = ["--defsym", "AUTOPAGE=1"] if auto else []
    o, elf, gba = (os.path.join(HERE, out + ext)
                   for ext in (".o", ".elf", ".gba"))
    subprocess.run(["arm-none-eabi-as", "-mcpu=arm7tdmi", *defs,
                    "-o", o, os.path.join(HERE, "gbaedge.s")],
                   check=True, cwd=HERE)
    subprocess.run(["arm-none-eabi-ld", "-Ttext=0x08000000",
                    "-o", elf, o], check=True, cwd=HERE)
    subprocess.run(["arm-none-eabi-objcopy", "-O", "binary", elf, gba],
                   check=True, cwd=HERE)
    rom = bytearray(open(gba, "rb").read())
    rom[0x04:0xA0] = LOGO
    rom[0xA0:0xAC] = b"GBAEDGE\0\0\0\0\0"
    rom[0xAC:0xB0] = b"AGBE"
    rom[0xB0:0xB2] = b"01"
    rom[0xB2] = 0x96
    c = 0
    for i in range(0xA0, 0xBD):
        c = (c - rom[i]) & 0xFF
    rom[0xBD] = (c - 0x19) & 0xFF
    open(gba, "wb").write(rom)
    os.unlink(o)
    os.unlink(elf)
    print(f"{gba}: {len(rom)} bytes, {len(PAGES)} pages")


if __name__ == "__main__":
    gen_inc()
    build(False)
    build(True)
