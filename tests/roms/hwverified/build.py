#!/usr/bin/env python3
"""Builds the per-fix hardware proof ROMs.

Each probe is a single .s file that includes the shared runtime
(runtime.inc: cart header, mode-3 init, 8x8 font renderer, hex dump of a
32-byte result slot).  Every ROM runs its single experiment at boot,
draws the raw observed bytes as hex on screen and loops forever, so a
photo of real hardware and an emulator screenshot are directly
comparable.

Build recipe follows gbaedge.py: arm-none-eabi-as -mcpu=arm7tdmi,
ld -Ttext=0x08000000, objcopy -O binary, then the Nintendo logo, title
and header complement are patched in.

Requires arm-none-eabi-{as,ld,objcopy}.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

ROMS = [
    "msrtbit", "psrmask", "thumbcmp", "ldmuser", "pcwb", "bxdecode",
    "irqwin", "dmabyte", "capdma", "sweep", "iomap",
]

# The compressed Nintendo logo every bootable cart carries at 0x04-0x9F.
LOGO = bytes.fromhex(
    "24ffae51699aa2213d84820a84e409ad11248b98c0817f21a352be199309ce"
    "2010464a4af82731ec58c7e83382e3cebf85f4df94ce4b09c194568ac01372"
    "a7fc9f844d73a3ca9a615897a327fc039876231dc7610304ae56bf38840040"
    "a70efdff52fe036f9530f197fbc08560d68025a963be03014e38e2f9a234ff"
    "bb3e0344780090cb88113a9465c07c6387f03cafd625e48b380aac7221d4f8"
    "07")

FONT_ORDER = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-/."


def gen_font_inc():
    # font_gen.inc (8x8 1bpp glyphs in FONT_ORDER) is checked in; it only
    # needs regenerating if the glyph set changes.
    if not os.path.exists(os.path.join(HERE, "font_gen.inc")):
        raise SystemExit("font_gen.inc is missing")


def build(name):
    src = os.path.join(HERE, name + ".s")
    o, elf, gba = (os.path.join(HERE, name + ext)
                   for ext in (".o", ".elf", ".gba"))
    subprocess.run(["arm-none-eabi-as", "-mcpu=arm7tdmi", "-o", o, src],
                   check=True, cwd=HERE)
    subprocess.run(["arm-none-eabi-ld", "-Ttext=0x08000000", "-o", elf, o],
                   check=True, cwd=HERE)
    subprocess.run(["arm-none-eabi-objcopy", "-O", "binary", elf, gba],
                   check=True, cwd=HERE)
    rom = bytearray(open(gba, "rb").read())
    rom[0x04:0xA0] = LOGO
    title = name.upper().encode().ljust(12, b"\0")[:12]
    rom[0xA0:0xAC] = title
    rom[0xAC:0xB0] = b"AHWP"
    rom[0xB0:0xB2] = b"01"
    rom[0xB2] = 0x96
    c = 0
    for i in range(0xA0, 0xBD):
        c = (c - rom[i]) & 0xFF
    rom[0xBD] = (c - 0x19) & 0xFF
    open(gba, "wb").write(rom)
    os.unlink(o)
    os.unlink(elf)
    print(f"{gba}: {len(rom)} bytes")


if __name__ == "__main__":
    gen_font_inc()
    targets = sys.argv[1:] or ROMS
    for name in targets:
        build(name)
