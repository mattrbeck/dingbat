#!/usr/bin/env python3
"""Builds sgbtest.gb — a Super Game Boy acceptance ROM (hand-assembled SM83).

There is no SGB-enhanced ROM in this repository and none may be fetched, so
this stands in for one. It exercises exactly the path a real SGB game uses:
the P1 pulse-encoded command-packet stream, the palette and attribute
commands, and the two VRAM transfers that carry a border.

What the ROM does, in order:

  0.  BGP = 0xE4, no scroll, and an identity BG map ($00..$13 on the first
      line, $14..$27 on the next) so the VRAM transfers meet the conditions
      Pan Docs requires -- a transfer is read out of the DISPLAY, not out of
      memory, and dingbat reads it that way.
  1.  Copy the 4 KiB CHR payload from ROM 0x4000 into VRAM 0x8000-0x8FFF,
      turn the LCD on, and send CHR_TRN (tiles 0x00-0x7F, BG).
  2.  Copy the 4 KiB PCT payload from ROM 0x5000 into the same window and
      send PCT_TRN (border tilemap + border palettes 4-6).
  3.  Write four solid-shade BG tiles and a tile map of vertical stripes
      (columns cycle shade 0,1,2,3), BGP = 0xE4, LCD on.
  4.  Send PAL01, PAL23, ATTR_DIV and ATTR_BLK, then spin.

The expected picture is therefore fully determined: every 8x8 screen cell
has a known SGB palette from the ATTR_* commands and a known shade from the
stripe pattern, and the border is a known 32x28 arrangement of solid-colour
tiles. tests/sgb_test.nim checks that pixel by pixel.

Run this script to regenerate sgbtest.gb next to it (no toolchain
dependency — the program is assembled by the mini-assembler below).
"""
import os

ROM_SIZE = 0x8000
rom = bytearray(ROM_SIZE)

# ---------------------------------------------------------------- assembler

class Asm:
    """Minimal two-pass SM83 emitter: `l("name")` marks, `ref` patches."""

    def __init__(self, org):
        self.pc = org
        self.labels = {}
        self.fix16 = []   # (addr, label)
        self.fix8 = []    # (addr, label)  relative

    def db(self, *b):
        for v in b:
            rom[self.pc] = v & 0xFF
            self.pc += 1

    def l(self, name):
        self.labels[name] = self.pc

    def a16(self, name):
        self.fix16.append((self.pc, name))
        self.db(0, 0)

    def rel(self, name):
        self.fix8.append((self.pc, name))
        self.db(0)

    def resolve(self):
        for addr, name in self.fix16:
            t = self.labels[name]
            rom[addr] = t & 0xFF
            rom[addr + 1] = t >> 8
        for addr, name in self.fix8:
            d = self.labels[name] - (addr + 1)
            assert -128 <= d <= 127, (name, d)
            rom[addr] = d & 0xFF

    # -- the instruction subset this program needs --
    def di(self):            self.db(0xF3)
    def ld_sp(self, n):      self.db(0x31, n & 0xFF, n >> 8)
    def ld_hl(self, n):      self.db(0x21, n & 0xFF, n >> 8)
    def ld_de(self, n):      self.db(0x11, n & 0xFF, n >> 8)
    def ld_bc(self, n):      self.db(0x01, n & 0xFF, n >> 8)
    def ld_a(self, n):       self.db(0x3E, n & 0xFF)
    def ld_b(self, n):       self.db(0x06, n & 0xFF)
    def ld_c(self, n):       self.db(0x0E, n & 0xFF)
    def xor_a(self):         self.db(0xAF)
    def ldh_to(self, n):     self.db(0xE0, n & 0xFF)   # ldh (n), a
    def ld_a_hli(self):      self.db(0x2A)
    def ld_de_a(self):       self.db(0x12)
    def inc_de(self):        self.db(0x13)
    def inc_hl(self):        self.db(0x23)
    def dec_bc(self):        self.db(0x0B)
    def dec_b(self):         self.db(0x05)
    def dec_c(self):         self.db(0x0D)
    def ld_a_b(self):        self.db(0x78)
    def ld_a_d(self):        self.db(0x7A)
    def ld_a_h(self):        self.db(0x7C)
    def ld_a_l(self):        self.db(0x7D)
    def ld_d_a(self):        self.db(0x57)
    def or_c(self):          self.db(0xB1)
    def and_n(self, n):      self.db(0xE6, n & 0xFF)
    def cp_n(self, n):       self.db(0xFE, n & 0xFF)
    def ld_hli_a(self):      self.db(0x22)
    def add_hl_bc(self):     self.db(0x09)
    def ld_e(self, n):       self.db(0x1E, n & 0xFF)
    def dec_e(self):         self.db(0x1D)
    def inc_d(self):         self.db(0x14)
    def rrca(self):          self.db(0x0F)
    def nop(self):           self.db(0x00)
    def ret(self):           self.db(0xC9)
    def call(self, name):    self.db(0xCD); self.a16(name)
    def jp(self, name):      self.db(0xC3); self.a16(name)
    def jr(self, name):      self.db(0x18); self.rel(name)
    def jr_nz(self, name):   self.db(0x20); self.rel(name)
    def jr_c(self, name):    self.db(0x38); self.rel(name)


