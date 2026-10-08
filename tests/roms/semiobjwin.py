#!/usr/bin/env python3
"""Builds semiobjwin.gba (see semiobjwin.s for the experiment).

Same recipe as hwverified/build.py: arm-none-eabi-as -mcpu=arm7tdmi,
ld -Ttext=0x08000000, objcopy -O binary, title and complement patched in
here, logo written by gbafix (romfix.py). Requires arm-none-eabi-{as,ld,
objcopy} and gbafix.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import romfix  # noqa: E402


def build(name="semiobjwin"):
    src = os.path.join(HERE, name + ".s")
    o, elf, gba = (os.path.join(HERE, name + ext) for ext in (".o", ".elf", ".gba"))
    subprocess.run(["arm-none-eabi-as", "-mcpu=arm7tdmi", "-o", o, src], check=True)
    subprocess.run(["arm-none-eabi-ld", "-Ttext=0x08000000", "-o", elf, o], check=True)
    subprocess.run(["arm-none-eabi-objcopy", "-O", "binary", elf, gba], check=True)
    rom = bytearray(open(gba, "rb").read())
    rom[0xA0:0xAC] = name.upper().encode().ljust(12, b"\0")[:12]
    rom[0xAC:0xB0] = b"ASOW"
    rom[0xB0:0xB2] = b"01"
    rom[0xB2] = 0x96
    c = 0
    for i in range(0xA0, 0xBD):
        c = (c - rom[i]) & 0xFF
    rom[0xBD] = (c - 0x19) & 0xFF
    open(gba, "wb").write(rom)
    romfix.gba_logo(gba)
    os.unlink(o)
    os.unlink(elf)
    print(f"{gba}: {len(rom)} bytes")


if __name__ == "__main__":
    build()
