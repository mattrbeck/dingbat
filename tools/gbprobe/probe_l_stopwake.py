#!/usr/bin/env python3
"""probe_l_stopwake -- what does a STOP woken by a key press do to the PPU
and the timer? (docs/gb-failure-triage.md I13, docs/hwprobe-questions.md)

    python3 tools/gbprobe/probe_l_stopwake.py <out.gb> <logo-donor.gb>

Generated here rather than assembled (no RGBDS needed). The Nintendo logo the
boot ROM checks is copied from <logo-donor.gb>, any bootable cart (e.g. one of
the probes beside this file); none of it is in this file. No CGB flag: a CGB or
AGB runs it in compatibility mode. The glyphs are roms/font.inc's.

Pan Docs ("Using the STOP Instruction") says STOP ends on a P10-P13 line going
low and nothing of the PPU or the timer across it, or of how long the wake
takes. dingbat freezes the whole machine in STOP mode and resumes where it
stopped; DocBoy's DMG `stop_read_{ly,stat}_*` rows need the PPU to have run
2^17 + 4 dots across the stop with the timer and the OAM DMA held
(STOP_WAKE_PPU_DOTS in cpu.nim); SameBoy agrees with dingbat.

ONE TRIAL (six, one per key press; the results stay on screen):
  wait until no key has been held for 256 polls (a held key turns STOP into a
  HALT: Pan Docs' STOP chart), LCD off in VBlank, then
      DIV := 0; TAC := $04 (4096 Hz, tap bit 9); TIMA := 0; TMA := 0
      IF := 0; IE := 0; P1 := $10 (action keys)
      LCDC := $91 -- the PPU starts line 0; the DIV reset is a fixed 13
                     M-cycles before it, so the two are locked together
      wait to line 20, STOP                <- press A, any time later
      read LY, STAT, TIMA, DIV at once, LY again 160 M-cycles later
  Row 2 + n shows trial n's five bytes in that order. Row 0: page code 5C,
  version 01, trials done.

READING (every trial should show the same five bytes; if LY differs from
trial to trial, the PPU free-runs through STOP and the wake time matters):
  14 82 09 00 15  dingbat, MGB and CGB-compat alike: the PPU resumes line 20
                  where it stopped; TIMA as at the STOP plus the reset's tick.
  00 85 09 00 01  dingbat with STOP_WAKE_PPU_DOTS = 131076 (DocBoy's rows): the
                  PPU ran 2^17 + 4 dots, to line 153 (LY reads 0, LYC = 0
                  matches), and line 1 a line later.
  .. .. 89 .. ..  the timer ran through a 2^17-T restart too (128 ticks of a
                  4096 Hz TIMA).
"""
import os
import sys

OUT, DONOR = sys.argv[1], sys.argv[2]

HERE = os.path.dirname(os.path.abspath(__file__))


def load_font():
    """The 16 hex glyphs of roms/font.inc (`dw` lines of rgbds pixel strings)."""
    glyphs = []
    for line in open(os.path.join(HERE, "roms", "font.inc")):
        line = line.strip()
        if line.startswith("dw `"):
            glyphs.append([p.strip().lstrip("`") for p in line[3:].split(",")])
    assert len(glyphs) == 16, len(glyphs)
    return glyphs


FONT = load_font()


def tile(rows):
    out = []
    for r in rows:
        lo = hi = 0
        for i, ch in enumerate(r):
            c = int(ch)
            lo |= (c & 1) << (7 - i)
            hi |= ((c >> 1) & 1) << (7 - i)
        out += [lo, hi]
    return out


