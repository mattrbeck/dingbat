#!/usr/bin/env python3
"""Builds gblinktest.gb — GB link-cable acceptance ROM (hand-assembled SM83).

Contract (asserted by dingbat_test --mode=gblinktest):
  The harness pokes the unit's role into WRAM 0xC7FF before running
  (0 = master / internal clock, 1 = slave / external clock).
  16 rounds of full-duplex byte exchange: the master sends 0xC0|round and
  the slave answers 0xD0|round, so each unit logs the PEER's byte per
  round at 0xC000+round. 0xC808 counts serial-completion IF flags
  observed (must be 16). Done flag: 0xC800/0xC801 = 0xFE 0xCA (0xCAFE).

Run this script to regenerate gblinktest.gb next to it (no toolchain
dependency — the few dozen instructions are assembled by hand below).
"""
import struct, os

rom = bytearray(0x8000)

def emit(addr, *byts):
    rom[addr:addr+len(byts)] = bytes(byts)
    return addr + len(byts)

# --- entry + header ---
emit(0x100, 0x00, 0xC3, 0x50, 0x01)          # nop; jp 0x0150
# title
title = b"GBLINKTEST"
rom[0x134:0x134+len(title)] = title
rom[0x143] = 0x00                             # DMG cart
rom[0x147] = 0x00                             # ROM only
rom[0x148] = 0x00                             # 32 KB
rom[0x149] = 0x00                             # no cart RAM

# --- program ---
a = 0x150
a = emit(a, 0xF3)                             # di
a = emit(a, 0x31, 0xFE, 0xFF)                 # ld sp, 0xFFFE
a = emit(a, 0xFA, 0xFF, 0xC7)                 # ld a, (0xC7FF)   ; role
a = emit(a, 0x47)                             # ld b, a
a = emit(a, 0x0E, 0x00)                       # ld c, 0          ; round

LOOP = a
a = emit(a, 0x78)                             # ld a, b
a = emit(a, 0xA7)                             # and a
SLAVE_JP = a
a = emit(a, 0xC2, 0x00, 0x00)                 # jp nz, SLAVE (patched)

# master: give the slave time to stage its reply byte, then clock 8 bits
a = emit(a, 0x16, 0xFF)                       # ld d, 0xFF
MDELAY = a
a = emit(a, 0x15)                             # dec d
a = emit(a, 0xC2, MDELAY & 0xFF, MDELAY >> 8) # jp nz, MDELAY  (~4 kcycles)
a = emit(a, 0x3E, 0xC0)                       # ld a, 0xC0
a = emit(a, 0xB1)                             # or c
a = emit(a, 0xE0, 0x01)                       # ldh (SB), a
a = emit(a, 0x3E, 0x81)                       # ld a, 0x81
a = emit(a, 0xE0, 0x02)                       # ldh (SC), a      ; start
MWAIT = a
a = emit(a, 0xF0, 0x02)                       # ldh a, (SC)
a = emit(a, 0xE6, 0x80)                       # and 0x80
a = emit(a, 0xC2, MWAIT & 0xFF, MWAIT >> 8)   # jp nz, MWAIT
GOT_JP = a
a = emit(a, 0xC3, 0x00, 0x00)                 # jp GOT (patched)

SLAVE = a
rom[SLAVE_JP+1] = SLAVE & 0xFF
rom[SLAVE_JP+2] = SLAVE >> 8
a = emit(a, 0x3E, 0xD0)                       # ld a, 0xD0
a = emit(a, 0xB1)                             # or c
a = emit(a, 0xE0, 0x01)                       # ldh (SB), a
a = emit(a, 0x3E, 0x80)                       # ld a, 0x80
a = emit(a, 0xE0, 0x02)                       # ldh (SC), a      ; wait for master's clock
SWAIT = a
a = emit(a, 0xF0, 0x02)                       # ldh a, (SC)
a = emit(a, 0xE6, 0x80)                       # and 0x80
a = emit(a, 0xC2, SWAIT & 0xFF, SWAIT >> 8)   # jp nz, SWAIT

GOT = a
rom[GOT_JP+1] = GOT & 0xFF
rom[GOT_JP+2] = GOT >> 8
# count the serial-completion IF flag, then clear it
a = emit(a, 0xF0, 0x0F)                       # ldh a, (IF)
a = emit(a, 0xCB, 0x5F)                       # bit 3, a
NOIRQ_JP = a
a = emit(a, 0xCA, 0x00, 0x00)                 # jp z, NOIRQ (patched)
a = emit(a, 0x21, 0x08, 0xC8)                 # ld hl, 0xC808
a = emit(a, 0x34)                             # inc (hl)
a = emit(a, 0xF0, 0x0F)                       # ldh a, (IF)
a = emit(a, 0xE6, 0xF7)                       # and ~0x08
a = emit(a, 0xE0, 0x0F)                       # ldh (IF), a
NOIRQ = a
rom[NOIRQ_JP+1] = NOIRQ & 0xFF
rom[NOIRQ_JP+2] = NOIRQ >> 8
# log the received byte at 0xC000 + round
a = emit(a, 0xF0, 0x01)                       # ldh a, (SB)
a = emit(a, 0x21, 0x00, 0xC0)                 # ld hl, 0xC000
a = emit(a, 0x69)                             # ld l, c
a = emit(a, 0x77)                             # ld (hl), a
# next round
a = emit(a, 0x0C)                             # inc c
a = emit(a, 0x79)                             # ld a, c
a = emit(a, 0xFE, 0x10)                       # cp 16
a = emit(a, 0xC2, LOOP & 0xFF, LOOP >> 8)     # jp nz, LOOP
# done: 0xCAFE at 0xC800 (little endian)
a = emit(a, 0x3E, 0xFE)                       # ld a, 0xFE
a = emit(a, 0xEA, 0x00, 0xC8)                 # ld (0xC800), a
a = emit(a, 0x3E, 0xCA)                       # ld a, 0xCA
a = emit(a, 0xEA, 0x01, 0xC8)                 # ld (0xC801), a
a = emit(a, 0xC3, a & 0xFF, a >> 8)           # spin: jp self

# header checksum (0x134..0x14C)
chk = 0
for i in range(0x134, 0x14D):
    chk = (chk - rom[i] - 1) & 0xFF
rom[0x14D] = chk

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gblinktest.gb")
with open(out, "wb") as f:
    f.write(rom)
print(f"wrote {out} ({len(rom)} bytes), program ends at 0x{a:04X}")
