#!/usr/bin/env python3
"""Builds lcdflicker.gb — a controlled alternate-frame flicker test ROM.

Real games hide their flicker-transparency deep inside a save file, which
makes an on/off comparison a screenshot of two different moments. This ROM
puts every case a panel-response model has to get right on one screen at
once, from a cold boot, with no input:

  rows  0-4   solid shade 0, never changes        static light reference
  rows  5-8   palette index 1, WHITE on even frames, BLACK on odd
  rows  9-12  palette index 2, BLACK on even frames, WHITE on odd
  rows 13-17  solid shade 3, never changes        static dark reference

The two flickering bands are in opposite phase, so a frame is never uniformly
anything, and both static bands are on screen in the same frame — if the model
smears static content, it shows up right next to the thing that is supposed to
smear. Nothing is written to VRAM per frame: the bands flicker purely by
alternating BGP between 0xF0 and 0xCC, so the flicker is exactly 30 Hz and
exactly two states, with no sprite motion confusing the measurement.

Two sprites also cross the screen at 2 px/frame, and they are the asymmetry
test: a BLACK sprite over the static light band, and a WHITE sprite over the
static dark band. On a normally-white panel these must smear in OPPOSITE
directions — the black one trails behind (the pixels it vacates take the slow
elastic way back to light), the white one leads soft and trails crisp.

Run this script to regenerate lcdflicker.gb next to it. Hand-assembled SM83,
same as gblinktest.py — no toolchain dependency.
"""
import os
import romfix

rom = bytearray(0x8000)


def emit(addr, *byts):
    rom[addr:addr + len(byts)] = bytes(byts)


# ── header ───────────────────────────────────────────────────────────────
emit(0x100, 0x00, 0xC3, 0x50, 0x01)          # nop; jp $0150
rom[0x134:0x144] = b"LCDFLICKER\0\0\0\0\0\0"
emit(0x147, 0x00)                             # MBC: ROM only
emit(0x148, 0x00)                             # 32 KiB
emit(0x149, 0x00)                             # no RAM

# ── tile data: four solid tiles, one per palette index ────────────────────
# 2bpp, 8 rows of (low plane, high plane).
TILES = 0x0400
tiles = bytearray()
for idx in range(4):
    lo = 0xFF if idx & 1 else 0x00
    hi = 0xFF if idx & 2 else 0x00
    tiles += bytes([lo, hi]) * 8
rom[TILES:TILES + len(tiles)] = tiles

# ── one tile index per background-map row (32 rows) ───────────────────────
ROWTAB = 0x0480
rows = []
for y in range(32):
    if y <= 4:
        rows.append(0)      # static light
    elif y <= 8:
        rows.append(1)      # flicker, phase A
    elif y <= 12:
        rows.append(2)      # flicker, phase B
    else:
        rows.append(3)      # static dark
rom[ROWTAB:ROWTAB + 32] = bytes(rows)

# ── code ─────────────────────────────────────────────────────────────────
BGPVAR = 0x80   # HRAM: the BGP value currently latched
SPX = 0x81      # HRAM: sprite X

code = []


def b(*x):
    code.extend(x)


def here():
    return 0x150 + len(code)


b(0xF3)                                   # di
b(0x31, 0xFE, 0xDF)                       # ld sp, $DFFE
b(0xAF)                                   # xor a
b(0xE0, 0x40)                             # ldh ($40), a   LCD off

# copy 64 bytes of tile data to $8000
b(0x21, 0x00, 0x80)                       # ld hl, $8000
b(0x11, TILES & 0xFF, TILES >> 8)         # ld de, TILES
b(0x06, 64)                               # ld b, 64
copy = here()
b(0x1A)                                   # ld a, (de)
b(0x22)                                   # ld (hl+), a
b(0x13)                                   # inc de
b(0x05)                                   # dec b
b(0x20, (copy - (here() + 2)) & 0xFF)     # jr nz, copy

