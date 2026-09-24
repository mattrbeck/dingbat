#!/usr/bin/env python3
"""Build the BIOS sound-driver probe ROMs (tools/biosdrv/*.c + rt.s).

Needs devkitARM (/opt/devkitpro): arm-none-eabi-gcc with gba.specs, and
gbafix. Each ROM is written next to its source as <name>.gba together with
<name>.snap, the BD_SNAP region list tests/biosdrv_probe.nim should
snapshot at every marker (the SoundArea, the BIOS variables at 0x03007FF0,
the probe's RESULT block and the wrappers' bd_regs).

Usage: build.py [name ...]   (default: every .c here)
"""
import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DKA = "/opt/devkitpro/devkitARM/bin"
GBAFIX = "/opt/devkitpro/tools/bin/gbafix"


def sym(elf, name):
    out = subprocess.run([f"{DKA}/arm-none-eabi-nm", elf], check=True,
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == name:
            return int(parts[0], 16)
    return None


def build(name):
    src = os.path.join(HERE, name + ".c")
    elf = os.path.join(HERE, name + ".elf")
    gba = os.path.join(HERE, name + ".gba")
    extra = [os.path.join(HERE, f) for f in ("rt.s",)]
    # song data assembled per probe when present (name_song.s)
    song = os.path.join(HERE, name + "_song.s")
    if os.path.exists(song):
        extra.append(song)
    subprocess.run([f"{DKA}/arm-none-eabi-gcc", "-mthumb", "-mcpu=arm7tdmi",
                    "-O2", "-specs=gba.specs", "-o", elf, src] + extra,
                   check=True)
    subprocess.run([f"{DKA}/arm-none-eabi-objcopy", "-O", "binary", elf, gba],
                   check=True)
    subprocess.run([GBAFIX, gba, "-t" + name.upper()[:12], "-cBDRV", "-r0"],
                   check=True, capture_output=True)
    regs = sym(elf, "bd_regs")
    # (a probe without ARM wrappers has no bd_regs: snapshot a dummy word)
    regs = regs if regs is not None else 0x02030100
    snap = f"03004000:FB0,03007FF0:10,02030000:100,{regs:08X}:20"
    extra_snap = os.path.join(HERE, name + ".extrasnap")
    if os.path.exists(extra_snap):
        snap += "," + open(extra_snap).read().strip()
    open(os.path.join(HERE, name + ".snap"), "w").write(snap + "\n")
    os.unlink(elf)
    print(f"{gba}: {os.path.getsize(gba)} bytes, snap {snap}")


if __name__ == "__main__":
    names = sys.argv[1:] or sorted(
        os.path.splitext(os.path.basename(p))[0]
        for p in glob.glob(os.path.join(HERE, "*.c")))
    for n in names:
        build(n)