class Asm:
    R = {"b": 0, "c": 1, "d": 2, "e": 3, "h": 4, "l": 5, "(hl)": 6, "a": 7}

    def __init__(self, org):
        self.org = org
        self.code = []
        self.labels = {}
        self.fix = []  # (pos, label, kind)

    def here(self):
        return self.org + len(self.code)

    def label(self, n):
        self.labels[n] = self.here()

    def b(self, *bs):
        self.code += list(bs)

    def w(self, v):
        self.b(v & 0xFF, (v >> 8) & 0xFF)

    def ref16(self, lab):
        self.fix.append((len(self.code), lab, "abs"))
        self.w(0)

    def ref8rel(self, lab):
        self.fix.append((len(self.code), lab, "rel"))
        self.b(0)

    # instructions
    def nop(self): self.b(0x00)
    def di(self): self.b(0xF3)
    def ei(self): self.b(0xFB)
    def stop(self): self.b(0x10, 0x00)
    def ret(self): self.b(0xC9)
    def ld_r_n(self, r, n): self.b(0x06 | (self.R[r] << 3), n & 0xFF)
    def ld_r_r(self, d, s): self.b(0x40 | (self.R[d] << 3) | self.R[s])
    def ldh_n_a(self, n): self.b(0xE0, n & 0xFF)
    def ldh_a_n(self, n): self.b(0xF0, n & 0xFF)
    def ld_hl_nn(self, v): self.b(0x21); self.w(v)
    def ld_de_nn(self, v): self.b(0x11); self.w(v)
    def ld_bc_nn(self, v): self.b(0x01); self.w(v)
    def ld_sp_nn(self, v): self.b(0x31); self.w(v)
    def ld_de_lab(self, lab): self.b(0x11); self.ref16(lab)
    def ld_hli_a(self): self.b(0x22)
    def ld_a_hli(self): self.b(0x2A)
    def ld_a_de(self): self.b(0x1A)
    def ld_nn_a(self, v): self.b(0xEA); self.w(v)
    def ld_a_nn(self, v): self.b(0xFA); self.w(v)
    def inc_r(self, r): self.b(0x04 | (self.R[r] << 3))
    def dec_r(self, r): self.b(0x05 | (self.R[r] << 3))
    def inc_de(self): self.b(0x13)
    def inc_hl(self): self.b(0x23)
    def dec_bc(self): self.b(0x0B)
    def dec_de(self): self.b(0x1B)
    def or_r(self, r): self.b(0xB0 | self.R[r])
    def xor_a(self): self.b(0xAF)
    def and_n(self, n): self.b(0xE6, n)
    def cp_n(self, n): self.b(0xFE, n)
    def add_n(self, n): self.b(0xC6, n)
    def adc_n(self, n): self.b(0xCE, n)
    def swap_a(self): self.b(0xCB, 0x37)
    def push_bc(self): self.b(0xC5)
    def pop_bc(self): self.b(0xC1)
    def push_hl(self): self.b(0xE5)
    def pop_hl(self): self.b(0xE1)
    def jr(self, lab, cc=None):
        op = {None: 0x18, "nz": 0x20, "z": 0x28, "nc": 0x30, "c": 0x38}[cc]
        self.b(op); self.ref8rel(lab)
    def jp(self, lab): self.b(0xC3); self.ref16(lab)
    def call(self, lab): self.b(0xCD); self.ref16(lab)

    def nops(self, n):
        for _ in range(n):
            self.nop()

    def wait(self, m):
        """Exactly m M-cycles (m >= 8): ld de,k; loop {dec de; ld a,d; or e;
        jr nz} = 2+1+1+3 taken, 2+1+1+2 last; pad with nops. Clobbers a, de."""
        # ld de,nn = 3; loop k iterations = 7k - 1; total 3 + 7k - 1 = 7k + 2
        k = (m - 2) // 7
        pad = m - (7 * k + 2)
        assert k >= 1 and pad >= 0
        lab = f"_w{len(self.code)}"
        self.ld_de_nn(k)
        self.label(lab)
        self.dec_de()
        self.ld_r_r("a", "d")
        self.or_r("e")
        self.jr(lab, "nz")
        self.nops(pad)

    def resolve(self):
        for pos, lab, kind in self.fix:
            t = self.labels[lab]
            if kind == "abs":
                self.code[pos] = t & 0xFF
                self.code[pos + 1] = t >> 8
            else:
                d = t - (self.org + pos + 1)
                assert -128 <= d <= 127, (lab, d)
                self.code[pos] = d & 0xFF


