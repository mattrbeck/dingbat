#!/usr/bin/env python3
"""Builds the resident GBA monitor (gbamon.s says what it does).

    python3 gbamon.py            build gbamon.mb.gba (+ gbamon.gba)

`gbamon.mb.gba` is the multiboot image uploaded over the link cable by
tools/hwlink/monitor.py.  `gbamon.gba` is the same source linked into the
cartridge window instead, which is what an emulator can run: it reaches the
same idle loop, so a smoke test can check the monitor starts without a
console in the loop.  It is also the build to put on a flashcart, where the
monitor can reach the cartridge bus that multiboot cannot.

Requires arm-none-eabi-{as,ld,objcopy} and gbafix, like the other ROMs here.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import romfix                                # noqa: E402

MULTIBOOT_ADDRESS = 0x02000000
CART_ADDRESS = 0x08000000
# the upload's length word is (size - 0x190) / 4, so anything shorter would
# underflow it; the transfer itself moves 16 bytes at a time
MIN_SIZE = 0x200


def build_one(load_address, out_name):
    obj = os.path.join(HERE, "gbamon.o")
    elf = os.path.join(HERE, "gbamon.elf")
    out = os.path.join(HERE, out_name)
    subprocess.run(["arm-none-eabi-as", "-mcpu=arm7tdmi", "-o", obj,
                    os.path.join(HERE, "gbamon.s")], check=True)
    subprocess.run(["arm-none-eabi-ld", f"-Ttext={load_address:#x}", "-o", elf,
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
    build_one(MULTIBOOT_ADDRESS, "gbamon.mb.gba")
    build_one(CART_ADDRESS, "gbamon.gba")
