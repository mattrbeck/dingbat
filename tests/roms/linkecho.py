#!/usr/bin/env python3
"""Builds linkecho.mb.gba — the multiboot link smoke test (linkecho.s says
what it does).  Upload it with tools/hwlink/gblink.py:

    python3 linkecho.py                       build
    python3 ../../tools/hwlink/gblink.py boot linkecho.mb.gba

A pass is the screen turning green and the host reading C0DE1234 back.

Requires arm-none-eabi-{as,ld,objcopy} and gbafix, like the other ROMs here.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import romfix                                # noqa: E402

# A multiboot image is linked into EWRAM, not the cartridge window, and the
# upload's length word is (size - 0x190) / 4, so anything shorter than that
# would underflow it; the transfer itself moves 16 bytes at a time.
LOAD_ADDRESS = 0x02000000
MIN_SIZE = 0x200


def build():
    obj = os.path.join(HERE, "linkecho.o")
    elf = os.path.join(HERE, "linkecho.elf")
    out = os.path.join(HERE, "linkecho.mb.gba")
    subprocess.run(["arm-none-eabi-as", "-mcpu=arm7tdmi", "-o", obj,
                    os.path.join(HERE, "linkecho.s")], check=True)
    subprocess.run(["arm-none-eabi-ld", f"-Ttext={LOAD_ADDRESS:#x}", "-o", elf,
                    obj], check=True)
    subprocess.run(["arm-none-eabi-objcopy", "-O", "binary", elf, out],
                   check=True)
    data = bytearray(open(out, "rb").read())
    while len(data) < MIN_SIZE or len(data) % 16:
        data.append(0)
    open(out, "wb").write(bytes(data))
    romfix.gba_logo(out)
    for scratch in (obj, elf):
        os.remove(scratch)
    print(f"{out} {len(data)} bytes")


if __name__ == "__main__":
    build()