# ---------------------------------------------------------------- payloads

def rgb555(r, g, b):
    return (r & 0x1F) | ((g & 0x1F) << 5) | ((b & 0x1F) << 10)


# Border colour ramp: index 0 is transparent, 1..15 are 15 distinct colours.
BORDER_COLORS = [
    rgb555(0, 0, 0),      # 0 (transparent, never drawn)
    rgb555(31, 0, 0), rgb555(0, 31, 0), rgb555(0, 0, 31),
    rgb555(31, 31, 0), rgb555(31, 0, 31), rgb555(0, 31, 31),
    rgb555(31, 31, 31), rgb555(16, 0, 0), rgb555(0, 16, 0),
    rgb555(0, 0, 16), rgb555(16, 16, 0), rgb555(16, 0, 16),
    rgb555(0, 16, 16), rgb555(16, 16, 16), rgb555(24, 12, 4),
]

# CHR payload: 128 SNES 4bpp tiles, tile n a solid fill of colour (n & 15).
chr_payload = bytearray(4096)
for n in range(128):
    ci = n & 15
    base = n * 32
    for row in range(8):
        chr_payload[base + row * 2]      = 0xFF if (ci & 1) else 0x00
        chr_payload[base + row * 2 + 1]  = 0xFF if (ci & 2) else 0x00
        chr_payload[base + 16 + row * 2] = 0xFF if (ci & 4) else 0x00
        chr_payload[base + 16 + row * 2 + 1] = 0xFF if (ci & 8) else 0x00

# PCT payload: 32x28 tilemap (the centre 20x18 is tile 0 = transparent, which
# is where the Game Boy window shows through) then the three border palettes.
pct_payload = bytearray(4096)


def border_tile(tx, ty):
    """The tile this map cell uses. Mirrors tests/sgb_test.nim."""
    if 6 <= tx < 26 and 5 <= ty < 23:
        return 0                       # the Game Boy window
    return 1 + ((tx + ty) % 15)


for ty in range(28):
    for tx in range(32):
        entry = border_tile(tx, ty) | (4 << 10)   # always palette 4
        o = (ty * 32 + tx) * 2
        pct_payload[o] = entry & 0xFF
        pct_payload[o + 1] = entry >> 8
for p in range(3):
    for i in range(16):
        c = BORDER_COLORS[i] if p == 0 else rgb555(i, i, i)
        o = 0x800 + (p * 16 + i) * 2
        pct_payload[o] = c & 0xFF
        pct_payload[o + 1] = c >> 8

# Four solid-shade BG tiles (2bpp): tile n is shade n everywhere.
bg_tiles = bytearray(64)
for n in range(4):
    for row in range(8):
        bg_tiles[n * 16 + row * 2]     = 0xFF if (n & 1) else 0x00
        bg_tiles[n * 16 + row * 2 + 1] = 0xFF if (n & 2) else 0x00


# ---------------------------------------------------------------- packets

def packet(cmd, data, total=1, index=0):
    """One 16-byte SGB packet. `data` fills bytes 1..15 of packet 0."""
    p = bytearray(16)
    if index == 0:
        p[0] = (cmd << 3) | total
        p[1:1 + len(data)] = bytes(data[:15])
    else:
        p[0:len(data)] = bytes(data[:16])
    return p


def pal_data(c0, a1, a2, a3, b1, b2, b3):
    out = []
    for c in (c0, a1, a2, a3, b1, b2, b3):
        out += [c & 0xFF, c >> 8]
    return out