LY, STAT, DIV, TIMA, TMA, TAC, IF, IE, P1, LCDC, BGP, SCX, SCY = (
    0x44, 0x41, 0x04, 0x05, 0x06, 0x07, 0x0F, 0xFF, 0x00, 0x40, 0x47, 0x43, 0x42)
FONT_BASE = 0x10
TRIALS = 6
RES = 0xC000          # 8 bytes per trial
N0 = 20 * 114         # M-cycles from the LCD enable to the STOP fetch (line 20)
POST = 160            # M-cycles between the two LY reads after the wake

a = Asm(0x150)
a.label("Start")
a.di()
a.ld_sp_nn(0xDFFF)
# clear results, trial counter in $C0F0
a.ld_hl_nn(RES)
a.ld_r_n("b", 0xF1)
a.xor_a()
a.label("clr")
a.ld_hli_a()
a.dec_r("b")
a.jr("clr", "nz")

a.label("Trial")
# --- LCD off at VBlank, font + map with results so far, LCD on (text) ---
a.call("LcdOff")
a.call("Draw")
a.ld_r_n("a", 0x91)
a.ldh_n_a(LCDC)
a.ld_a_nn(0xC0F0)
a.cp_n(TRIALS)
a.jr("Idle", "z")
# --- wait until no button held for 256 consecutive polls ---
a.ld_r_n("a", 0x10)
a.ldh_n_a(P1)
a.label("rel0")
a.ld_r_n("c", 0)
a.label("rel1")
a.ldh_a_n(P1)
a.and_n(0x0F)
a.cp_n(0x0F)
a.jr("rel0", "nz")
a.dec_r("c")
a.jr("rel1", "nz")
# --- the measurement ---
a.call("LcdOff")
a.xor_a()
a.ldh_n_a(DIV)        # divider := 0 first: its own glitch tick lands on a TIMA reset below
a.ld_r_n("a", 0x04)
a.ldh_n_a(TAC)        # 4096 Hz, tap bit 9: low for 512 T after the reset, no glitch
a.xor_a()
a.ldh_n_a(TIMA)
a.ldh_n_a(TMA)
a.ldh_n_a(IF)
a.ldh_n_a(IE)
a.ld_r_n("a", 0x10)
a.ldh_n_a(P1)
a.ld_r_n("a", 0x91)
a.ldh_n_a(LCDC)       # PPU restarts here, a fixed 13 M-cycles after the DIV reset
a.wait(N0 - 2)        # ldh LCDC's own write lands at its end; STOP fetched N0 later
a.stop()
a.ldh_a_n(LY)
a.ld_r_r("b", "a")
a.ldh_a_n(STAT)
a.ld_r_r("c", "a")
a.ldh_a_n(TIMA)
a.ld_r_r("h", "a")
a.ldh_a_n(DIV)
a.ld_r_r("l", "a")
a.wait(POST)          # clobbers a, de only
a.ldh_a_n(LY)
a.ld_r_r("e", "a")
a.ld_r_r("a", "h"); a.ld_nn_a(0xC0F9)
a.ld_r_r("a", "l"); a.ld_nn_a(0xC0FA)
a.ld_a_nn(0xC0F0)
a.b(0x87, 0x87, 0x87)  # add a,a x3 -> 8 * trial
a.ld_r_r("l", "a")
a.ld_r_n("h", RES >> 8)
a.ld_r_r("a", "b"); a.ld_hli_a()
a.ld_r_r("a", "c"); a.ld_hli_a()
a.ld_a_nn(0xC0F9); a.ld_hli_a()
a.ld_a_nn(0xC0FA); a.ld_hli_a()
a.ld_r_r("a", "e"); a.ld_hli_a()
a.ld_a_nn(0xC0F0)
a.inc_r("a")
a.ld_nn_a(0xC0F0)
a.jp("Trial")

a.label("Idle")
a.b(0x76)             # halt (IE = 0: never wakes; the screen holds)
a.jr("Idle")

# LcdOff: wait LY = 145 if on, then LCDC = 0
a.label("LcdOff")
a.ldh_a_n(LCDC)
a.and_n(0x80)
a.b(0xC8)             # ret z
a.label("lo1")
a.ldh_a_n(LY)
a.cp_n(145)
a.jr("lo1", "nz")
a.xor_a()
a.ldh_n_a(LCDC)
a.ret()

