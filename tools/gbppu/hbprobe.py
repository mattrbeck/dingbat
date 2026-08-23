#!/usr/bin/env python3
"""Rebuild wilbertpol's hblank_ly_scx_timing as a ONE-CELL probe.

The shipped ROM asks 32 fixed yes/no questions (two nop counts per SCX, two
lines each) and stops at the first miss, so an emulator that is off by an
M-cycle tells you nothing but WHERE it first differs. This keeps the ROM's own
sync/halt path and failure dump byte-for-byte and replaces the body with:

    di
    ld hl,$ff44 ; STAT=$08 ; IE=$02 ; SCX=<s> ; d=$41 ; e=$42
    call <sync>          ; wait LY 89 -> 90 -> d, clear IF, EI, HALT
    call <sled>          ; N nops, then ret
    ld a,(hl)            ; read LY
    jp <dump>            ; always dump: B = the LY read, A = SCX

so one run reports the LY the CPU sees N M-cycles after the mode-0 STAT wake,
and sweeping N brackets the LY increment against the wake to one M-cycle.

N here is the ROM's own units: the shipped -C ROM's `call $0497` sled is 22 nops
and its per-cell tail is 2 or 3 more, so N = 24 is its "2 nops" cell.

  hbprobe.py <hblank_ly_scx_timing-C.gb> <scx> <N> <out.gb> [line=$41]
"""
import sys

rom = bytearray(open(sys.argv[1], "rb").read())
scx = int(sys.argv[2]); n = int(sys.argv[3]); out = sys.argv[4]
line = int(sys.argv[5], 0) if len(sys.argv) > 5 else 0x41

# The shipped -C ROM's own addresses (see tools/gbppu/sm83dis.py on it).
SYNC, DUMP, SLED = 0x04AE, 0x03FC, 0x3F00

body = bytes([
    0xF3,                          # di
    0x21, 0x44, 0xFF,              # ld hl,$ff44
    0x3E, 0x08, 0xE0, 0x41,        # ld a,$08 ; ldh ($ff41),a
    0x3E, 0x02, 0xE0, 0xFF,        # ld a,$02 ; ldh ($ffff),a
    0x3E, scx & 0xFF, 0xE0, 0x43,  # ld a,scx ; ldh ($ff43),a
    0x16, line,                    # ld d,<line>
    0x1E, (line + 1) & 0xFF,       # ld e,<line>+1
    0xCD, SYNC & 0xFF, SYNC >> 8,  # call sync
    0xCD, SLED & 0xFF, SLED >> 8,  # call sled
    0x7E,                          # ld a,(hl)
    0xC3, DUMP & 0xFF, DUMP >> 8,  # jp dump
])
rom[0x150:0x150 + len(body)] = body
rom[SLED:SLED + n] = b"\x00" * n
rom[SLED + n] = 0xC9

c = 0
for a in range(0x134, 0x14D): c = (c - rom[a] - 1) & 0xFF
rom[0x14D] = c
open(out, "wb").write(rom)