# fill the $9800 map, one tile index per row
b(0x21, 0x00, 0x98)                       # ld hl, $9800
b(0x11, ROWTAB & 0xFF, ROWTAB >> 8)       # ld de, ROWTAB
b(0x0E, 32)                               # ld c, 32     rows
r1 = here()
b(0x1A)                                   # ld a, (de)
b(0x13)                                   # inc de
b(0x06, 32)                               # ld b, 32     columns
r2 = here()
b(0x22)                                   # ld (hl+), a
b(0x05)                                   # dec b
b(0x20, (r2 - (here() + 2)) & 0xFF)       # jr nz, r2
b(0x0D)                                   # dec c
b(0x20, (r1 - (here() + 2)) & 0xFF)       # jr nz, r1

# clear OAM
b(0x21, 0x00, 0xFE)                       # ld hl, $FE00
b(0x06, 160)                              # ld b, 160
b(0xAF)                                   # xor a
oc = here()
b(0x22)                                   # ld (hl+), a
b(0x05)                                   # dec b
b(0x20, (oc - (here() + 2)) & 0xFF)       # jr nz, oc

b(0x3E, 0xF0)                             # ld a, $F0
b(0xE0, BGPVAR)                           # ldh (BGPVAR), a
b(0xE0, 0x47)                             # ldh ($47), a    BGP
b(0x3E, 0xC0)                             # ld a, $C0       OBP0: idx3 black,
b(0xE0, 0x48)                             # ldh ($48), a    idx1 white
b(0xAF)                                   # xor a
b(0xE0, SPX)                              # ldh (SPX), a
b(0xE0, 0x42)                             # ldh ($42), a    SCY
b(0xE0, 0x43)                             # ldh ($43), a    SCX
b(0x3E, 0x93)                             # ld a, $93       LCD+BG+OBJ on,
b(0xE0, 0x40)                             # ldh ($40), a    $8000 tiles

main = here()
w1 = here()
b(0xF0, 0x44)                             # ldh a, ($44)    LY
b(0xFE, 144)                              # cp 144
b(0x20, (w1 - (here() + 2)) & 0xFF)       # jr nz, w1       wait for VBlank

b(0xF0, BGPVAR)                           # ldh a, (BGPVAR)
b(0xEE, 0x3C)                             # xor $3C         $F0 <-> $CC
b(0xE0, BGPVAR)                           # ldh (BGPVAR), a
b(0xE0, 0x47)                             # ldh ($47), a

b(0xF0, SPX)                              # ldh a, (SPX)
b(0xC6, 0x02)                             # add 2
b(0xE0, SPX)                              # ldh (SPX), a
b(0x21, 0x00, 0xFE)                       # ld hl, $FE00
b(0x3E, 32)                               # ld a, 32        sprite 0 Y (screen 16)
b(0x22)                                   # ld (hl+), a
b(0xF0, SPX)                              # ldh a, (SPX)
b(0x22)                                   # ld (hl+), a
b(0x3E, 3)                                # ld a, 3         solid-index-3 tile
b(0x22)                                   # ld (hl+), a
b(0xAF)                                   # xor a
b(0x22)                                   # ld (hl+), a
b(0x3E, 136)                              # ld a, 136       sprite 1 Y (screen 120)
b(0x22)                                   # ld (hl+), a
b(0xF0, SPX)                              # ldh a, (SPX)
b(0x22)                                   # ld (hl+), a
b(0x3E, 1)                                # ld a, 1         solid-index-1 tile
b(0x22)                                   # ld (hl+), a
b(0xAF)                                   # xor a
b(0x22)                                   # ld (hl+), a

w2 = here()
b(0xF0, 0x44)                             # ldh a, ($44)
b(0xFE, 144)                              # cp 144
b(0x28, (w2 - (here() + 2)) & 0xFF)       # jr z, w2        leave VBlank
b(0x18, (main - (here() + 2)) & 0xFF)     # jr main

emit(0x150, *code)

# header checksum
c = 0
for a in range(0x134, 0x14D):
    c = (c - rom[a] - 1) & 0xFF
emit(0x14D, c)

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lcdflicker.gb")
open(out, "wb").write(rom)
romfix.gb_logo(out)
print(out, len(rom), "bytes,", len(code), "bytes of code")
