#!/usr/bin/env python3
"""Builds gbhdmatest.gbc — CGB HBlank-DMA (HDMA) regression ROM (hand-assembled SM83).

Continuously re-arms a 128-block HBlank DMA (ROM 0x0000 -> VRAM 0x8000) so the
PPU's mode 3 -> 0 transition fires ppu_step_hdma on nearly every visible line.
The ROM never terminates; the harness runs it for a fixed frame count in
screenshot mode and passes iff the process survives (exit 0).

Regression guard for the Pokemon Crystal boot crash (native segfault / web
"Maximum call stack size exceeded"): the HDMA block copy ticks the PPU, and if
`mode_flag=` triggers the copy BEFORE lcd_status reflects mode 0, a nested tick
in the FIFO renderer still observes mode 3, re-enters its level-triggered
`lx >= GB_WIDTH` mode-0 transition, and recurses until the stack overflows.

Run: ./dingbat_test tests/roms/gbhdmatest.gbc --mode=screenshot --timeout=120 \
       --screenshot=/tmp/gbhdmatest.ppm

Run this script to regenerate gbhdmatest.gbc next to it (no toolchain
dependency — the handful of instructions are assembled by hand below).
"""
import os

rom = bytearray(0x8000)

def emit(addr, *byts):
    rom[addr:addr+len(byts)] = bytes(byts)
    return addr + len(byts)

# --- entry + header ---
emit(0x100, 0x00, 0xC3, 0x50, 0x01)          # nop; jp 0x0150
title = b"GBHDMATEST"
rom[0x134:0x134+len(title)] = title
rom[0x143] = 0xC0                             # CGB only (HDMA is CGB hardware)
rom[0x147] = 0x00                             # ROM only
rom[0x148] = 0x00                             # 32 KB
rom[0x149] = 0x00                             # no cart RAM

# --- program ---
a = 0x150
a = emit(a, 0xF3)                             # di
a = emit(a, 0x31, 0xFE, 0xFF)                 # ld sp, 0xFFFE

ARM = a
# HDMA src = 0x0000 (ROM), dst = 0x8000 (VRAM)
a = emit(a, 0xAF)                             # xor a
a = emit(a, 0xE0, 0x51)                       # ldh (HDMA1), a  ; src hi
a = emit(a, 0xE0, 0x52)                       # ldh (HDMA2), a  ; src lo
a = emit(a, 0xE0, 0x53)                       # ldh (HDMA3), a  ; dst hi
a = emit(a, 0xE0, 0x54)                       # ldh (HDMA4), a  ; dst lo
a = emit(a, 0x3E, 0xFF)                       # ld a, 0xFF      ; HBlank DMA, 128 blocks
a = emit(a, 0xE0, 0x55)                       # ldh (HDMA5), a  ; start
WAIT = a
a = emit(a, 0xF0, 0x55)                       # ldh a, (HDMA5)
a = emit(a, 0xFE, 0xFF)                       # cp 0xFF         ; 0xFF = transfer done
a = emit(a, 0x20, (WAIT - (a + 2)) & 0xFF)    # jr nz, WAIT
a = emit(a, 0x18, (ARM - (a + 2)) & 0xFF)     # jr ARM          ; re-arm forever

# header checksum (0x134..0x14C)
chk = 0
for i in range(0x134, 0x14D):
    chk = (chk - rom[i] - 1) & 0xFF
rom[0x14D] = chk

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gbhdmatest.gbc")
with open(out, "wb") as f:
    f.write(rom)
print(f"wrote {out} ({len(rom)} bytes), program ends at 0x{a:04X}")
