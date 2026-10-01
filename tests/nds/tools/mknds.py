#!/usr/bin/env python3
"""Wrap raw ARM9 and ARM7 binaries in a Nintendo DS cartridge header.

Enough for a direct-booting emulator (one that copies the two binaries to
their RAM addresses itself and starts both CPUs at their entry points). Field
layout follows GBATEK "DS Cartridge Header".

    mknds.py -9 arm9.bin -7 arm7.bin -o out.nds [--title FB_HELLO]

Defaults: ARM9 loaded and entered at 0x02000000, ARM7 at 0x037F8000 (the
start of ARM7-visible shared/ARM7 WRAM). The binaries are placed at ROM
offsets 0x4000 (ARM9) and the next 0x200 boundary after it (ARM7), as
ndstool does.

The 156-byte boot logo at 0x0C0 is left zeroed: it is Nintendo's bitmap and
is not reproduced here. Real firmware refuses a cart without it; a direct
boot does not look at it. `--logo-from some.nds` copies 0x0C0..0x15D from
another ROM image if a firmware boot is ever wanted.
"""

import argparse
import struct
import sys


def crc16(data: bytes, crc: int = 0xFFFF) -> int:
    """CRC-16/MODBUS (reflected poly 0xA001, init 0xFFFF), as GBATEK specifies
    for the header, logo and secure-area checksums."""
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def align(n: int, a: int) -> int:
    return (n + a - 1) & ~(a - 1)


def build(arm9: bytes, arm7: bytes, *, title: str, code: str, maker: str,
          arm9_addr: int, arm9_entry: int, arm7_addr: int, arm7_entry: int,
          logo: bytes | None) -> bytes:
    arm9_off = 0x4000
    arm7_off = align(arm9_off + len(arm9), 0x200)
    used = arm7_off + len(arm7)
    total = align(used, 0x200)

    # Device capacity: chip size = 128 KiB << n.
    cap = 0
    while (0x20000 << cap) < total:
        cap += 1

    h = bytearray(0x200)
    h[0x000:0x00C] = title.encode("ascii")[:12].ljust(12, b"\0")
    h[0x00C:0x010] = code.encode("ascii")[:4].ljust(4, b"\0")
    h[0x010:0x012] = maker.encode("ascii")[:2].ljust(2, b"\0")
    h[0x012] = 0x00          # unit code: NDS only
    h[0x014] = cap
    struct.pack_into("<IIII", h, 0x020, arm9_off, arm9_entry, arm9_addr, len(arm9))
    struct.pack_into("<IIII", h, 0x030, arm7_off, arm7_entry, arm7_addr, len(arm7))
    # No file system, no overlays, no icon/title block: 0x040..0x05F and
    # 0x068 stay zero.
    struct.pack_into("<I", h, 0x060, 0x00586000)   # ROMCTRL for normal commands
    struct.pack_into("<I", h, 0x064, 0x001808F8)   # ROMCTRL for KEY1 commands
    struct.pack_into("<H", h, 0x06E, 0x051E)       # secure-area delay
    struct.pack_into("<I", h, 0x080, used)         # total used ROM size
    struct.pack_into("<I", h, 0x084, 0x4000)       # ROM header size
    if logo is not None:
        h[0x0C0:0x15C] = logo
    struct.pack_into("<H", h, 0x15C, crc16(bytes(h[0x0C0:0x15C])))

    rom = bytearray(total)
    rom[arm9_off:arm9_off + len(arm9)] = arm9
    rom[arm7_off:arm7_off + len(arm7)] = arm7
    # 0x06C (secure-area CRC) stays zero: it covers the KEY1-encrypted form
    # of 0x4000..0x7FFF, which a plain homebrew image never has.
    struct.pack_into("<H", h, 0x15E, crc16(bytes(h[0x000:0x15E])))
    rom[0:0x200] = h
    return bytes(rom)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    num = lambda s: int(s, 0)
    p.add_argument("-9", "--arm9", required=True, help="raw ARM9 binary")
    p.add_argument("-7", "--arm7", required=True, help="raw ARM7 binary")
    p.add_argument("-o", "--out", required=True)
    p.add_argument("--title", default="HOMEBREW")
    p.add_argument("--code", default="####")
    p.add_argument("--maker", default="00")
    p.add_argument("--arm9-addr", type=num, default=0x02000000)
    p.add_argument("--arm9-entry", type=num, default=None, help="default: --arm9-addr")
    p.add_argument("--arm7-addr", type=num, default=0x037F8000)
    p.add_argument("--arm7-entry", type=num, default=None, help="default: --arm7-addr")
    p.add_argument("--logo-from", help="copy the boot logo from this .nds")
    a = p.parse_args()

    with open(a.arm9, "rb") as f:
        arm9 = f.read()
    with open(a.arm7, "rb") as f:
        arm7 = f.read()
    logo = None
    if a.logo_from:
        with open(a.logo_from, "rb") as f:
            logo = f.read(0x15C)[0x0C0:0x15C]

    rom = build(arm9, arm7, title=a.title, code=a.code, maker=a.maker,
                arm9_addr=a.arm9_addr,
                arm9_entry=a.arm9_entry if a.arm9_entry is not None else a.arm9_addr,
                arm7_addr=a.arm7_addr,
                arm7_entry=a.arm7_entry if a.arm7_entry is not None else a.arm7_addr,
                logo=logo)
    with open(a.out, "wb") as f:
        f.write(rom)
    print(f"{a.out}: {len(rom)} bytes, ARM9 {len(arm9)} B @ {a.arm9_addr:#010x}, "
          f"ARM7 {len(arm7)} B @ {a.arm7_addr:#010x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