PAL0 = (rgb555(0, 0, 0), rgb555(31, 0, 0), rgb555(0, 31, 0), rgb555(0, 0, 31))
PAL1 = (rgb555(31, 31, 0), rgb555(31, 0, 31), rgb555(0, 31, 31))
PAL2 = (rgb555(10, 10, 10), rgb555(20, 20, 20), rgb555(31, 31, 31))
PAL3 = (rgb555(31, 16, 0), rgb555(16, 31, 0), rgb555(0, 16, 31))

PACKETS = {
    # PAL01: palette 0 gets all four colours, palette 1 shares colour 0.
    "pal01": packet(0x00, pal_data(PAL0[0], PAL0[1], PAL0[2], PAL0[3],
                                   PAL1[0], PAL1[1], PAL1[2])),
    # PAL23: same colour 0 again (it is the shared backdrop).
    "pal23": packet(0x01, pal_data(PAL0[0], PAL2[0], PAL2[1], PAL2[2],
                                   PAL3[0], PAL3[1], PAL3[2])),
    # ATTR_DIV: horizontal split at row 9. Above = palette 1, the division
    # line = palette 3, below = palette 2.
    "attrdiv": packet(0x06, [(2 & 3) | ((1 & 3) << 2) | ((3 & 3) << 4) | 0x40, 9]),
    # ATTR_BLK: one data set, change inside + line + outside is NOT used --
    # only "inside" (control 1), so the surrounding line takes the inside
    # colour too, per Pan Docs. Rectangle x 4..11, y 2..6, palette 0.
    "attrblk": packet(0x04, [1, 0x01, 0x00 | (0 << 2), 4, 2, 11, 6]),
    "chrtrn": packet(0x13, [0x00]),
    "pcttrn": packet(0x14, []),
}
# ATTR_BLK's data-set layout is control, palettes, x1, y1, x2, y2 -- rebuild
# it explicitly so the field order is unmistakable.
PACKETS["attrblk"] = packet(0x04, [
    0x01,                    # number of data sets
    0x01,                    # control: change inside only
    0x00,                    # palettes: inside 0, line 0, outside 0
    4, 2, 11, 6,             # x1, y1, x2, y2
])

PACKET_ORDER = ["pal01", "pal23", "attrdiv", "attrblk", "chrtrn", "pcttrn"]
PACKET_ADDR = {}


# ---------------------------------------------------------------- program

a = Asm(0x0150)

a.di()
a.ld_sp(0xFFFE)
a.ld_a(0xE4); a.ldh_to(0x47)         # BGP = identity, as a transfer requires
a.xor_a(); a.ldh_to(0x42); a.ldh_to(0x43)   # SCY = SCX = 0

# A VRAM transfer is read out of the DISPLAY, not out of memory, so the
# documented preconditions have to actually hold: characters $00-$FF on
# screen ($00..$13 on the first line, $14..$27 on the next), LCD on, unsigned
# tile addressing, no scroll, BGP = $E4. Build the identity map once.
a.xor_a(); a.ldh_to(0x40)            # LCD off so VRAM is always writable
a.ld_hl(0x9800)
a.ld_b(0)                            # character number
a.ld_e(13)                           # 13 rows covers all 256 characters
a.l("idrow")
a.ld_c(20)
a.l("idcol")
a.ld_a_b(); a.ld_hli_a(); a.db(0x04)  # inc b
a.dec_c(); a.jr_nz("idcol")
for _ in range(12): a.inc_hl()       # skip the off-screen map columns
                                     # (not `ld bc,12 / add hl,bc` -- that
                                     #  would clobber the B character counter)
a.dec_e(); a.jr_nz("idrow")

# --- border character data ---
a.ld_hl(0x4000); a.ld_de(0x8000); a.ld_bc(0x1000); a.call("memcpy")
a.ld_a(0x91); a.ldh_to(0x40)         # LCD on, BG on, unsigned tiles at 0x8000
a.ld_hl(0)                           # patched below to the chrtrn packet
a.fix16.append((a.pc - 2, "pkt_chrtrn"))
a.call("send_packet")

# --- border tilemap + palettes ---
a.xor_a(); a.ldh_to(0x40)
a.ld_hl(0x5000); a.ld_de(0x8000); a.ld_bc(0x1000); a.call("memcpy")
a.ld_a(0x91); a.ldh_to(0x40)
a.ld_hl(0)
a.fix16.append((a.pc - 2, "pkt_pcttrn"))
a.call("send_packet")

