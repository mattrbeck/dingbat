#!/usr/bin/env python3
"""Run one probe ROM through tests/biosdrv_probe.nim.

  run.py <rom.gba> <real|hle> [frames] [--trace] [--swi]

Output prefix: /tmp/bd/<rom>.<real|hle>. --trace adds BD_MEMTRACE,
BD_MEMREAD and BD_IOREAD; --swi adds BD_SWILOG. A ROM with a .snap file
next to it gets its snapshot regions.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import BIOS, run  # noqa: E402

args = [a for a in sys.argv[1:] if not a.startswith("--")]
flags = {a for a in sys.argv[1:] if a.startswith("--")}
rom = os.path.abspath(args[0])
tag = args[1]
frames = int(args[2]) if len(args) > 2 else 60
env = {}
if "--trace" in flags:
    env.update(BD_MEMTRACE="1", BD_MEMREAD="1", BD_IOREAD="1")
if "--memall" in flags:
    env.update(BD_MEMTRACE="all")
if "--swi" in flags:
    env.update(BD_SWILOG="1")
print(run(rom, frames, BIOS if tag == "real" else "hle", tag, env))
