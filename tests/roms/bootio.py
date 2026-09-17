#!/usr/bin/env python3
"""Builds bootio.gba — the I/O register file a ROM finds at entry, plus
serial-register write/read-back experiments (bootio.s says what each word
is).  Run it on hardware with no link cable and photograph the 4 pages.

    python3 bootio.py            build
    python3 bootio.py words F    decode a 720-byte data dump F (e.g. peeked
                                 from 0x02000000 in an emulator)

Requires arm-none-eabi-{as,ld,objcopy} and gbafix, like gbaedge.py.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gbedge import font_1bpp, tile_of        # noqa: E402
import romfix                                # noqa: E402


def gen_inc():
    lines = [".global font_data", "font_data:"]
    fd = font_1bpp()
    for i in range(0, len(fd), 8):
        lines.append("    .byte " + ",".join(f"0x{b:02X}" for b in fd[i:i+8]))
    for label, text in (("str_title", "BOOTIO V1 P"), ("str_crc", "CRC "),
                        ("str_all", "ALL ")):
        lines.append(f"{label}:")
        lines.append("    .byte " + ",".join(str(tile_of(c)) for c in text))
        lines.append(f".equ {label}_len, {len(text)}")
    lines.append(".align 2")
    with open(os.path.join(HERE, "bootio_gen.inc"), "w") as f:
        f.write("\n".join(lines) + "\n")


def build():
    o, elf, gba = (os.path.join(HERE, "bootio" + ext) for ext in (".o", ".elf", ".gba"))
    subprocess.run(["arm-none-eabi-as", "-mcpu=arm7tdmi", "-o", o,
                    os.path.join(HERE, "bootio.s")], check=True, cwd=HERE)
    subprocess.run(["arm-none-eabi-ld", "-Ttext=0x08000000", "-o", elf, o],
                   check=True, cwd=HERE)
    subprocess.run(["arm-none-eabi-objcopy", "-O", "binary", elf, gba],
                   check=True, cwd=HERE)
    rom = bytearray(open(gba, "rb").read())
    rom[0xA0:0xAC] = b"BOOTIO\0\0\0\0\0\0"
    rom[0xAC:0xB0] = b"ABIE"
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


def words(data):
    return [data[2 * i] | data[2 * i + 1] << 8 for i in range(len(data) // 2)]


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "words":
        w = words(open(sys.argv[2], "rb").read())
        for i in range(0, 270, 5):
            print(f"{2 * i:03X} " + " ".join(f"{x:04X}" for x in w[i:i + 5]))
        for i in range(270, 293):
            print(f"exp {i - 270:2} {w[i]:04X}")
    else:
        gen_inc()
        build()