# Draw: font at $8100, map cleared, header row 0, results rows 2..7
a.label("Draw")
a.ld_r_n("a", 0xE4)
a.ldh_n_a(BGP)
a.xor_a()
a.ldh_n_a(SCX)
a.ldh_n_a(SCY)
a.ld_hl_nn(0x8000)    # clear tile 0 (blank) and the map
a.ld_r_n("b", 16)
a.label("d0")
a.ld_hli_a()
a.dec_r("b")
a.jr("d0", "nz")
a.ld_hl_nn(0x9800)
a.ld_bc_nn(0x400)
a.label("d1")
a.xor_a()
a.ld_hli_a()
a.dec_bc()
a.ld_r_r("a", "b")
a.or_r("c")
a.jr("d1", "nz")
a.ld_hl_nn(0x8000 + FONT_BASE * 16)
a.ld_de_lab("Font")
a.ld_bc_nn(16 * 16)
a.label("d2")
a.ld_a_de()
a.inc_de()
a.ld_hli_a()
a.dec_bc()
a.ld_r_r("a", "b")
a.or_r("c")
a.jr("d2", "nz")
# header: 5C 01 (page code, version) at row 0
a.ld_hl_nn(0x9801)
a.ld_r_n("a", 0x5C); a.call("PutByte")
a.ld_r_n("a", 0x01); a.call("PutByte")
a.ld_a_nn(0xC0F0); a.call("PutByte")
# rows 2..7: 5 bytes each
a.ld_de_nn(RES)
a.ld_hl_nn(0x9800 + 2 * 32 + 1)
a.ld_r_n("c", TRIALS)
a.label("d3")
a.ld_r_n("b", 5)
a.push_hl()
a.label("d4")
a.ld_a_de()
a.inc_de()
a.call("PutByte")
a.inc_hl()            # a space between bytes
a.dec_r("b")
a.jr("d4", "nz")
a.inc_de(); a.inc_de(); a.inc_de()   # slots are 8 bytes
a.pop_hl()
a.ld_r_r("a", "l"); a.add_n(32); a.ld_r_r("l", "a")
a.ld_r_r("a", "h"); a.adc_n(0); a.ld_r_r("h", "a")
a.dec_r("c")
a.jr("d3", "nz")
a.ret()

# PutByte: A as two glyphs at [hl], hl += 2
a.label("PutByte")
a.push_bc()
a.ld_r_r("b", "a")
a.swap_a()
a.and_n(0x0F)
a.add_n(FONT_BASE)
a.ld_hli_a()
a.ld_r_r("a", "b")
a.and_n(0x0F)
a.add_n(FONT_BASE)
a.ld_hli_a()
a.pop_bc()
a.ret()

a.label("Font")
for g in FONT:
    a.b(*tile(g))

a.resolve()

rom = bytearray(32768)
donor = open(DONOR, "rb").read()
rom[0x104:0x134] = donor[0x104:0x134]          # the logo, from the donor cart
rom[0x100:0x104] = bytes([0x00, 0xC3, 0x50, 0x01])
title = b"STOPWAKE"
rom[0x134:0x134 + len(title)] = title
rom[0x143] = 0x00      # no CGB flag: a CGB/AGB runs it in compatibility mode
rom[0x147] = 0x00
rom[0x148] = 0x00
rom[0x149] = 0x00
rom[0x14A] = 0x01
rom[0x14B] = 0x00
code = bytes(a.code)
rom[0x150:0x150 + len(code)] = code
chk = 0
for i in range(0x134, 0x14D):
    chk = (chk - rom[i] - 1) & 0xFF
rom[0x14D] = chk
g = sum(rom) - rom[0x14E] - rom[0x14F]
rom[0x14E] = (g >> 8) & 0xFF
rom[0x14F] = g & 0xFF
open(OUT, "wb").write(rom)
print(f"wrote {OUT}: code {len(code)} bytes")