# --- the Game Boy picture: four solid tiles, striped tile map ---
a.xor_a(); a.ldh_to(0x40)
a.ld_hl(0x6000); a.ld_de(0x8000); a.ld_bc(64); a.call("memcpy")
a.ld_hl(0x9800)
a.l("maploop")
a.ld_a_l(); a.and_n(3); a.ld_hli_a()
a.ld_a_h(); a.cp_n(0x9C); a.jr_nz("maploop")
a.ld_a(0x91); a.ldh_to(0x40)         # LCD on, BG on, tile data at 0x8000

# --- colour ---
for name in ["pal01", "pal23", "attrdiv", "attrblk"]:
    a.ld_hl(0)
    a.fix16.append((a.pc - 2, "pkt_" + name))
    a.call("send_packet")

a.l("done")
a.jr("done")

# --- memcpy: hl -> de, bc bytes ---
a.l("memcpy")
a.l("memcpy_loop")
a.ld_a_hli(); a.ld_de_a(); a.inc_de(); a.dec_bc()
a.ld_a_b(); a.or_c(); a.jr_nz("memcpy_loop")
a.ret()

# --- send_packet: hl -> 16 bytes ---
# Both select lines low is the reset pulse; then each bit is one low pulse,
# P14 for a 0 and P15 for a 1, LSB of each byte first, and a 0 stop bit.
a.l("send_packet")
a.xor_a(); a.ldh_to(0x00)            # P14 = P15 = 0: reset
a.nop(); a.nop()
a.ld_a(0x30); a.ldh_to(0x00)         # both high
a.ld_c(16)
a.l("byteloop")
a.ld_b(8)
a.ld_a_hli(); a.ld_d_a()
a.l("bitloop")
a.ld_a_d(); a.rrca(); a.ld_d_a()     # LSB into carry
a.ld_a(0x10)                         # P15 low  -> a 1 bit
a.jr_c("emit")
a.ld_a(0x20)                         # P14 low  -> a 0 bit
a.l("emit")
a.ldh_to(0x00)
a.nop()
a.ld_a(0x30); a.ldh_to(0x00)
a.dec_b(); a.jr_nz("bitloop")
a.dec_c(); a.jr_nz("byteloop")
a.ld_a(0x20); a.ldh_to(0x00)         # stop bit (0)
a.nop()
a.ld_a(0x30); a.ldh_to(0x00)
a.ret()

# --- data ---
rom[0x4000:0x5000] = chr_payload
rom[0x5000:0x6000] = pct_payload
rom[0x6000:0x6040] = bg_tiles

pkt_base = 0x6100
for i, name in enumerate(PACKET_ORDER):
    addr = pkt_base + i * 16
    rom[addr:addr + 16] = PACKETS[name]
    a.labels["pkt_" + name] = addr
    PACKET_ADDR[name] = addr

a.resolve()
assert a.pc < 0x4000, hex(a.pc)

# ---------------------------------------------------------------- header

rom[0x100:0x104] = bytes([0x00, 0xC3, 0x50, 0x01])   # nop; jp 0x0150

# The Nintendo logo. Required by real hardware (and by the SGB, which will not
# unlock its functions for a cart that fails the boot check).
LOGO = bytes([
    0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83,
    0x00, 0x0C, 0x00, 0x0D, 0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E,
    0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99, 0xBB, 0xBB, 0x67, 0x63,
    0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E,
])
rom[0x104:0x134] = LOGO

title = b"SGBTEST"
rom[0x134:0x134 + len(title)] = title
rom[0x143] = 0x00        # not CGB
rom[0x146] = 0x03        # SGB flag  -- required to unlock SGB functions
rom[0x147] = 0x00        # ROM only
rom[0x148] = 0x00        # 32 KiB
rom[0x149] = 0x00        # no cart RAM
rom[0x14B] = 0x33        # old licensee 0x33 -- also required (Pan Docs)

chk = 0
for i in range(0x134, 0x14D):
    chk = (chk - rom[i] - 1) & 0xFF
rom[0x14D] = chk

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sgbtest.gb")
with open(out, "wb") as f:
    f.write(rom)
print("wrote", out, len(rom), "bytes; program ends at", hex(a.pc))
print("packets:", {k: hex(v) for k, v in PACKET_ADDR.items()})
