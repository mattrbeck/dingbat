#!/usr/bin/env python3
"""Builds gbedge.gb — a paginated GB/GBC hardware edge-case probe ROM.

The existing suites (mooneye, gambatte, blargg, AGE, GBMicrotest, SameSuite,
mealybug) bake an expected value into the ROM and print pass/fail. This ROM
deliberately does NOT: every probe runs a choreographed, cycle-deterministic
sequence from power-on and stores the RAW values it observed (register burst
samples, IRQ counts, conflict bytes) into a 32-byte result slot. The viewer
then lets you page through the slots as hex dumps with LEFT/RIGHT.

Real hardware is the oracle: photograph every page on a console, screenshot
the same pages in an emulator, and diff. Where consoles of different models
disagree with each other, that is data too — several probes (unused regs,
OAM corruption, STAT write bug) are model fingerprints on purpose.

Determinism contract: every probe either runs entirely from a state it fully
constructs (LCD off -> re-enable realigns the PPU; DIV write realigns the
timer) or samples at a fixed instruction offset from entry. No probe depends
on uninitialized RAM. Interrupts only ever run during a probe that armed
them. So a given (ROM, console model) pair always shows the same bytes.

LCD is only ever switched off during vblank (hardware-safety rule).

Build:  python3 gbedge.py            -> gbedge.gb      (manual paging)
        python3 gbedge.py --autopage -> gbedge-auto.gb (page++ every 64
                                        frames, for input-less emulator
                                        screenshot harnesses)

Hand-assembled SM83 like the other ROMs here, but through a small two-pass
assembler (below) because this suite is ~2000 instructions, not 40.
"""
import os
import sys

import romfix

AUTOPAGE = "--autopage" in sys.argv

# ═══════════════════════════════════════════════════════════════════════════
# mini-assembler: two-pass, label fixups for jr/jp/call/ld rr,label
# ═══════════════════════════════════════════════════════════════════════════

R8 = {"b": 0, "c": 1, "d": 2, "e": 3, "h": 4, "l": 5, "hl": 6, "a": 7}
R16 = {"bc": 0x00, "de": 0x10, "hl": 0x20, "sp": 0x30}
R16P = {"bc": 0x00, "de": 0x10, "hl": 0x20, "af": 0x30}   # push/pop
CC = {"nz": 0x00, "z": 0x08, "nc": 0x10, "c": 0x18}


class Asm:
    def __init__(self):
        self.rom = bytearray(0x8000)
        self.pc = 0x150
        self.labels = {}
        self.fixups = []          # (addr, kind, label)

    # ── placement ────────────────────────────────────────────────────────
    def org(self, addr):
        self.pc = addr

    def label(self, name):
        assert name not in self.labels, f"duplicate label {name}"
        self.labels[name] = self.pc
        return self.pc

    def db(self, *byts):
        for x in byts:
            assert 0 <= x <= 0xFF, hex(x)
            self.rom[self.pc] = x
            self.pc += 1

    def dw(self, val):
        self.db(val & 0xFF, val >> 8)

    def blob(self, data):
        self.rom[self.pc:self.pc + len(data)] = data
        self.pc += len(data)

    def _imm16(self, target):
        if isinstance(target, str):
            self.fixups.append((self.pc, "abs", target))
            self.db(0, 0)
        else:
            self.dw(target)

    # ── loads ────────────────────────────────────────────────────────────
    def ld_r_n(self, r, n):        self.db(0x06 | (R8[r] << 3), n & 0xFF)
    def ld_r_r(self, d, s):        self.db(0x40 | (R8[d] << 3) | R8[s])
    def ld_rr_nn(self, rr, nn):    self.db(0x01 | R16[rr]); self._imm16(nn)
    def ld_a_rr(self, rr):         self.db({"bc": 0x0A, "de": 0x1A}[rr])
    def ld_rr_a(self, rr):         self.db({"bc": 0x02, "de": 0x12}[rr])
    def ld_a_hli(self):            self.db(0x2A)
    def ld_a_hld(self):            self.db(0x3A)
    def ld_hli_a(self):            self.db(0x22)
    def ld_hld_a(self):            self.db(0x32)
    def ld_a_nn(self, nn):         self.db(0xFA); self._imm16(nn)
    def ld_nn_a(self, nn):         self.db(0xEA); self._imm16(nn)
    def ld_nn_sp(self, nn):        self.db(0x08); self._imm16(nn)
    def ld_sp_hl(self):            self.db(0xF9)
    def ldh_a_n(self, n):          self.db(0xF0, n & 0xFF)
    def ldh_n_a(self, n):          self.db(0xE0, n & 0xFF)
    def ldh_a_c(self):             self.db(0xF2)
    def ldh_c_a(self):             self.db(0xE2)

    # ── alu ──────────────────────────────────────────────────────────────
    def _alu_r(self, op, r):       self.db(0x80 | (op << 3) | R8[r])
    def _alu_n(self, op, n):       self.db(0xC6 | (op << 3), n & 0xFF)
    def add_a_r(self, r):          self._alu_r(0, r)
    def adc_a_r(self, r):          self._alu_r(1, r)
    def sub_r(self, r):            self._alu_r(2, r)
    def and_r(self, r):            self._alu_r(4, r)
    def xor_r(self, r):            self._alu_r(5, r)
    def or_r(self, r):             self._alu_r(6, r)
    def cp_r(self, r):             self._alu_r(7, r)
    def add_a_n(self, n):          self._alu_n(0, n)
    def adc_a_n(self, n):          self._alu_n(1, n)
    def sub_n(self, n):            self._alu_n(2, n)
    def and_n(self, n):            self._alu_n(4, n)
    def xor_n(self, n):            self._alu_n(5, n)
    def or_n(self, n):             self._alu_n(6, n)
    def cp_n(self, n):             self._alu_n(7, n)
    def inc_r(self, r):            self.db(0x04 | (R8[r] << 3))
    def dec_r(self, r):            self.db(0x05 | (R8[r] << 3))
    def inc_rr(self, rr):          self.db(0x03 | R16[rr])
    def dec_rr(self, rr):          self.db(0x0B | R16[rr])
    def add_hl_rr(self, rr):       self.db(0x09 | R16[rr])
    def rlca(self):                self.db(0x07)
    def rrca(self):                self.db(0x0F)
    def rla(self):                 self.db(0x17)
    def rra(self):                 self.db(0x1F)
    def cpl(self):                 self.db(0x2F)
    def scf(self):                 self.db(0x37)
    def daa(self):                 self.db(0x27)

    # ── CB prefix ────────────────────────────────────────────────────────
    def swap_r(self, r):           self.db(0xCB, 0x30 | R8[r])
    def srl_r(self, r):            self.db(0xCB, 0x38 | R8[r])
    def sla_r(self, r):            self.db(0xCB, 0x20 | R8[r])
    def rl_r(self, r):             self.db(0xCB, 0x10 | R8[r])
    def bit_r(self, b, r):         self.db(0xCB, 0x40 | (b << 3) | R8[r])
    def res_r(self, b, r):         self.db(0xCB, 0x80 | (b << 3) | R8[r])
    def set_r(self, b, r):         self.db(0xCB, 0xC0 | (b << 3) | R8[r])

    # ── flow ─────────────────────────────────────────────────────────────
    def jr(self, target, cond=None):
        op = 0x18 if cond is None else 0x20 | CC[cond]
        if isinstance(target, str) and target not in self.labels:
            self.fixups.append((self.pc, "rel", target))
            self.db(op, 0)
        else:
            dest = self.labels[target] if isinstance(target, str) else target
            off = dest - (self.pc + 2)
            assert -128 <= off <= 127, f"jr out of range to {target}: {off}"
            self.db(op, off & 0xFF)

    def jp(self, target, cond=None):
        self.db(0xC3 if cond is None else 0xC2 | CC[cond])
        self._imm16(target)

    def jp_hl(self):               self.db(0xE9)
    def call(self, target, cond=None):
        self.db(0xCD if cond is None else 0xC4 | CC[cond])
        self._imm16(target)

    def ret(self, cond=None):
        self.db(0xC9 if cond is None else 0xC0 | CC[cond])

    def reti(self):                self.db(0xD9)
    def rst(self, n):              self.db(0xC7 | n)
    def push(self, rr):            self.db(0xC5 | R16P[rr])
    def pop(self, rr):             self.db(0xC1 | R16P[rr])
    def nop(self):                 self.db(0x00)
    def halt(self):                self.db(0x76)
    def stop(self):                self.db(0x10, 0x00)
    def di(self):                  self.db(0xF3)
    def ei(self):                  self.db(0xFB)

    # ── exact M-cycle delay (clobbers a, b, c, flags) ────────────────────
    def delay(self, m):
        assert m >= 0
        if m <= 24:
            for _ in range(m):
                self.nop()
            return
        # 16-bit loop: ld bc,k (3) + k iters of [dec bc(2); ld a,b(1);
        # or c(1); jr nz(3)] with the last jr not taken (2): 3 + 7k - 1.
        k = (m - 8) // 7
        assert 1 <= k <= 0xFFFF
        used = 7 * k + 2
        self.ld_rr_nn("bc", k)
        top = self.pc
        self.dec_rr("bc")
        self.ld_r_r("a", "b")
        self.or_r("c")
        self.jr(top, "nz")
        for _ in range(m - used):
            self.nop()

    # ── finalize ─────────────────────────────────────────────────────────
    def resolve(self):
        for addr, kind, name in self.fixups:
            dest = self.labels[name]
            if kind == "abs":
                self.rom[addr] = dest & 0xFF
                self.rom[addr + 1] = dest >> 8
            else:
                off = dest - (addr + 2)
                assert -128 <= off <= 127, f"jr out of range to {name}: {off}"
                self.rom[addr + 1] = off & 0xFF


# delay() cycle counts are the documented ones, not self-checked:
# ld rr,nn=3, dec rr=2, ld r,r=1, or r=1, jr taken=3 / not=2, nop=1.

# ═══════════════════════════════════════════════════════════════════════════
# hardware constants
# ═══════════════════════════════════════════════════════════════════════════

P1, SB, SC, DIV, TIMA, TMA, TAC = 0x00, 0x01, 0x02, 0x04, 0x05, 0x06, 0x07
IF, LCDC, STAT, SCY, SCX, LY, LYC = 0x0F, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45
DMA, BGP, OBP0, OBP1, WY, WX = 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B
KEY1, VBK, HDMA1, HDMA2, HDMA3, HDMA4, HDMA5 = 0x4D, 0x4F, 0x51, 0x52, 0x53, 0x54, 0x55
RP, BCPS, BCPD, OCPS, OCPD, OPRI, SVBK = 0x56, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x70
IE = 0xFF                                     # as ldh offset

# WRAM layout
SNAP = 0xC000          # 16-byte entry snapshot
TRAMP = 0xC0E0         # 5 interrupt trampolines, 4 bytes apart (jp nnnn)
SLOTS = 0xC100         # result slots, 32 bytes each
SLOT_SIZE = 32
SCRATCH = 0xC600       # per-probe scratch
STACK_TOP = 0xDFF0

# HRAM: FF80 = running probe index, FF81 = probe stage breadcrumb, FF82 =
# 0x01 once the viewer is reached (a hung probe leaves its index behind —
# and GBMicrotest-style harnesses that read $FF80-$FF82 can score liveness)
B_PROBE, B_STAGE, B_ALIVE = 0x80, 0x81, 0x82
# HRAM viewer variables
V_PAGE, V_PREV, V_FRAME, V_TMP = 0x88, 0x89, 0x8A, 0x8B

# ═══════════════════════════════════════════════════════════════════════════
# 8x8 1bpp font: space, 0-9, A-Z, dash, slash  (tile 0 = blank = space)
# ═══════════════════════════════════════════════════════════════════════════

GLYPHS = {
    "0": ["01110",
          "10001",
          "10011",
          "10101",
          "11001",
          "10001",
          "01110"],
    "1": ["00100",
          "01100",
          "00100",
          "00100",
          "00100",
          "00100",
          "01110"],
    "2": ["01110",
          "10001",
          "00001",
          "00110",
          "01000",
          "10000",
          "11111"],
    "3": ["01110",
          "10001",
          "00001",
          "00110",
          "00001",
          "10001",
          "01110"],
    "4": ["00010",
          "00110",
          "01010",
          "10010",
          "11111",
          "00010",
          "00010"],
    "5": ["11111",
          "10000",
          "11110",
          "00001",
          "00001",
          "10001",
          "01110"],
    "6": ["00110",
          "01000",
          "10000",
          "11110",
          "10001",
          "10001",
          "01110"],
    "7": ["11111",
          "00001",
          "00010",
          "00100",
          "01000",
          "01000",
          "01000"],
    "8": ["01110",
          "10001",
          "10001",
          "01110",
          "10001",
          "10001",
          "01110"],
    "9": ["01110",
          "10001",
          "10001",
          "01111",
          "00001",
          "00010",
          "01100"],
    "A": ["01110",
          "10001",
          "10001",
          "11111",
          "10001",
          "10001",
          "10001"],
    "B": ["11110",
          "10001",
          "10001",
          "11110",
          "10001",
          "10001",
          "11110"],
    "C": ["01110",
          "10001",
          "10000",
          "10000",
          "10000",
          "10001",
          "01110"],
    "D": ["11110",
          "10001",
          "10001",
          "10001",
          "10001",
          "10001",
          "11110"],
    "E": ["11111",
          "10000",
          "10000",
          "11110",
          "10000",
          "10000",
          "11111"],
    "F": ["11111",
          "10000",
          "10000",
          "11110",
          "10000",
          "10000",
          "10000"],
    "G": ["01110",
          "10001",
          "10000",
          "10111",
          "10001",
          "10001",
          "01111"],
    "H": ["10001",
          "10001",
          "10001",
          "11111",
          "10001",
          "10001",
          "10001"],
    "I": ["01110",
          "00100",
          "00100",
          "00100",
          "00100",
          "00100",
          "01110"],
    "J": ["00111",
          "00010",
          "00010",
          "00010",
          "00010",
          "10010",
          "01100"],
    "K": ["10001",
          "10010",
          "10100",
          "11000",
          "10100",
          "10010",
          "10001"],
    "L": ["10000",
          "10000",
          "10000",
          "10000",
          "10000",
          "10000",
          "11111"],
    "M": ["10001",
          "11011",
          "10101",
          "10101",
          "10001",
          "10001",
          "10001"],
    "N": ["10001",
          "11001",
          "10101",
          "10011",
          "10001",
          "10001",
          "10001"],
    "O": ["01110",
          "10001",
          "10001",
          "10001",
          "10001",
          "10001",
          "01110"],
    "P": ["11110",
          "10001",
          "10001",
          "11110",
          "10000",
          "10000",
          "10000"],
    "Q": ["01110",
          "10001",
          "10001",
          "10001",
          "10101",
          "10010",
          "01101"],
    "R": ["11110",
          "10001",
          "10001",
          "11110",
          "10100",
          "10010",
          "10001"],
    "S": ["01111",
          "10000",
          "10000",
          "01110",
          "00001",
          "00001",
          "11110"],
    "T": ["11111",
          "00100",
          "00100",
          "00100",
          "00100",
          "00100",
          "00100"],
    "U": ["10001",
          "10001",
          "10001",
          "10001",
          "10001",
          "10001",
          "01110"],
    "V": ["10001",
          "10001",
          "10001",
          "10001",
          "10001",
          "01010",
          "00100"],
    "W": ["10001",
          "10001",
          "10001",
          "10101",
          "10101",
          "11011",
          "10001"],
    "X": ["10001",
          "10001",
          "01010",
          "00100",
          "01010",
          "10001",
          "10001"],
    "Y": ["10001",
          "10001",
          "01010",
          "00100",
          "00100",
          "00100",
          "00100"],
    "Z": ["11111",
          "00001",
          "00010",
          "00100",
          "01000",
          "10000",
          "11111"],
    "-": ["00000",
          "00000",
          "00000",
          "01110",
          "00000",
          "00000",
          "00000"],
    "/": ["00001",
          "00010",
          "00010",
          "00100",
          "01000",
          "01000",
          "10000"],
    ".": ["00000",
          "00000",
          "00000",
          "00000",
          "00000",
          "01100",
          "01100"],
}

FONT_ORDER = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-/."


def tile_of(ch):
    return FONT_ORDER.index(ch)


def font_1bpp():
    out = bytearray()
    for ch in FONT_ORDER:
        if ch == " ":
            out += bytes(8)
            continue
        rows = GLYPHS[ch]
        for y in range(8):
            bits = 0
            if y < 7:
                for x, c in enumerate(rows[y]):
                    if c == "1":
                        bits |= 0x80 >> (x + 1)   # 1px left margin
            out.append(bits)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# test registry: (short name <=10 chars, emit function).  Each emit function
# writes a routine that fills its 32-byte slot and returns with ret.  The
# routine is entered with interrupts disabled, LCD ON in vblank, IE=0, IF
# undefined, and must leave LCD ON (in any line) and IME disabled.
# ═══════════════════════════════════════════════════════════════════════════

TESTS = []


def test(name):
    def deco(fn):
        TESTS.append((name, fn))
        return fn
    return deco


def slot_addr(idx):
    return SLOTS + idx * SLOT_SIZE


# common helpers emitted once, called by tests --------------------------------

def emit_helpers(a):
    # wait_vblank: poll LY until ==145 (well inside vblank).  clobbers a,f.
    a.label("wait_vblank")
    a.ldh_a_n(LY)
    a.cp_n(145)
    a.jr("wait_vblank", "nz")
    a.ret()

    # lcd_off_safe: wait for vblank, then LCDC=0.  clobbers a,f.
    a.label("lcd_off_safe")
    a.call("wait_vblank")
    a.xor_r("a")
    a.ldh_n_a(LCDC)
    a.ret()

    # clear_slot: hl = slot, fill 32 bytes with 0.  clobbers a,b,f; hl -> +32
    a.label("clear_slot")
    a.ld_r_n("b", SLOT_SIZE)
    a.xor_r("a")
    a.label("cs_loop")
    a.ld_hli_a()
    a.dec_r("b")
    a.jr("cs_loop", "nz")
    a.ret()

    # default interrupt target: just return
    a.label("int_ret")
    a.reti()

    # install default trampolines: all five vectors -> int_ret
    a.label("reset_tramps")
    a.ld_rr_nn("hl", TRAMP)
    a.ld_r_n("b", 5)
    a.label("rt_loop")
    a.ld_r_n("a", 0xC3)              # jp
    a.ld_hli_a()
    a.ld_r_n("a", 0)                 # int_ret lo (patched below in resolve)
    a.fixups.append((a.pc - 1, "abs8lo", "int_ret"))
    a.ld_hli_a()
    a.ld_r_n("a", 0)
    a.fixups.append((a.pc - 1, "abs8hi", "int_ret"))
    a.ld_hli_a()
    a.inc_rr("hl")                   # 4-byte stride
    a.dec_r("b")
    a.jr("rt_loop", "nz")
    a.ret()


# patch kinds "abs8lo"/"abs8hi" write one byte of a label address into the
# immediate operand of a ld r,n — extend resolve for them.
_orig_resolve = Asm.resolve


def _resolve(self):
    leftovers = []
    for addr, kind, name in self.fixups:
        if kind == "abs8lo":
            self.rom[addr] = self.labels[name] & 0xFF
        elif kind == "abs8hi":
            self.rom[addr] = self.labels[name] >> 8
        else:
            leftovers.append((addr, kind, name))
    self.fixups = leftovers
    _orig_resolve(self)


Asm.resolve = _resolve


# ═══════════════════════════════════════════════════════════════════════════
# probes
# ═══════════════════════════════════════════════════════════════════════════

@test("IDENT")
def t_ident(a, slot, p):
    """Boot handoff snapshot + initial I/O readbacks.

    00-07  A F B C D E H L as handed over by the boot ROM
    08-09  SP (lo, hi)
    0A-0F  DIV LY STAT IF LCDC IE sampled at a fixed offset from entry
    10-1F  P1 KEY1 VBK SVBK FF72 FF73 FF74 FF75 PCM12 PCM34 OPRI RP SB SC
           TAC FF03 read back untouched-since-boot (except IE/IF/VBK, which
           init already wrote — VBK reads back its CGB floor value anyway)

    DMG=01/xx, MGB=FF, SGB=01/14, SGB2=FF, CGB=11 with B bit0 clear, AGB/GBA
    =11 with B bit0 set.  The DIV byte at 0A is the boot ROM's handoff phase
    — a per-model constant no suite pins down, and emulator boot tables get
    it wrong more often than the named registers.
    """
    a.ld_rr_nn("hl", SNAP)
    a.ld_rr_nn("de", slot)
    a.ld_r_n("b", 16)
    a.label(f"{p}_cp")
    a.ld_a_hli()
    a.ld_rr_a("de")
    a.inc_rr("de")
    a.dec_r("b")
    a.jr(f"{p}_cp", "nz")
    regs = [P1, KEY1, VBK, SVBK, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77,
            OPRI, RP, SB, SC, TAC, 0x03]
    for i, off in enumerate(regs):
        a.ldh_a_n(off)
        a.ld_nn_a(slot + 16 + i)


FRAME_M = 70224 // 4                   # M-cycles per frame, single speed


def burst(a, dest, delay_m, reg, n):
    """LCD off (vblank-safe) -> LCD on -> exact delay -> n reads of FF00+reg
    stored to dest.  Each sample is 5 M-cycles (20 dots) after the previous;
    the read lands on the 1st M-cycle of `ld a,(hl)`... in truth somewhere
    fixed inside it, which is exactly the kind of constant this ROM treats
    as part of the measurement.  Emit several calls with delay_m+1..+4 for
    dot-resolution phase sweeps."""
    a.ld_rr_nn("hl", 0xFF00 + reg)
    a.ld_rr_nn("de", dest)
    a.ld_r_n("a", 0x91)
    a.ldh_n_a(LCDC)
    a.delay(delay_m)
    for _ in range(n):
        a.ld_r_r("a", "hl")            # 2 M
        a.ld_rr_a("de")                # 2 M
        a.inc_rr("de")                 # 1 M


def dot_delay(dot, frame=1):
    """M-cycle delay from the LCD-enabling write to roughly `dot` of frame
    `frame` (0 = the frame the LCD turns on in).  The exact dot the first
    sample lands on has a small constant offset — irrelevant, since every
    implementation gets the same constant."""
    return (frame * 70224 + dot) // 4


def patch_tramp(a, tramp_off, target):
    """Point one of the WRAM interrupt trampolines at `target` (a label)."""
    a.ld_r_n("a", 0xC3)
    a.ld_nn_a(TRAMP + tramp_off)
    a.ld_r_n("a", 0)
    a.fixups.append((a.pc - 1, "abs8lo", target))
    a.ld_nn_a(TRAMP + tramp_off + 1)
    a.ld_r_n("a", 0)
    a.fixups.append((a.pc - 1, "abs8hi", target))
    a.ld_nn_a(TRAMP + tramp_off + 2)


@test("DIVPHASE")
def t_divphase(a, slot, p):
    """DIV write-to-first-increment phase, and the TAC mux seen through TIMA.

    00-0F  run k (k = 56..71): `xor a / ldh (DIV),a`, wait k M-cycles, read
           DIV.  The 00->01 transition column pins the reset-to-increment
           distance at 1 M-cycle resolution (expected near 64 M, i.e. k=61
           +/- the sub-instruction write/read offsets).
    10-17  run k (k = 10..17): TAC=05 (16-T period), reset DIV, TIMA=0,
           wait k, read TIMA.  Pins the mux-bit phase TIMA ticks on.
    """
    for i, k in enumerate(range(56, 72)):
        a.xor_r("a")
        a.ldh_n_a(DIV)
        a.delay(k)
        a.ldh_a_n(DIV)
        a.ld_nn_a(slot + i)
    for i, k in enumerate(range(10, 18)):
        a.ld_r_n("a", 0x05)
        a.ldh_n_a(TAC)
        a.xor_r("a")
        a.ldh_n_a(DIV)
        a.xor_r("a")
        a.ldh_n_a(TIMA)
        a.delay(k)
        a.ldh_a_n(TIMA)
        a.ld_nn_a(slot + 16 + i)
        a.xor_r("a")
        a.ldh_n_a(TAC)


@test("TIMAGLITCH")
def t_timaglitch(a, slot, p):
    """The timer falling-edge detector, provoked three ways.

    00-07  DIV write while the TAC=05 mux bit is high: k = 0..7 M-cycles
           between two DIV writes, read TIMA.  The extra +1s mark the
           phases where the reset itself clocked TIMA (expected at 2 of
           every 4 k on DMG; the phase column is the fingerprint).
    08-0F  same k sweep, but the second write disables TAC instead.  DMG
           gains an increment when the mux bit was high; CGB revisions
           handle the disable glitch differently.
    10-13  k = 0..3, TAC written 05->06 while running (frequency switch
           glitch: old-bit/new-bit selection differs between models).
    14-17  rate sanity at each TAC frequency: TIMA after 256 M-cycles
           (expected 01/40/10/04 hex; a calibration row for reading the
           rest).
    """
    for i, k in enumerate(range(8)):
        a.ld_r_n("a", 0x05)
        a.ldh_n_a(TAC)
        a.xor_r("a")
        a.ldh_n_a(DIV)
        a.xor_r("a")
        a.ldh_n_a(TIMA)
        a.delay(k)
        a.xor_r("a")
        a.ldh_n_a(DIV)
        a.ldh_a_n(TIMA)
        a.ld_nn_a(slot + i)
        a.xor_r("a")
        a.ldh_n_a(TAC)
    for i, k in enumerate(range(8)):
        a.ld_r_n("a", 0x05)
        a.ldh_n_a(TAC)
        a.xor_r("a")
        a.ldh_n_a(DIV)
        a.xor_r("a")
        a.ldh_n_a(TIMA)
        a.delay(k)
        a.xor_r("a")
        a.ldh_n_a(TAC)
        a.ldh_a_n(TIMA)
        a.ld_nn_a(slot + 8 + i)
    for i, k in enumerate(range(4)):
        a.ld_r_n("a", 0x05)
        a.ldh_n_a(TAC)
        a.xor_r("a")
        a.ldh_n_a(DIV)
        a.xor_r("a")
        a.ldh_n_a(TIMA)
        a.delay(k)
        a.ld_r_n("a", 0x06)
        a.ldh_n_a(TAC)
        a.ldh_a_n(TIMA)
        a.ld_nn_a(slot + 16 + i)
        a.xor_r("a")
        a.ldh_n_a(TAC)
    for i, f in enumerate(range(4)):
        a.ld_r_n("a", 0x04 | f)
        a.ldh_n_a(TAC)
        a.xor_r("a")
        a.ldh_n_a(DIV)
        a.xor_r("a")
        a.ldh_n_a(TIMA)
        a.delay(256)
        a.ldh_a_n(TIMA)
        a.ld_nn_a(slot + 20 + i)
        a.xor_r("a")
        a.ldh_n_a(TAC)


def _reload_setup(a):
    # TAC off; TMA=55; TIMA=FF; reset DIV; TAC=06 (64-T period).  With this
    # ordering the overflow tick lands ~11 M-cycles after the setup block,
    # so k sweeps below straddle the 1 M-cycle "TIMA reads 00" window.
    a.xor_r("a")
    a.ldh_n_a(TAC)
    a.ldh_n_a(IF)
    a.ld_r_n("a", 0x55)
    a.ldh_n_a(TMA)
    a.ld_r_n("a", 0xFF)
    a.ldh_n_a(TIMA)
    a.xor_r("a")
    a.ldh_n_a(DIV)
    a.ld_r_n("a", 0x06)
    a.ldh_n_a(TAC)


@test("TIMARELOAD")
def t_timareload(a, slot, p):
    """The TIMA overflow/reload window, byte by byte.

    00-0B  k = 7..18: read TIMA k M-cycles after an aligned overflow run.
           Expect FF FF ... 00 55 55: the position and WIDTH of the 00
           column is the reload delay.
    0C-0F  k = 8..11: write TIMA=AA in the window, read back 4 M later.
           Whether AA survives or the 55 reload wins, per cycle.
    10-13  k = 8..11: write TMA=99 in the window instead — which reload
           value gets used, per cycle.
    14-15  IF at k=9 and k=11 (when exactly does bit 2 set).
    """
    for i, k in enumerate(range(7, 19)):
        _reload_setup(a)
        a.delay(k)
        a.ldh_a_n(TIMA)
        a.ld_nn_a(slot + i)
        a.xor_r("a")
        a.ldh_n_a(TAC)
    for i, k in enumerate(range(8, 12)):
        _reload_setup(a)
        a.delay(k)
        a.ld_r_n("a", 0xAA)
        a.ldh_n_a(TIMA)
        a.delay(4)
        a.ldh_a_n(TIMA)
        a.ld_nn_a(slot + 12 + i)
        a.xor_r("a")
        a.ldh_n_a(TAC)
    for i, k in enumerate(range(8, 12)):
        _reload_setup(a)
        a.delay(k)
        a.ld_r_n("a", 0x99)
        a.ldh_n_a(TMA)
        a.delay(4)
        a.ldh_a_n(TIMA)
        a.ld_nn_a(slot + 16 + i)
        a.xor_r("a")
        a.ldh_n_a(TAC)
    for i, k in enumerate((9, 11)):
        _reload_setup(a)
        a.delay(k)
        a.ldh_a_n(IF)
        a.ld_nn_a(slot + 20 + i)
        a.xor_r("a")
        a.ldh_n_a(TAC)


CNT = SCRATCH + 0x20                   # shared IRQ counter for probes


@test("HALTBUG")
def t_haltbug(a, slot, p):
    """halt / EI-delay corner cases.

    00  IME=0, IE&IF pending, `halt / inc a / inc a` from a=0: 03 = halt
        bug (byte after halt fetched twice), 02 = no bug.
    01  IRQ counter after `ei / nop` with a pending, enabled interrupt
        (EI's one-instruction delay).
    02  IRQ counter after `ei / di` with a pending interrupt — whether the
        delayed enable can dispatch before DI lands.
    03  IRQ counter after `ei / halt` woken by a real timer overflow.
    04  DIV after an IME=0 halt woken by timer overflow (wake latency in
        16384 Hz ticks).
    05  TIMA at the same point.
    """
    # (00) the classic bug
    a.ld_r_n("a", 0x04)
    a.ldh_n_a(IE)
    a.ldh_n_a(IF)
    a.xor_r("a")
    a.halt()
    a.inc_r("a")
    a.inc_r("a")
    a.ld_nn_a(slot + 0)
    a.xor_r("a")
    a.ldh_n_a(IF)
    a.ldh_n_a(IE)
    # (01) ei/nop dispatch
    patch_tramp(a, 8, f"{p}_timer")    # timer vector -> counter handler
    a.xor_r("a")
    a.ld_nn_a(CNT)
    a.ld_r_n("a", 0x04)
    a.ldh_n_a(IE)
    a.ldh_n_a(IF)
    a.ei()
    a.nop()
    a.nop()
    a.di()
    a.ld_a_nn(CNT)
    a.ld_nn_a(slot + 1)
    a.xor_r("a")
    a.ldh_n_a(IF)
    a.ldh_n_a(IE)
    # (02) ei/di
    a.xor_r("a")
    a.ld_nn_a(CNT)
    a.ld_r_n("a", 0x04)
    a.ldh_n_a(IE)
    a.ldh_n_a(IF)
    a.ei()
    a.di()
    a.ld_a_nn(CNT)
    a.ld_nn_a(slot + 2)
    a.xor_r("a")
    a.ldh_n_a(IF)
    a.ldh_n_a(IE)
    # (03) ei/halt with a real overflow wake
    a.xor_r("a")
    a.ld_nn_a(CNT)
    a.ldh_n_a(IF)
    a.ld_r_n("a", 0x04)
    a.ldh_n_a(IE)
    a.ld_r_n("a", 0xF0)
    a.ldh_n_a(TIMA)
    a.ld_r_n("a", 0x05)
    a.ldh_n_a(TAC)
    a.ei()
    a.halt()
    a.di()
    a.xor_r("a")
    a.ldh_n_a(TAC)
    a.ld_a_nn(CNT)
    a.ld_nn_a(slot + 3)
    a.xor_r("a")
    a.ldh_n_a(IF)
    a.ldh_n_a(IE)
    # (04/05) IME=0 halt wake latency
    a.ld_r_n("a", 0x04)
    a.ldh_n_a(IE)
    a.xor_r("a")
    a.ldh_n_a(IF)
    a.ld_r_n("a", 0xF8)
    a.ldh_n_a(TIMA)
    a.ld_r_n("a", 0x07)                # 256-T period: overflow ~512 M later
    a.ldh_n_a(TAC)
    a.xor_r("a")
    a.ldh_n_a(DIV)
    a.halt()
    a.ldh_a_n(DIV)
    a.ld_nn_a(slot + 4)
    a.ldh_a_n(TIMA)
    a.ld_nn_a(slot + 5)
    a.xor_r("a")
    a.ldh_n_a(TAC)
    a.ldh_n_a(IF)
    a.ldh_n_a(IE)
    a.jr(f"{p}_end")
    # timer vector handler: count and return
    a.label(f"{p}_timer")
    a.push("af")
    a.ld_a_nn(CNT)
    a.inc_r("a")
    a.ld_nn_a(CNT)
    a.pop("af")
    a.reti()
    a.label(f"{p}_end")


IEP = SCRATCH + 0x30                   # iepush bookkeeping block
IEP_SP, IEP_IE, IEP_IF = IEP + 0, IEP + 2, IEP + 3
IEP_TCNT, IEP_ZCNT, IEP_FCNT = IEP + 4, IEP + 5, IEP + 6
IEP_RETVEC = IEP + 8                   # jp nnnn written per run
IEP_SAVSP = IEP + 0x0C                 # caller's SP (the probe was call'd)


def _iep_restore_sp(a):
    # SM83 has no `ld sp,(nn)`: bounce through hl.  Restores the SP the
    # probe was entered with, return address still on top.
    a.ld_a_nn(IEP_SAVSP)
    a.ld_r_r("l", "a")
    a.ld_a_nn(IEP_SAVSP + 1)
    a.ld_r_r("h", "a")
    a.ld_sp_hl()


@test("IEPUSH")
def t_iepush(a, slot, p):
    """Interrupt dispatch pushing PC's high byte over IE (SP=0000).

    The dispatch's own push rewrites IE mid-dispatch.  Run 1 triggers from
    address 0x04xx (pushed byte keeps the timer bit): expect a normal
    dispatch.  Run 2 triggers from 0x01xx (pushed byte clears it): mooneye
    says DMG cancels the dispatch and jumps to 0x0000.  What CGB/AGB do,
    and what happens to IF, is exactly what the bytes record.

    00-04  run 1: timer-vector hits, addr-0 hits, fall-throughs, IE, IF
    05-09  run 2: same five
    0A-0B  SP as captured inside the addr-0 handler (lo, hi)
    """
    a.ld_nn_sp(IEP_SAVSP)              # the runner call'd us: keep its SP
    # stubs at the two magic pages
    save_pc = a.pc
    for addr, tag in ((0x160, "lo"), (0x400, "hi")):
        a.org(addr)
        for _ in range(6):
            a.nop()
        a.jp(f"{p}_fall")
    a.org(save_pc)

    patch_tramp(a, 8, f"{p}_timer")
    for run, (stub, base) in enumerate(((0x400, 0), (0x160, 5))):
        a.xor_r("a")
        a.ld_nn_a(IEP_TCNT)
        a.ld_nn_a(IEP_ZCNT)
        a.ld_nn_a(IEP_FCNT)
        # continuation for the handlers: jp cont_<run>
        a.ld_r_n("a", 0xC3)
        a.ld_nn_a(IEP_RETVEC)
        a.ld_r_n("a", 0)
        a.fixups.append((a.pc - 1, "abs8lo", f"{p}_cont{run}"))
        a.ld_nn_a(IEP_RETVEC + 1)
        a.ld_r_n("a", 0)
        a.fixups.append((a.pc - 1, "abs8hi", f"{p}_cont{run}"))
        a.ld_nn_a(IEP_RETVEC + 2)
        a.xor_r("a")
        a.ldh_n_a(IF)
        a.ld_r_n("a", 0x04)
        a.ldh_n_a(IE)
        a.ldh_n_a(IF)
        a.ld_r_n("a", 0x10 + run)
        a.ldh_n_a(B_STAGE)
        a.ld_rr_nn("sp", 0x0000)
        a.ei()
        a.jp(stub)                     # IRQ window opens at the stub
        a.label(f"{p}_cont{run}")
        _iep_restore_sp(a)
        a.di()
        a.ld_r_n("a", 0x20 + run)
        a.ldh_n_a(B_STAGE)
        for i, src in enumerate((IEP_TCNT, IEP_ZCNT, IEP_FCNT, IEP_IE,
                                 IEP_IF)):
            a.ld_a_nn(src)
            a.ld_nn_a(slot + base + i)
    a.ld_a_nn(IEP_SP)
    a.ld_nn_a(slot + 10)
    a.ld_a_nn(IEP_SP + 1)
    a.ld_nn_a(slot + 11)
    a.xor_r("a")
    a.ldh_n_a(IF)
    a.ldh_n_a(IE)
    a.jr(f"{p}_end")

    # cancelled dispatch lands at 0x0000, whose vector jp's here
    a.label("iepush_zero")
    a.ld_nn_sp(IEP_SP)
    _iep_restore_sp(a)
    a.ldh_a_n(IE)
    a.ld_nn_a(IEP_IE)
    a.ldh_a_n(IF)
    a.ld_nn_a(IEP_IF)
    a.ld_a_nn(IEP_ZCNT)
    a.inc_r("a")
    a.ld_nn_a(IEP_ZCNT)
    a.jp(IEP_RETVEC)
    # normal dispatch: timer vector
    a.label(f"{p}_timer")
    _iep_restore_sp(a)
    a.ldh_a_n(IE)
    a.ld_nn_a(IEP_IE)
    a.ldh_a_n(IF)
    a.ld_nn_a(IEP_IF)
    a.ld_a_nn(IEP_TCNT)
    a.inc_r("a")
    a.ld_nn_a(IEP_TCNT)
    a.jp(IEP_RETVEC)
    # neither happened: the stub fell through its nops
    a.label(f"{p}_fall")
    _iep_restore_sp(a)
    a.ld_a_nn(IEP_FCNT)
    a.inc_r("a")
    a.ld_nn_a(IEP_FCNT)
    a.jp(IEP_RETVEC)
    a.label(f"{p}_end")


@test("SERIAL")
def t_serial(a, slot, p):
    """Serial engine vs the DIV chain — an area no bundled suite touches.

    00  poll iterations (10 M each) for an internal-clock transfer to
        finish, no cable (~1024 M on DMG: expect ~66).
    01  SB after it (open link shifts in 1s: FF).
    02  the same with SC=83 (CGB fast clock bit; DMG ignores bit 1 — a
        model split by itself).
    03  poll iterations remaining after DIV is RESET mid-transfer: the
        serial clock taps the DIV chain, so the reset stretches the
        transfer on hardware.
    04  SB read mid-transfer (partially shifted byte).
    05  SC read mid-transfer.
    06  SC after 200 M of external-clock (no cable): transfer never
        completes, bit 7 still set.
    07  SB after cancelling that transfer by writing SC=00.
    """
    def count_done(store_at):
        a.ld_r_n("b", 0)
        a.label(f"{p}_w{store_at}")
        a.ldh_a_n(SC)
        a.rlca()
        a.jr(f"{p}_d{store_at}", "nc")
        a.inc_r("b")
        a.jr(f"{p}_w{store_at}")
        a.label(f"{p}_d{store_at}")
        a.ld_r_r("a", "b")
        a.ld_nn_a(slot + store_at)

    a.ld_r_n("a", 0x5A)
    a.ldh_n_a(SB)
    a.ld_r_n("a", 0x81)
    a.ldh_n_a(SC)
    count_done(0)
    a.ldh_a_n(SB)
    a.ld_nn_a(slot + 1)

    a.ld_r_n("a", 0x5A)
    a.ldh_n_a(SB)
    a.ld_r_n("a", 0x83)
    a.ldh_n_a(SC)
    count_done(2)

    a.xor_r("a")
    a.ldh_n_a(SB)
    a.ld_r_n("a", 0x81)
    a.ldh_n_a(SC)
    a.delay(300)
    a.xor_r("a")
    a.ldh_n_a(DIV)
    count_done(3)

    a.xor_r("a")
    a.ldh_n_a(SB)
    a.ld_r_n("a", 0x81)
    a.ldh_n_a(SC)
    a.delay(500)
    a.ldh_a_n(SB)
    a.ld_nn_a(slot + 4)
    a.ldh_a_n(SC)
    a.ld_nn_a(slot + 5)
    count_done(31)                     # drain; iteration count not scored

    a.ld_r_n("a", 0x5A)
    a.ldh_n_a(SB)
    a.ld_r_n("a", 0x80)
    a.ldh_n_a(SC)
    a.delay(200)
    a.ldh_a_n(SC)
    a.ld_nn_a(slot + 6)
    a.xor_r("a")
    a.ldh_n_a(SC)
    a.ldh_a_n(SB)
    a.ld_nn_a(slot + 7)


def wait_line(a, tag, n):
    """Two-stage LY poll: waits for the START of line n (within the 8 M-cycle
    poll granularity — constant for a given implementation, so comparable)."""
    a.label(f"{tag}_wla")
    a.ldh_a_n(LY)
    a.cp_n((n - 1) & 0xFF)
    a.jr(f"{tag}_wla", "nz")
    a.label(f"{tag}_wlb")
    a.ldh_a_n(LY)
    a.cp_n(n)
    a.jr(f"{tag}_wlb", "nz")


@test("IFVBLANK")
def t_ifvblank(a, slot, p):
    """When exactly IF.0 rises at the line 143->144 boundary.

    00-0B  IF sampled 12x, 20 dots apart, across the boundary (frame after
           the LCD-on frame, so first-frame quirks are out of the way)
    0C-17  the same window sampled at +8 dots (10-dot effective resolution)
    18-1D  LY sampled with the identical alignment, to anchor the window

    Anchored on an LY=143 poll (8 M-cycle granularity, constant for an
    implementation) rather than absolute LCD-on delays, so first-frame
    length quirks cannot move the window.
    """
    def anchored(reg, dest, n, phase):
        wait_line(a, f"{p}_a{reg}_{dest & 0xFF}_{phase}", 143)
        a.xor_r("a")
        a.ldh_n_a(IF)                  # drop the previous vblank flag
        a.ld_rr_nn("hl", 0xFF00 + reg)
        a.ld_rr_nn("de", dest)
        a.delay(50 + phase)            # ~dot 240 of line 143
        for _ in range(n):
            a.ld_r_r("a", "hl")
            a.ld_rr_a("de")
            a.inc_rr("de")

    anchored(IF, slot + 0, 12, 0)
    anchored(IF, slot + 12, 12, 2)
    anchored(LY, slot + 24, 4, 0)
    anchored(STAT, slot + 28, 4, 0)


@test("STATSEQ")
def t_statseq(a, slot, p):
    """STAT mode bits swept across one whole visible line (line 40).

    00-17  24 samples, 20 dots apart, SCX=0: the 2->3 and 3->0 edges land
           in here, and their sample positions are the whole mode-timing
           model in one row, including what a mid-mode STAT read RETURNS.
    18-1F  8 samples straddling the 3->0 edge with SCX=5: the fine-scroll
           mode-3 stretch.
    """
    a.call("lcd_off_safe")
    burst(a, slot, dot_delay(40 * 456 - 20), STAT, 24)
    a.call("lcd_off_safe")
    a.ld_r_n("a", 5)
    a.ldh_n_a(SCX)
    burst(a, slot + 24, dot_delay(40 * 456 + 230), STAT, 8)
    a.xor_r("a")
    a.ldh_n_a(SCX)


@test("LY153")
def t_ly153(a, slot, p):
    """Line 153: LY reads 153 for only a handful of dots, then 0.

    00-17  four 6-sample sweeps of LY across the 152->153->0 boundary, at
           phase offsets 0/1/2/3 M-cycles: together they tile the boundary
           at 4-dot resolution, so the handful of dots LY actually reads
           153 for MUST land in some cell.  How many cells show 153 (and
           where the 0 begins) splits DMG revisions from CGB.
    18-1F  8 STAT samples across the boundary with LYC=153: the LYC
           coincidence flag's rise/fall around the phantom line.
    """
    for ph in range(4):
        a.call("lcd_off_safe")
        burst(a, slot + 6 * ph, dot_delay(153 * 456 - 23) + ph, LY, 6)
    a.call("lcd_off_safe")
    a.ld_r_n("a", 153)
    a.ldh_n_a(LYC)
    burst(a, slot + 24, dot_delay(153 * 456 - 30), STAT, 8)
    a.xor_r("a")
    a.ldh_n_a(LYC)


@test("LCDON")
def t_lcdon(a, slot, p):
    """The infamous first frame after LCDC.7 goes high.

    00-17  24 STAT samples starting immediately after the enabling write:
           hardware starts line 0 in mode 0 (not 2) and skips the first
           OAM scan.
    18-1F  8 LY samples across the first line boundary: is the first line
           full-length?
    """
    a.call("lcd_off_safe")
    burst(a, slot, 2, STAT, 24)
    a.call("lcd_off_safe")
    burst(a, slot + 24, 440 // 4, LY, 8)


@test("STATWBUG")
def t_statwbug(a, slot, p):
    """The DMG STAT-write bug: a STAT write behaves as if $FF were written
    for one cycle, spuriously raising the STAT line (Road Rash / Zerd no
    Densetsu).  CGB is supposed to be immune — per revision?

    Six choreographed writes of STAT=$00 (and one $40), IF.1 polled after
    each (IME off, IE=0: pure IF observation), STAT mode captured too:
    00/01  written during vblank            (bug fires on DMG)
    02/03  during mode 0, line 40           (fires)
    04/05  during mode 3, line 40           (no source matches: silent)
    06/07  during mode 2, line 40           (fires)
    08/09  during vblank with LYC=150 match (fires via the LYC source)
    0A/0B  STAT=$40 written in vblank       (value-independence check)
    """
    cases = [
        (150, 0, 0x00, 0),             # (line, extra delay, value, lyc)
        (40, 85, 0x00, 0),
        (40, 30, 0x00, 0),
        (40, 5, 0x00, 0),
        (150, 0, 0x00, 150),
        (150, 0, 0x40, 0),
    ]
    for i, (line, extra, val, lyc) in enumerate(cases):
        a.ld_r_n("a", lyc)
        a.ldh_n_a(LYC)
        a.xor_r("a")
        a.ldh_n_a(STAT)                # no sources enabled
        wait_line(a, f"{p}_c{i}", line)
        if extra:
            a.delay(extra)
        a.xor_r("a")
        a.ldh_n_a(IF)
        a.ld_r_n("a", val)
        a.ldh_n_a(STAT)
        a.ldh_a_n(IF)
        a.ld_nn_a(slot + 2 * i)
        a.ldh_a_n(STAT)
        a.ld_nn_a(slot + 2 * i + 1)


@test("STATIRQ")
def t_statirq(a, slot, p):
    """STAT interrupt counts per frame under each source combination.

    The STAT line is the OR of the enabled sources and only its RISING edge
    sets IF ("STAT blocking") — so combinations fire fewer times than the
    sum of their parts, and the per-frame counts are a compact fingerprint
    of the whole source model:
    00  mode-0 only    01  mode-1 only      02  mode-2 only
    03  LYC=40 only    04  LYC=40 + mode-0 + mode-2 (blocking-heavy)
    05  mode-1 + mode-2 (the line-144 OAM quirk lives here)
    """
    patch_tramp(a, 4, f"{p}_stat")
    configs = [(0x08, 0), (0x10, 0), (0x20, 0), (0x40, 40), (0x68, 40),
               (0x30, 0)]
    for i, (en, lyc) in enumerate(configs):
        a.ld_r_n("a", lyc)
        a.ldh_n_a(LYC)
        a.ld_r_n("a", en)
        a.ldh_n_a(STAT)
        a.ld_r_n("a", 0x02)
        a.ldh_n_a(IE)
        wait_line(a, f"{p}_s{i}", 120)
        a.xor_r("a")
        a.ld_nn_a(CNT)
        a.ldh_n_a(IF)
        a.ei()
        wait_line(a, f"{p}_e{i}", 120)  # exactly one frame later
        a.di()
        a.ld_a_nn(CNT)
        a.ld_nn_a(slot + i)
        a.xor_r("a")
        a.ldh_n_a(STAT)
        a.ldh_n_a(IE)
        a.ldh_n_a(IF)
    a.jr(f"{p}_end")
    a.label(f"{p}_stat")
    a.push("af")
    a.ld_a_nn(CNT)
    a.inc_r("a")
    a.ld_nn_a(CNT)
    a.pop("af")
    a.reti()
    a.label(f"{p}_end")


HRAM_RT = 0xFF90                       # OAM-DMA-time routine lives here
HRAM_BUF = 0xFFD0                      # its 8-byte result buffer


@test("OAMDMA")
def t_oamdma(a, slot, p):
    """Bus conflicts while OAM DMA runs, for four source buses.

    Per 8-byte group (sources: ROM page 05 / WRAM C0 / VRAM 9C / ECHO E0):
    +0  WRAM $C010 read mid-DMA      +1  VRAM $9C10 read mid-DMA
    +2  ROM $0510 read mid-DMA       +3  OAM $FE10 read mid-DMA
    +4  ECHO $E010 read mid-DMA      +5/6/7  OAM $00/$10/$9F after

    Reads on the bus the DMA source occupies return the in-flight DMA
    byte on DMG; which buses conflict, and what the CGB returns (it has a
    separate WRAM bus), is per-model.  The ECHO-source group doubles as
    "what does DMA from $E000 copy".  Executed from HRAM with no stack use.
    """
    # the HRAM routine, emitted here then copied up.  entry: a = source
    # page, c = HRAM_BUF low byte, hl = return address.
    a.jr(f"{p}_after_rt")
    a.label(f"{p}_rt")
    rt_start = a.pc
    a.ldh_n_a(DMA)                     # DMA starts
    for addr in (0xC010, 0x9C10, 0x0510, 0xFE10, 0xE010):
        a.ld_a_nn(addr)
        a.ldh_c_a()
        a.inc_r("c")
    a.ld_r_n("a", 45)                  # outlast the 160 M transfer
    rt_wait = a.pc
    a.dec_r("a")
    a.jr(rt_wait, "nz")
    for addr in (0xFE00, 0xFE10, 0xFE9F):
        a.ld_a_nn(addr)
        a.ldh_c_a()
        a.inc_r("c")
    a.jp_hl()
    rt_len = a.pc - rt_start
    a.label(f"{p}_after_rt")

    # copy it to HRAM
    a.ld_rr_nn("hl", f"{p}_rt")
    a.ld_r_n("c", HRAM_RT & 0xFF)
    a.ld_r_n("b", rt_len)
    a.label(f"{p}_cp")
    a.ld_a_hli()
    a.ldh_c_a()
    a.inc_r("c")
    a.dec_r("b")
    a.jr(f"{p}_cp", "nz")

    # markers on every bus (VRAM touched in the LCD-off window), and a
    # deterministic WRAM source page: power-on WRAM is silicon noise on
    # real hardware, so everything DMA will copy gets written first
    a.call("lcd_off_safe")
    a.ld_rr_nn("hl", 0xC014)
    a.label(f"{p}_wf")
    a.ld_r_r("a", "l")
    a.xor_n(0x5A)
    a.ld_hli_a()
    a.ld_r_r("a", "l")
    a.cp_n(0xA0)
    a.jr(f"{p}_wf", "nz")
    a.ld_r_n("a", 0x11)
    a.ld_nn_a(0xC010)
    a.ld_r_n("a", 0x22)
    a.ld_nn_a(0x9C10)
    a.ld_r_n("a", 0x91)
    a.ldh_n_a(LCDC)

    for i, src in enumerate((0x05, 0xC0, 0x9C, 0xE0)):
        a.call("wait_vblank")          # whole run fits inside vblank
        a.ld_r_n("c", HRAM_BUF & 0xFF)
        a.ld_rr_nn("hl", f"{p}_back{i}")
        a.ld_r_n("a", src)
        a.jp(HRAM_RT)
        a.label(f"{p}_back{i}")
        for j in range(8):
            a.ld_a_nn(0xFF00 | ((HRAM_BUF + j) & 0xFF))
            a.ld_nn_a(slot + 8 * i + j)


@test("OAMCORRUPT")
def t_oamcorrupt(a, slot, p):
    """The DMG OAM corruption bug (16-bit inc/dec near $FE00 in mode 2).

    Four runs, 8 bytes each: [corrupt-count, first-corrupt-index, OAM at
    first-corrupt-index-rounded-row.. 6 bytes].  Runs 1-3 execute inc hl /
    dec hl / inc de (pointer $FE30) at three offsets inside line 30's OAM
    scan; run 4 is the vblank control (must stay clean).  CGB should show
    all four clean; WHICH rows DMG trashes, and with what values, varies
    by revision.
    """
    runs = [("inc_hl", 6), ("dec_hl", 12), ("inc_de", 18), ("ctl", 0)]
    for i, (kind, extra) in enumerate(runs):
        # repaint OAM with the pattern page (direct writes, LCD off)
        a.call("lcd_off_safe")
        a.ld_rr_nn("hl", 0xFE00)
        a.ld_rr_nn("de", "dma_pattern")
        a.ld_r_n("b", 160)
        a.label(f"{p}_f{i}")
        a.ld_a_rr("de")
        a.inc_rr("de")
        a.ld_hli_a()
        a.dec_r("b")
        a.jr(f"{p}_f{i}", "nz")
        a.ld_r_n("a", 0x91)
        a.ldh_n_a(LCDC)
        if kind == "ctl":
            a.call("wait_vblank")
        else:
            wait_line(a, f"{p}_w{i}", 30)
            a.delay(extra)
        a.ld_rr_nn("hl", 0xFE30)
        a.ld_rr_nn("de", 0xFE30)
        if kind == "inc_hl":
            a.inc_rr("hl")
        elif kind == "dec_hl":
            a.dec_rr("hl")
        elif kind == "inc_de":
            a.inc_rr("de")
        else:
            a.inc_rr("hl")
        # diff OAM against the pattern (LCD off so OAM reads are clean)
        a.call("lcd_off_safe")
        a.ld_rr_nn("hl", 0xFE00)
        a.ld_rr_nn("de", "dma_pattern")
        a.ld_r_n("b", 0)               # count
        a.ld_r_n("c", 0xFF)            # first index
        a.label(f"{p}_d{i}")
        a.ld_a_rr("de")
        a.cp_r("hl")
        a.jr(f"{p}_same{i}", "z")
        a.inc_r("b")
        a.ld_r_r("a", "c")
        a.cp_n(0xFF)
        a.jr(f"{p}_seen{i}", "nz")
        a.ld_r_r("a", "l")             # first corrupt: c = low(addr)
        a.ld_r_r("c", "a")
        a.label(f"{p}_seen{i}")
        a.label(f"{p}_same{i}")
        a.inc_rr("hl")
        a.inc_rr("de")
        a.ld_r_r("a", "l")
        a.cp_n(0xA0)
        a.jr(f"{p}_d{i}", "nz")
        a.ld_r_r("a", "b")
        a.ld_nn_a(slot + 8 * i)
        a.ld_r_r("a", "c")
        a.ld_nn_a(slot + 8 * i + 1)
        # 6 bytes from the first corrupt row (or row 6 if clean)
        a.ld_r_r("a", "c")
        a.cp_n(0xFF)
        a.jr(f"{p}_row{i}", "nz")
        a.ld_r_n("c", 0x30)
        a.label(f"{p}_row{i}")
        a.ld_r_r("a", "c")
        a.and_n(0xF8)                  # round to the 8-byte OAM row
        a.ld_r_r("l", "a")
        a.ld_r_n("h", 0xFE)
        for j in range(6):
            a.ld_a_hli()
            a.ld_nn_a(slot + 8 * i + 2 + j)
        a.ld_r_n("a", 0x91)
        a.ldh_n_a(LCDC)


@test("UNUSED")
def t_unused(a, slot, p):
    """The unmapped corners, which differ per model/revision.

    00-0B  $FEA0/$FEA8/../$FEF8 reads (DMG: 00; CGB: OAM-row echoes that
           changed across CGB revisions; read during vblank)
    0C     $FEA5 after writing $5A to it
    0D-10  $FF03 $FF08 $FF0D $FF15
    11-13  $FF4C $FF6D $FF7F
    14     P1 with BOTH select lines low (write $00)
    15     P1 with NEITHER line low (write $30) — floating-bit behavior
    16     IF after writing $00 (upper 3 bits)
    17     IF after writing $1F
    18     IE after writing $FF (upper bits store?)  [restored to 0 after]
    19     STAT after writing $FF
    1A     TAC after writing $FF
    1B     SC after writing $7E
    1C-1D  DIV read twice back-to-back
    """
    a.call("wait_vblank")
    for i in range(12):
        a.ld_a_nn(0xFEA0 + 8 * i)
        a.ld_nn_a(slot + i)
    a.ld_r_n("a", 0x5A)
    a.ld_nn_a(0xFEA5)
    a.ld_a_nn(0xFEA5)
    a.ld_nn_a(slot + 12)
    for i, r in enumerate((0x03, 0x08, 0x0D, 0x15, 0x4C, 0x6D, 0x7F)):
        a.ldh_a_n(r)
        a.ld_nn_a(slot + 13 + i)
    for i, v in enumerate((0x00, 0x30)):
        a.ld_r_n("a", v)
        a.ldh_n_a(P1)
        for _ in range(4):
            a.ldh_a_n(P1)
        a.ld_nn_a(slot + 20 + i)
    a.ld_r_n("a", 0x30)
    a.ldh_n_a(P1)
    for i, v in enumerate((0x00, 0x1F)):
        a.ld_r_n("a", v)
        a.ldh_n_a(IF)
        a.ldh_a_n(IF)
        a.ld_nn_a(slot + 22 + i)
    a.ld_r_n("a", 0xFF)
    a.ldh_n_a(IE)
    a.ldh_a_n(IE)
    a.ld_nn_a(slot + 24)
    a.xor_r("a")
    a.ldh_n_a(IE)
    a.ldh_n_a(IF)
    a.ld_r_n("a", 0xFF)
    a.ldh_n_a(STAT)
    a.ldh_a_n(STAT)
    a.ld_nn_a(slot + 25)
    a.xor_r("a")
    a.ldh_n_a(STAT)
    a.ld_r_n("a", 0xFF)
    a.ldh_n_a(TAC)
    a.ldh_a_n(TAC)
    a.ld_nn_a(slot + 26)
    a.xor_r("a")
    a.ldh_n_a(TAC)
    a.ld_r_n("a", 0x7E)
    a.ldh_n_a(SC)
    a.ldh_a_n(SC)
    a.ld_nn_a(slot + 27)
    a.xor_r("a")
    a.ldh_n_a(SC)
    a.ldh_a_n(DIV)
    a.ld_nn_a(slot + 28)
    a.ldh_a_n(DIV)
    a.ld_nn_a(slot + 29)


@test("VRAMLOCK")
def t_vramlock(a, slot, p):
    """What locked-region reads RETURN, mode by mode (line 40 alignments).

    Groups of 4 [VRAM $9C05, OAM $FE10, BCPD(color1 lo), STAT-at-the-time]:
    00-03  during mode 2     04-07  during mode 3
    08-0B  during mode 0     0C-0F  during mode 1
    10     VRAM $9C05 in vblank after writing $77 to it during mode 3
    11     OAM $FE10 in vblank after writing $88 during mode 2
    12     BCPD color1-lo in vblank after writing $33 during mode 3
    (locked writes are supposed to be dropped; late-CGB-E famously lands
    palette writes on neighbouring entries instead)
    DMG returns FF for BCPD throughout — the group is a model split AND a
    lock probe at once.
    """
    a.call("lcd_off_safe")
    a.xor_r("a")
    a.ld_nn_a(0x9C05)                  # known-zero lock target
    a.ld_r_n("a", 0x91)
    a.ldh_n_a(LCDC)
    aligns = [(f"{p}_m2", 40, 5), (f"{p}_m3", 40, 30), (f"{p}_m0", 40, 90),
              (f"{p}_m1", 148, 10)]
    for gi, (tag, line, extra) in enumerate(aligns):
        a.ld_r_n("a", 0x82)            # BCPS -> palette 0 color 1 low
        a.ldh_n_a(BCPS)
        wait_line(a, tag, line)
        a.delay(extra)
        a.ld_a_nn(0x9C05)
        a.ld_nn_a(slot + 4 * gi)
        a.ld_a_nn(0xFE10)
        a.ld_nn_a(slot + 4 * gi + 1)
        a.ldh_a_n(BCPD)
        a.ld_nn_a(slot + 4 * gi + 2)
        a.ldh_a_n(STAT)
        a.ld_nn_a(slot + 4 * gi + 3)
    # locked-write probes
    wait_line(a, f"{p}_wv", 40)
    a.delay(30)                        # mode 3
    a.ld_r_n("a", 0x77)
    a.ld_nn_a(0x9C05)
    a.ld_r_n("a", 0x82)
    a.ldh_n_a(BCPS)
    a.ld_r_n("a", 0x33)
    a.ldh_n_a(BCPD)
    wait_line(a, f"{p}_wo", 41)
    a.delay(5)                         # mode 2
    a.ld_r_n("a", 0x88)
    a.ld_nn_a(0xFE10)
    a.call("wait_vblank")
    a.ld_a_nn(0x9C05)
    a.ld_nn_a(slot + 16)
    a.ld_a_nn(0xFE10)
    a.ld_nn_a(slot + 17)
    a.ld_r_n("a", 0x82)
    a.ldh_n_a(BCPS)
    a.ldh_a_n(BCPD)
    a.ld_nn_a(slot + 18)
    # restore palette 0 color 1 in case the $33 landed
    a.ld_r_n("a", 0x82)
    a.ldh_n_a(BCPS)
    a.ld_r_n("a", 0x94)
    a.ldh_n_a(BCPD)
    a.ld_r_n("a", 0x52)
    a.ldh_n_a(BCPD)
    # scrub the VRAM lock target
    a.call("lcd_off_safe")
    a.xor_r("a")
    a.ld_nn_a(0x9C05)
    a.ld_r_n("a", 0x91)
    a.ldh_n_a(LCDC)


def cgb_gate(a, slot, p):
    """Skip the probe (slot byte 31 = EE) on anything that isn't CGB/AGB."""
    a.ld_a_nn(SNAP)
    a.cp_n(0x11)
    a.jr(f"{p}_go", "z")
    a.ld_r_n("a", 0xEE)
    a.ld_nn_a(slot + 31)
    a.ret()
    a.label(f"{p}_go")


@test("HDMA")
def t_hdma(a, slot, p):
    """CGB DMA engines under the clock.  (EE at +1F = not a CGB.)

    00  TIMA ticks (262 kHz) stolen by a 16-block GDMA from ROM
    01  HDMA5 readback right after it (FF = done)
    02-04  HDMA5 after 1/3/5 more scanlines with an 8-block HBLANK DMA
           armed (remaining-count countdown)
    05  HDMA5 right after cancelling a fresh 16-block HBLANK DMA mid-run
    06  did the cancelled channel still copy block 1?  ($9D00 readback)
    07  HDMA5 after arming an HBLANK DMA and sitting through an LCD-off,
        LCD-on cycle — does a paused channel survive, resume, or fire?
    08/09  $9C00/$9C10 after the GDMA (content check: A5/B5)
    """
    cgb_gate(a, slot, p)
    def set_dma(src, dst):
        for reg, val in ((HDMA1, src >> 8), (HDMA2, src & 0xFF),
                         (HDMA3, dst >> 8), (HDMA4, dst & 0xFF)):
            a.ld_r_n("a", val)
            a.ldh_n_a(reg)
    # GDMA, timed
    a.call("wait_vblank")
    set_dma(0x0500, 0x9C00)
    a.ld_r_n("a", 0x05)
    a.ldh_n_a(TAC)
    a.xor_r("a")
    a.ldh_n_a(DIV)
    a.ldh_n_a(TIMA)
    a.ld_r_n("a", 0x0F)                # 16 blocks, general
    a.ldh_n_a(HDMA5)
    a.ldh_a_n(TIMA)
    a.ld_nn_a(slot + 0)
    a.xor_r("a")
    a.ldh_n_a(TAC)
    a.ldh_a_n(HDMA5)
    a.ld_nn_a(slot + 1)
    # HBLANK DMA countdown
    set_dma(0x0500, 0x9C00)
    a.call("wait_vblank")
    a.ld_r_n("a", 0x87)                # 8 blocks, hblank
    a.ldh_n_a(HDMA5)
    for i, line in enumerate((1, 3, 5)):
        wait_line(a, f"{p}_h{i}", line)
        a.delay(100)                   # let this line's block finish
        a.ldh_a_n(HDMA5)
        a.ld_nn_a(slot + 2 + i)
    wait_line(a, f"{p}_dr", 60)        # let the rest drain
    # cancel mid-run
    set_dma(0x0500, 0x9D00)
    a.call("wait_vblank")
    a.ld_r_n("a", 0x8F)
    a.ldh_n_a(HDMA5)
    wait_line(a, f"{p}_cx", 2)
    a.delay(100)
    a.xor_r("a")
    a.ldh_n_a(HDMA5)                   # bit7=0: terminate
    a.ldh_a_n(HDMA5)
    a.ld_nn_a(slot + 5)
    a.call("lcd_off_safe")
    a.ld_a_nn(0x9D00)
    a.ld_nn_a(slot + 6)
    a.ld_r_n("a", 0x91)
    a.ldh_n_a(LCDC)
    # armed across an LCD-off/on cycle
    set_dma(0x0500, 0x9D80)
    a.call("wait_vblank")
    a.ld_r_n("a", 0x81)                # 2 blocks, hblank
    a.ldh_n_a(HDMA5)
    a.call("lcd_off_safe")
    a.delay(2000)
    a.ld_r_n("a", 0x91)
    a.ldh_n_a(LCDC)
    wait_line(a, f"{p}_lo", 20)
    a.ldh_a_n(HDMA5)
    a.ld_nn_a(slot + 7)
    a.xor_r("a")
    a.ldh_n_a(HDMA5)                   # make sure nothing stays armed
    a.call("wait_vblank")              # VRAM readable
    a.ld_a_nn(0x9C00)
    a.ld_nn_a(slot + 8)
    a.ld_a_nn(0x9C10)
    a.ld_nn_a(slot + 9)


@test("PCMPSG")
def t_pcmpsg(a, slot, p):
    """PCM12 ($FF76) as a scope on channel 1, the CGB/AGB-only digital
    readback SameSuite's APU tests use.  (EE at +1F = not CGB/AGB.)

    00-17  24 PCM12 samples, 5 M-cycles apart, right after triggering ch1
           (duty 50%, vol F, period 8 M): trigger-to-first-output latency
           and the duty step positions, at sub-period resolution.
    18-1D  6 PCM12 samples with ch2 also on (both nibbles active).
    1E     NR52 channel-active flags after both triggers.
    """
    cgb_gate(a, slot, p)
    a.ld_r_n("a", 0x80)
    a.ldh_n_a(0x26)                    # NR52 on
    a.ld_r_n("a", 0x11)
    a.ldh_n_a(0x25)                    # NR51: ch1+ch2 both sides
    a.ld_r_n("a", 0x77)
    a.ldh_n_a(0x24)                    # NR50
    a.xor_r("a")
    a.ldh_n_a(0x10)                    # NR10 no sweep
    a.ld_r_n("a", 0x80)
    a.ldh_n_a(0x11)                    # NR11 duty 2 (50%)
    a.ld_r_n("a", 0xF0)
    a.ldh_n_a(0x12)                    # NR12 vol 15
    a.ld_r_n("a", 0xF8)
    a.ldh_n_a(0x13)                    # freq 2040: 8 M per duty step
    a.ld_rr_nn("hl", 0xFF76)
    a.ld_rr_nn("de", slot)
    a.ld_r_n("a", 0x87)
    a.ldh_n_a(0x14)                    # NR14: trigger
    for _ in range(24):
        a.ld_r_r("a", "hl")
        a.ld_rr_a("de")
        a.inc_rr("de")
    # ch2 joins
    a.ld_r_n("a", 0x80)
    a.ldh_n_a(0x16)                    # NR21 duty 2
    a.ld_r_n("a", 0xF0)
    a.ldh_n_a(0x17)
    a.ld_r_n("a", 0xF8)
    a.ldh_n_a(0x18)
    a.ld_rr_nn("hl", 0xFF76)
    a.ld_rr_nn("de", slot + 24)
    a.ld_r_n("a", 0x87)
    a.ldh_n_a(0x19)
    for _ in range(6):
        a.ld_r_r("a", "hl")
        a.ld_rr_a("de")
        a.inc_rr("de")
    a.ldh_a_n(0x26)
    a.ld_nn_a(slot + 30)
    a.xor_r("a")
    a.ldh_n_a(0x26)                    # APU off


def speed_switch(a, tag):
    """KEY1 bit0 + STOP, with the joypad parked the way the switch needs."""
    a.ld_r_n("a", 0x30)
    a.ldh_n_a(P1)
    a.ld_r_n("a", 0x01)
    a.ldh_n_a(KEY1)
    a.stop()


@test("DSTAT")
def t_dstat(a, slot, p):
    """STAT/LY sampling in DOUBLE SPEED, where a CPU M-cycle is 2 dots.

    00-17  24 STAT samples across line 40, now only 10 dots apart: twice
           the resolution on the same mode edges as STATSEQ, and WHERE
           inside a read the mode bits are sampled.
    18-1F  8 LY samples across the line-153 quirk at 10-dot cadence.
    (EE at +1F = not a CGB.)
    """
    cgb_gate(a, slot, p)
    speed_switch(a, f"{p}_in")
    a.call("lcd_off_safe")
    burst(a, slot, (70224 + 40 * 456 - 20) // 2, STAT, 24)
    a.call("lcd_off_safe")
    burst(a, slot + 24, (70224 + 153 * 456 - 30) // 2, LY, 8)
    speed_switch(a, f"{p}_out")


@test("SPEED")
def t_speed(a, slot, p):
    """The speed switch itself.  (EE at +1F = not a CGB.)

    00  KEY1 before          01  KEY1 right after the switch (bit 7 set?)
    02  DIV right after      03  TIMA (TAC=06) right after — how much
        timer time the ~2050-M switch stall consumed, and whether DIV
        survives or resets across STOP
    04  LY right after (the PPU keeps running through the stall?)
    05  DIV read 64 double-speed M-cycles after a reset (rate check: half
        the single-speed reading)
    06  KEY1 after switching back
    07  LY delta across the return switch
    """
    cgb_gate(a, slot, p)
    a.ldh_a_n(KEY1)
    a.ld_nn_a(slot + 0)
    a.ld_r_n("a", 0x06)
    a.ldh_n_a(TAC)
    a.xor_r("a")
    a.ldh_n_a(TIMA)
    a.ldh_n_a(DIV)
    speed_switch(a, f"{p}_in")
    a.ldh_a_n(KEY1)
    a.ld_nn_a(slot + 1)
    a.ldh_a_n(DIV)
    a.ld_nn_a(slot + 2)
    a.ldh_a_n(TIMA)
    a.ld_nn_a(slot + 3)
    a.ldh_a_n(LY)
    a.ld_nn_a(slot + 4)
    a.xor_r("a")
    a.ldh_n_a(TAC)
    a.ldh_n_a(DIV)
    a.delay(64)
    a.ldh_a_n(DIV)
    a.ld_nn_a(slot + 5)
    a.ldh_a_n(LY)
    a.ld_r_r("b", "a")
    speed_switch(a, f"{p}_out")
    a.ldh_a_n(KEY1)
    a.ld_nn_a(slot + 6)
    a.ldh_a_n(LY)
    a.sub_r("b")
    a.ld_nn_a(slot + 7)


@test("M1STAT")
def t_m1stat(a, slot, p):
    """Does the mode-1 STAT source assert at all on entering vblank, and
    how does it overlap the vblank IF bit?  (gambatte's `m1` rows turn on
    exactly this.)

    00-17  four 6-sample sweeps of IF across the line 143->144 boundary at
           phase offsets 0/1/2/3 M-cycles, STAT=$10 (mode-1 source ONLY)
           armed, IE=0.  Each byte carries bit0 (vblank IF) and bit1 (STAT
           IF) together, so their relative rise order is read at 4-dot
           resolution from a single column.
    18-1D  6 samples with STAT=$20 (mode-2 source only): the famous "OAM
           source pulses at line 144" quirk, same boundary.
    1E     IF one sample after entry with STAT=$00 (control: bit1 clear).
    """
    def entry_sweep(stat_en, dest, n, phase, tag):
        a.ld_r_n("a", stat_en)
        a.ldh_n_a(STAT)
        wait_line(a, f"{p}_{tag}", 143)
        a.xor_r("a")
        a.ldh_n_a(IF)
        a.ld_rr_nn("hl", 0xFF00 + IF)
        a.ld_rr_nn("de", dest)
        a.delay(78 + phase)            # samples span ~dot 370..490 of 143
        for _ in range(n):
            a.ld_r_r("a", "hl")
            a.ld_rr_a("de")
            a.inc_rr("de")
        a.xor_r("a")
        a.ldh_n_a(STAT)

    for ph in range(4):
        entry_sweep(0x10, slot + 6 * ph, 6, ph, f"m1p{ph}")
    entry_sweep(0x20, slot + 24, 6, 0, "m2q")
    entry_sweep(0x00, slot + 30, 1, 40, "ctl")


@test("HALTPHASE")
def t_haltphase(a, slot, p):
    """GBMicrotest (TIMA oracle) and mooneye (LY oracle) disagree about
    where a halt-woken handler stands relative to the mode-0 edge on the
    same device at the same SCX; this page runs BOTH shapes with BOTH
    oracles.

    Layout per SCX in {0, 3} (16 bytes each, at +00 / +10):
    +0..3   halt arm: TIMA at STAT-mode-0 handler entry, with the TIMA
            grid phase-swept 0..3 M-cycles (recovers 1 M-cycle resolution
            from the 4 M-cycle counter)
    +4      halt arm: LY at handler entry (phase 0)
    +5..8   sled arm: IF read at a fixed aligned point, delay swept
            0..3 M-cycles (where the IF bit rises, no halt involved)
    +9..12  sled arm: TIMA at those same four points
    +13     sled arm: LY at the phase-0 point
    """
    patch_tramp(a, 4, f"{p}_stat")     # stat vector -> recording handler
    for si, scx in enumerate((0, 3)):
        base = slot + 16 * si
        # ── halt arm ────────────────────────────────────────────────────
        for ph in range(4):
            a.ld_r_n("a", scx)
            a.ldh_n_a(SCX)
            a.ld_r_n("a", 0x08)        # mode-0 source
            a.ldh_n_a(STAT)
            a.ld_r_n("a", 0x02)
            a.ldh_n_a(IE)
            wait_line(a, f"{p}_h{si}_{ph}", 40)
            a.delay(ph)                # shifts the TIMA grid, not the halt
            a.xor_r("a")
            a.ldh_n_a(DIV)
            a.ldh_n_a(TIMA)
            a.ld_r_n("a", 0x05)        # 16-dot period timestamp counter
            a.ldh_n_a(TAC)
            a.xor_r("a")
            a.ldh_n_a(IF)
            a.ei()
            a.halt()                   # mode 0 of line 40 wakes+dispatches
            a.di()
            a.xor_r("a")
            a.ldh_n_a(TAC)
            a.ldh_n_a(IE)
            a.ldh_n_a(STAT)
            a.ld_a_nn(SCRATCH + 0x28)  # handler's TIMA
            a.ld_nn_a(base + ph)
            if ph == 0:
                a.ld_a_nn(SCRATCH + 0x29)
                a.ld_nn_a(base + 4)
        # ── sled arm (no halt, no IRQ: IME off, poll-free timed reads) ──
        for ph in range(4):
            a.ld_r_n("a", scx)
            a.ldh_n_a(SCX)
            a.ld_r_n("a", 0x08)
            a.ldh_n_a(STAT)
            wait_line(a, f"{p}_s{si}_{ph}", 40)
            a.xor_r("a")
            a.ldh_n_a(DIV)
            a.ldh_n_a(TIMA)
            a.ld_r_n("a", 0x05)
            a.ldh_n_a(TAC)
            a.xor_r("a")
            a.ldh_n_a(IF)
            a.delay(30 + 3 * ph)       # 4 points straddling the 3->0 edge
            a.ldh_a_n(IF)
            a.ld_nn_a(base + 5 + ph)
            a.ldh_a_n(TIMA)
            a.ld_nn_a(base + 9 + ph)
            if ph == 0:
                a.ldh_a_n(LY)
                a.ld_nn_a(base + 13)
            a.xor_r("a")
            a.ldh_n_a(TAC)
            a.ldh_n_a(STAT)
    a.xor_r("a")
    a.ldh_n_a(SCX)
    a.jr(f"{p}_end")
    a.label(f"{p}_stat")
    a.push("af")
    a.ldh_a_n(TIMA)
    a.ld_nn_a(SCRATCH + 0x28)
    a.ldh_a_n(LY)
    a.ld_nn_a(SCRATCH + 0x29)
    a.pop("af")
    a.reti()
    a.label(f"{p}_end")


@test("WYLATCH")
def t_wylatch(a, slot, p):
    """The WY sample point per device: gambatte's late_wy families expect
    the CGB to sample WY SOONER than the DMG, the opposite direction of
    every other CGB write latency.

    Oracle: the window starting on a line stretches that line's mode 3, so
    the mode-0 STAT IRQ arrives measurably later.  Sweep WHEN WY is written
    across the line-39/40 boundary and timestamp line 40's mode-0 edge:
    the k where the timestamp jumps is the WY sample point, at ~3 M-cycle
    granularity.  Photograph on DMG and CGB — the flip-k delta between the
    two IS the late_wy device split.

    00-17  TIMA timestamp of line 40's mode-0 IRQ: WY=40 written at
           k=0..5 (x3 M-cycles) into line 39, at TIMA grid phases
           +0/+1/+2/+3 M-cycles (grouped [ph][k], 6 per phase).  The grid
           zeroes at a FIXED dot early in line 40 (computed delay, not a
           second LY poll, so the k sweep cannot smear it), and four
           grids 4 dots apart mean even a stretch smaller than one
           16-dot tick must flip at least one of them.
    18-1B  oracle validation at phases 0..3: WY=40 armed BEFORE the
           frame — must sit above the control by the window-start
           stretch, or the oracle itself is too coarse
    1C-1F  control at phases 0..3: WY stays 200 (window never hits)
    """
    patch_tramp(a, 4, f"{p}_stat")
    runs = []
    for ph in range(4):
        runs.append((40, slot + 6 * ph, ph, False, 6))
    runs.append((40, slot + 24, None, True, 4))    # ph = k for these two
    runs.append((200, slot + 28, None, False, 4))
    for run, (wy_val, dest, phase, early, nk) in enumerate(runs):
        for k in range(nk):
            ph = phase if phase is not None else k
            a.call("lcd_off_safe")
            a.ld_r_n("a", 40 if early else 200)   # early: window armed now
            a.ldh_n_a(WY)
            a.ld_r_n("a", 80)
            a.ldh_n_a(WX)
            a.ld_r_n("a", 0xB1)        # LCD + BG + WINDOW enable
            a.ldh_n_a(LCDC)
            wait_line(a, f"{p}_r{run}k{k}", 39)
            a.delay(3 * k)
            a.ld_r_n("a", wy_val)      # the swept WY write, in line 39
            a.ldh_n_a(WY)
            # exact remainder to a fixed dot early in line 40: everything
            # from the poll exit to the DIV reset totals 112 M-cycles + ph
            # regardless of k (wy write block is 5 M)
            a.delay(107 - 3 * k + ph)
            a.xor_r("a")
            a.ldh_n_a(DIV)
            a.ldh_n_a(TIMA)
            a.ld_r_n("a", 0x05)
            a.ldh_n_a(TAC)
            a.ld_r_n("a", 0x08)        # arm mode-0 IRQ: line 40's own edge
            a.ldh_n_a(STAT)
            a.xor_r("a")
            a.ldh_n_a(IF)
            a.ld_r_n("a", 0x02)
            a.ldh_n_a(IE)
            a.ei()
            a.halt()
            a.di()
            a.ld_a_nn(SCRATCH + 0x28)
            a.ld_nn_a(dest + k)
            a.xor_r("a")
            a.ldh_n_a(TAC)
            a.ldh_n_a(IE)
            a.ldh_n_a(STAT)
    a.ld_r_n("a", 200)
    a.ldh_n_a(WY)
    a.ld_r_n("a", 0x91)                # window back off
    a.ldh_n_a(LCDC)
    a.jr(f"{p}_end")
    a.label(f"{p}_stat")
    a.push("af")
    a.ldh_a_n(TIMA)
    a.ld_nn_a(SCRATCH + 0x28)
    a.ldh_a_n(LY)
    a.ld_nn_a(SCRATCH + 0x29)
    a.pop("af")
    a.reti()
    a.label(f"{p}_end")


@test("CGBWRAM")
def t_cgbwram(a, slot, p):
    """Does the $D000 window really bank, and does any SVBK value alias it
    onto bank 0 ($C000 window)?  (Decides gambatte's oamdma rows that read
    $D000-window WRAM.)

    Straight-line code only — the stack lives in the $D000 window, so no
    call/push may execute while SVBK is switched.  Marker cell $D500 was
    chosen so that IF $D000 aliases $C000, the writes land in unused
    $C500 (sentinel-checked), never in this ROM's own state.

    00-07  read $D500 under SVBK=0..7 after writing B0+b to each bank
           (hardware: 00 -> B1, else B0+b; an alias shows as repeats)
    08     SVBK readback after writing 7 (upper-bit mask)
    09     the $C500 sentinel afterwards (5C = no alias hit bank 0)
    0A     SVBK=2, write 77 to $D500: $C500 read under the same SVBK
           (77 here = $D000 aliases $C000)
    0B     back on SVBK=1: $D500 (B1 = bank 2 write stayed in bank 2)
    0C     boot SVBK value (as this probe found it)
    0D     $D500 read on a DMG-class machine ends up B7 here (control)
    """
    a.ldh_a_n(SVBK)
    a.ld_nn_a(slot + 12)
    a.ld_r_r("c", "a")                 # c = boot SVBK, restored at the end
    a.ld_r_n("a", 0x5C)
    a.ld_nn_a(0xC500)                  # bank-0-window sentinel
    for b in range(8):
        a.ld_r_n("a", b)
        a.ldh_n_a(SVBK)
        a.ld_r_n("a", 0xB0 + b)
        a.ld_nn_a(0xD500)
    for b in range(8):
        a.ld_r_n("a", b)
        a.ldh_n_a(SVBK)
        a.ld_a_nn(0xD500)
        a.ld_nn_a(slot + b)
    a.ld_r_n("a", 7)
    a.ldh_n_a(SVBK)
    a.ldh_a_n(SVBK)
    a.ld_nn_a(slot + 8)
    a.ld_a_nn(0xC500)
    a.ld_nn_a(slot + 9)
    a.ld_r_n("a", 2)                   # ── the bucket-16 configuration ──
    a.ldh_n_a(SVBK)
    a.ld_r_n("a", 0x77)
    a.ld_nn_a(0xD500)
    a.ld_a_nn(0xC500)
    a.ld_nn_a(slot + 10)
    a.ld_r_n("a", 1)
    a.ldh_n_a(SVBK)
    a.ld_a_nn(0xD500)
    a.ld_nn_a(slot + 11)
    a.ld_a_nn(0xD500)
    a.ld_nn_a(slot + 13)
    a.ld_r_r("a", "c")                 # restore the boot bank before any
    a.ldh_n_a(SVBK)                    # stack use can happen again


@test("DIVTAPS")
def t_divtaps(a, slot, p):
    """The mechanism page: DIV, the timer, the serial clock and the APU
    frame sequencer are all supposed to be TAPS off one 16-bit counter.
    If that is true, sweeping the counter phase must shift every
    subsystem's event times by exactly the swept amount, and the tap bit
    indices fall out of the staircase periods.  Any subsystem that does
    NOT follow the sweep is not a tap.

    00-07  serial: poll-iterations until an internal-clock transfer
           completes, started 8*k M-cycles (k=0..7) after a DIV reset —
           the staircase period/phase IS the serial tap bit
    08-17  APU length: 16-bit poll count until a length-63 ch1 expires,
           triggered 2048*k M-cycles (k=0..7) after a DIV reset (lo,hi
           per k) — the staircase reveals the frame-sequencer tap and
           whether the DIV write itself clocks it (falling edge)
    18     NR52 right after the last trigger (ch1 active flag sanity)
    """
    for k in range(8):
        a.xor_r("a")
        a.ldh_n_a(SB)
        a.ldh_n_a(DIV)
        a.delay(8 * k)
        a.ld_r_n("a", 0x81)
        a.ldh_n_a(SC)
        a.ld_r_n("b", 0)
        a.label(f"{p}_sw{k}")
        a.ldh_a_n(SC)
        a.rlca()
        a.jr(f"{p}_sd{k}", "nc")
        a.inc_r("b")
        a.jr(f"{p}_sw{k}")
        a.label(f"{p}_sd{k}")
        a.ld_r_r("a", "b")
        a.ld_nn_a(slot + k)
    # APU length staircase
    a.ld_r_n("a", 0x80)
    a.ldh_n_a(0x26)                    # NR52 on
    a.ld_r_n("a", 0x11)
    a.ldh_n_a(0x25)
    a.ld_r_n("a", 0x77)
    a.ldh_n_a(0x24)
    for k in range(8):
        a.ld_r_n("a", 0xBF)            # duty 2, length 63
        a.ldh_n_a(0x11)
        a.ld_r_n("a", 0xF0)
        a.ldh_n_a(0x12)
        a.xor_r("a")
        a.ldh_n_a(0x13)
        a.ldh_n_a(DIV)                 # phase anchor
        a.delay(2048 * k)
        a.ld_r_n("a", 0xC4)            # trigger + length enable
        a.ldh_n_a(0x14)
        a.ld_rr_nn("bc", 0)
        a.label(f"{p}_aw{k}")
        a.ldh_a_n(0x26)
        a.and_n(0x01)
        a.jr(f"{p}_ad{k}", "z")
        a.inc_rr("bc")
        a.ld_r_r("a", "b")
        a.cp_n(0x20)                   # cap ~8k iterations
        a.jr(f"{p}_aw{k}", "c")
        a.label(f"{p}_ad{k}")
        a.ld_r_r("a", "c")
        a.ld_nn_a(slot + 8 + 2 * k)
        a.ld_r_r("a", "b")
        a.ld_nn_a(slot + 9 + 2 * k)
    a.ldh_a_n(0x26)
    a.ld_nn_a(slot + 24)
    a.xor_r("a")
    a.ldh_n_a(0x26)                    # APU off


@test("SWEEP")
def t_sweep(a, slot, p):
    """The ch1 sweep unit's TRIGGER checks: does CGB run the AGB second one?

    AGB silicon (AGS-001, gbaedge SWEEPQ/SWEEP2) runs the trigger's overflow
    check twice: the familiar shadow + (shadow >> s), then the LINEAR
    shadow + 2*(shadow >> s), which kills strictly above $800.  blargg's
    dmg_sound/cgb_sound 04-06 CRCs say GB silicon does NOT; this page
    re-anchors the raw values at the AGB anchor frequencies.  All rows:
    ch1, increment, vol F, duty 2, no length; the page cycles the APU OFF
    then ON (resetting the frame-sequencer step) and a DIV reset just
    before each trigger anchors the tap phase, so the counts do not depend
    on which page ran before.  Each row stores the 16-bit
    count (lo,hi) of NR52-bit0 polls (15 M-cycles each) until the channel
    died, capped at $2000.  Sweep period 2 => one sweep tick is <= 2/128 s,
    so "~1 tick" is roughly $400-$500 polls.
    00-01  freq 1300 ($514) shift 1: calc1 1950 passes; AGB's second check
           1300+2*650=2600 kills AT TRIGGER.  0 polls = CGB runs the AGB
           second check; ~1 tick = single check (tick recalc 2925 kills),
           the blargg-derived expectation
    02-03  freq 940 ($3AC) shift 1: linear second = 1880 survives, but a
           RECALCULATED second (1410+705=2115) kills at trigger.  0 polls =
           recalculated second check; ~1 tick = linear-or-none (tick recalc
           2115 kills), which both AGB and the single-check model predict
    04-05  freq 1024 ($400) shift 1: second = exactly 2048.  0 polls = a
           NON-strict (>=2048) second check; ~1 tick under both AGB's
           strict check and the single-check model (tick recalc 2304)
    06-07  freq 1000 ($3E8) shift 1: survives every trigger model (1500,
           2000); dies at tick 1 (recalc 2250) — poll-rate calibration row
    08-09  freq 1000 shift 1, sweep DIVIDER 0: the divider never ticks, so
           the channel never dies — every model predicts the $2000 cap
    0A     NR52 after the last row (ch1 bit still set = cap was real)
    """
    a.xor_r("a")
    a.ldh_n_a(0x26)                    # APU off: clears the sequencer step
    a.ld_r_n("a", 0x80)
    a.ldh_n_a(0x26)                    # NR52 on
    a.ld_r_n("a", 0x11)
    a.ldh_n_a(0x25)                    # NR51: ch1 both sides
    a.ld_r_n("a", 0x77)
    a.ldh_n_a(0x24)                    # NR50
    for k, (nr10, freq) in enumerate(
            ((0x21, 1300), (0x21, 940), (0x21, 1024), (0x21, 1000),
             (0x01, 1000))):
        a.ld_r_n("a", nr10)
        a.ldh_n_a(0x10)                # NR10: add, shift 1, period 2 (or 0)
        a.ld_r_n("a", 0x80)
        a.ldh_n_a(0x11)                # NR11 duty 2, length 0
        a.ld_r_n("a", 0xF0)
        a.ldh_n_a(0x12)                # NR12 vol 15, no envelope
        a.ld_r_n("a", freq & 0xFF)
        a.ldh_n_a(0x13)
        a.xor_r("a")
        a.ldh_n_a(DIV)                 # phase anchor
        a.ld_r_n("a", 0x80 | (freq >> 8))
        a.ldh_n_a(0x14)                # trigger, length disabled
        a.ld_rr_nn("bc", 0)
        a.label(f"{p}_sw{k}")
        a.ldh_a_n(0x26)
        a.and_n(0x01)
        a.jr(f"{p}_sd{k}", "z")
        a.inc_rr("bc")
        a.ld_r_r("a", "b")
        a.cp_n(0x20)                   # cap $2000 iterations (~7 ticks)
        a.jr(f"{p}_sw{k}", "c")
        a.label(f"{p}_sd{k}")
        a.ld_r_r("a", "c")
        a.ld_nn_a(slot + 2 * k)
        a.ld_r_r("a", "b")
        a.ld_nn_a(slot + 2 * k + 1)
    a.ldh_a_n(0x26)
    a.ld_nn_a(slot + 10)
    a.xor_r("a")
    a.ldh_n_a(0x26)                    # APU off


# ═══════════════════════════════════════════════════════════════════════════
# APU probe helpers (the 2026-09 pages)
# ═══════════════════════════════════════════════════════════════════════════
# Every page below is built out of the same four moves, so that the whole
# history of a row is the M-cycle count this file writes down and nothing
# else.  The value of these probes is entirely in those counts.
#
#   apu_power_cycle  NR52 $00 -> $80.  Zeroes NR10-NR51, parks every
#                    frequency timer, resets both squares' duty position and
#                    CH3's wave pointer to 0, restarts the APU's 1 MHz tick
#                    grid and sets the frame-sequencer stage to 0.  Wave RAM
#                    survives it.
#   div_anchor       `xor a / ldh (DIV),a`.  CYCLE 0 of every count on these
#                    pages is the M-cycle that write lands on: the internal
#                    divider restarts there, so the DIV-APU tap (internal bit
#                    12, 8192 T) falls 2048 M later and every 2048 M after.
#                    With the sequencer stage zeroed just before, the events
#                    are: #1 at 2048 = stage 0, #2 at 4096 = stage 1, ...
#                      length  stages 0/2/4/6 = events 1,3,5,7 = 2048 M then
#                              every 4096 M
#                      sweep   stages 2/6     = events 3,7,11 = 6144 M then
#                              every 8192 M
#                      envelope stage 7       = event 8       = 16384 M then
#                              every 16384 M
#   wait_reg_w       delay, then `ld a,n / ldh (r),a` so the bus WRITE lands
#                    on a named cycle (the write is the 3rd M-cycle of the
#                    ldh, i.e. the 5th of the pair).
#   wait_pcm         delay, then `ldh a,($76/$77)` so the bus READ lands on a
#                    named cycle (the read is the 3rd M-cycle of the ldh).
#
# A write and a read named for the same cycle are the same M-cycle of the
# bus; where a probe sweeps k it is sweeping that cycle by one M at a time.


def reg_w(a, reg, val):
    """`ld a,val / ldh (reg),a`: 5 M-cycles, the bus write on the 5th."""
    a.ld_r_n("a", val)
    a.ldh_n_a(reg)
    return 5


def apu_off(a):
    a.xor_r("a")
    a.ldh_n_a(0x26)


def div_anchor(a):
    """`xor a / ldh (DIV),a`.  The divider reset is the 4th M-cycle and is
    cycle 0 of the counts in the probes below."""
    a.xor_r("a")
    a.ldh_n_a(DIV)


def wait_reg_w(a, m, target, reg, val):
    """Delay, then write `val` to FF00+reg so the write lands on `target`
    M-cycles after the div_anchor.  Returns the new cycle count."""
    d = target - m - 5
    assert d >= 0, f"wait_reg_w underflow {d} (m={m} target={target})"
    a.delay(d)
    a.ld_r_n("a", val)
    a.ldh_n_a(reg)
    return target


def wait_pcm(a, m, target, dest, reg=0x76):
    """Delay, then read FF00+reg so the READ lands on cycle `target`, and
    store it at `dest`.  Returns the cycle count after the store."""
    d = target - m - 3
    assert d >= 0, f"wait_pcm underflow {d} (m={m} target={target})"
    a.delay(d)
    a.ldh_a_n(reg)
    a.ld_nn_a(dest)
    return target + 4


def pcm_or8(a, m, target, dest, reg=0x76):
    """Delay, then OR eight PCM reads 5 M-cycles apart, the first landing on
    `target`, and store the OR at `dest`.  With one square running at an 8 M
    duty-step period the eight reads span five duty periods, so the OR is
    that channel's VOLUME whatever the duty phase — the amplitude readout
    the envelope pages want, independent of where the waveform sits."""
    d = target - m - 5                 # ld c,0 (2) + the ldh's 3rd M (3)
    assert d >= 0, f"pcm_or8 underflow {d}"
    a.delay(d)
    a.ld_r_n("c", 0)
    for _ in range(8):
        a.ldh_a_n(reg)                 # 3
        a.or_r("c")                    # 1
        a.ld_r_r("c", "a")             # 1
    a.ld_r_r("a", "c")
    a.ld_nn_a(dest)
    return target + 40


def poll_nr52_16(a, tag, dest, cap_hi=0x20):
    """Poll NR52 bit 0 every 15 M-cycles until it clears; store the 16-bit
    count (lo, hi) at dest.  Capped at cap_hi*256 polls; the first read is 6
    M-cycles after the row's last write."""
    a.ld_rr_nn("bc", 0)                # 3
    a.label(f"{tag}_p")
    a.ldh_a_n(0x26)                    # 3
    a.and_n(0x01)                      # 2
    a.jr(f"{tag}_d", "z")              # 2 not taken
    a.inc_rr("bc")                     # 2
    a.ld_r_r("a", "b")                 # 1
    a.cp_n(cap_hi)                     # 2
    a.jr(f"{tag}_p", "c")              # 3 taken  => 15 M per poll
    a.label(f"{tag}_d")
    a.ld_r_r("a", "c")
    a.ld_nn_a(dest)
    a.ld_r_r("a", "b")
    a.ld_nn_a(dest + 1)


NR52_UNIT_INNER = 75
NR52_UNIT_M = 17 + 4 * NR52_UNIT_INNER      # 317 M-cycles per poll


def poll_nr52_coarse(a, tag, dest, cap=0xFF):
    """Poll NR52 bit 0 every NR52_UNIT_M (317) M-cycles until it clears;
    store the count as one saturating byte at dest.  $00 = the channel was
    already off on the first poll (6 M-cycles after the row's last write),
    `cap` = it was still on cap*317 M-cycles later.  One byte per row buys
    the rows these sweeps need; 317 M is ~1/26 of a sweep step, which is the
    resolution the sweep pages actually use.  `cap` is per row and is also
    the row's cost: a row that never dies takes cap*317 M-cycles of boot
    time, so pages that only need "did it die at all" pass a small one."""
    a.ld_r_n("b", 0)                   # 2
    a.label(f"{tag}_p")
    a.ldh_a_n(0x26)                    # 3
    a.and_n(0x01)                      # 2
    a.jr(f"{tag}_d", "z")              # 2 not taken
    a.inc_r("b")                       # 1
    a.ld_r_r("a", "b")                 # 1
    a.cp_n(cap)                        # 2
    a.jr(f"{tag}_d", "z")              # 2 not taken
    a.ld_r_n("c", NR52_UNIT_INNER)     # 2
    a.label(f"{tag}_i")
    a.dec_r("c")                       # 1
    a.jr(f"{tag}_i", "nz")             # 3 taken, 2 on the last  => 4*n - 1
    a.jr(f"{tag}_p")                   # 3
    a.label(f"{tag}_d")
    a.ld_r_r("a", "b")
    a.ld_nn_a(dest)


@test("CH2PHASE")
def t_ch2phase(a, slot, p):
    """Channel 2's trigger phase: the channel-1 PCMPSG measurement mirrored.

    `ch2_pcm_edge_zero` and `ch2_reload_is_now` (apu/channel2.nim) are
    channel 1's constants copied across with "no channel_2 build of the ROM
    measures it. Assumed" — this page is that build.  PCM12 ($FF76) carries
    CH1 in the low nibble and CH2 in the high one, and a power cycle leaves
    CH1's DAC off, so every byte reads x0 and x IS channel 2's output.
    (EE at +1F = not CGB/AGB: no PCM readback.)

    Each row is its own run, from its own APU power cycle (duty position
    back to 0): NR21 duty 2, NR22 volume $F with no envelope, NR23 = $F8
    (freq 2040 => one duty step every 8 M-cycles), then the NR24 trigger.

    00-0F  k = 0..15: PCM12 read k+3 M-cycles after the trigger write, the
           channel starting from OFF.  Duty 3 is low only on the position a
           power cycle leaves behind, so the FIRST duty step is the first
           non-zero byte and its k is gb_trigger_deadline's "2 extra ticks"
           start-up delay at 1 M resolution.  dingbat: 00 x8 then F0 x8, so
           the step lands 11 M-cycles after the write — 8 M of period, 2
           ticks of start-up and 1 M for the write to reach the APU's 1 MHz
           grid (gb_apu_edge).  A byte reading 00 where both neighbours
           read F0 is the CGB 0/A/B/C PCM read glitch on the channel-2 side
           — GbQuirks.pcm_read_edge_zero via ch2_pcm_edge_zero, which is
           off from CGB D: photograph this page on a CGB-C and a CGB-E.
    10-1D  k = 0..13, but a SECOND NR24 trigger is written 68 M-cycles
           after the first (leaving the duty position on the step before
           the high run) and k counts from that one: a restart of a running
           channel, which gb_trigger_deadline gives 1 extra tick instead of
           2, and across which the duty position and the latched sample are
           supposed to carry.  dingbat: 00 x7 then F0 x7 — one M-cycle
           earlier than 00-0F, and that difference of exactly 1 between the
           two rows' edges IS the extra tick.
    1E     NR52 after the last row ($x2 = channel 2 still on)
    """
    cgb_gate(a, slot, p)
    for k in range(16):
        apu_off(a)
        reg_w(a, 0x26, 0x80)           # APU on
        reg_w(a, 0x25, 0xFF)           # NR51 everything, both sides
        reg_w(a, 0x24, 0x77)           # NR50 max, no VIN
        reg_w(a, 0x16, 0xC0)           # NR21 duty 3 (75%), length 0
        reg_w(a, 0x17, 0xF0)           # NR22 volume $F, envelope off
        reg_w(a, 0x18, 0xF8)           # NR23 freq $7F8 -> 8 M per duty step
        reg_w(a, 0x19, 0x87)           # NR24 trigger, length disabled
        a.delay(k)                     # the read lands at trigger + k + 3
        a.ldh_a_n(0x76)
        a.ld_nn_a(slot + k)
    for k in range(14):
        apu_off(a)
        reg_w(a, 0x26, 0x80)
        reg_w(a, 0x25, 0xFF)
        reg_w(a, 0x24, 0x77)
        reg_w(a, 0x16, 0xC0)
        reg_w(a, 0x17, 0xF0)
        reg_w(a, 0x18, 0xF8)
        reg_w(a, 0x19, 0x87)           # first trigger
        a.delay(63)                    # + 5 M of the write below = 68 M
        reg_w(a, 0x19, 0x87)           # restart, 68 M after the first
        a.delay(k)
        a.ldh_a_n(0x76)
        a.ld_nn_a(slot + 0x10 + k)
    a.ldh_a_n(0x26)
    a.ld_nn_a(slot + 0x1E)
    apu_off(a)


@test("SWPPHASE")
def t_swpphase(a, slot, p):
    """The two sweep phases channel1.nim marks "Assumed; no ROM pins this",
    and with them the sweep-delay split of hwprobe row 14.

    dingbat splits the 8 M-cycles SameSuite channel_1_sweep* measures into
    GB_SWEEP_SHADOW_DELAY (2 M, trigger -> shadow loaded),
    GB_SWEEP_CHECK_DELAY (7 M, writeback -> the second overflow check) and
    GB_SWEEP_STOP_DELAY (1 M, check -> the stop visible in NR52), and states
    at channel1.nim:242 that a pending stop does NOT survive a restart
    ("only reachable when the trigger lands on the calculation's cycle").
    Rows 00-0E land a restart on each of the 15 M-cycles that window spans.

    Every row: APU power cycle, DIV anchor (cycle 0), NR10 = $11 (pace 1,
    increment, shift 1), duty 2, volume $F, freq 1024 ($400), triggered on
    cycle 40 — well before the first sweep step.  The trigger's own check
    calculates 1024 + 512 = 1536 and passes.  The sweep step on cycle 6144
    calculates 1536, writes it back, and its trailing check calculates
    1536 + 768 = 2304 > $7FF: THAT is what stops the channel, ~8 M later.
    The restart is NR13 = $00 followed 5 M later by NR14 = $80, so the
    restarted channel's frequency — and therefore its sweep shadow — is 0
    however that pair straddles the writeback (1536 = $600 also has a zero
    low byte, so the writeback cannot smuggle a non-zero frequency in).  A
    shadow of 0 calculates 0 forever, so nothing the restarted channel does
    can ever stop it again: whether it is alive afterwards is exactly
    whether the pending stop survived the restart.

    00-0E  k = 0..14: the restart's NR14 write lands on cycle 6139+k, i.e.
           5 M before the sweep calculation through 9 M after it (past the
           trailing check at 6151 and the stop at 6152).  Byte = poll count
           in units of 317 M-cycles until NR52 bit 0 clears, from 6 M after
           the restart, capped at 8 (a restart row only has to answer "did
           it die at all"): 08 = still on 2536 M later, 00/01 = it died.
           dingbat predicts 08 in all 15 — a restart before the check
           re-arms the check with the zero shadow, a restart between the
           check and the stop clears the pending stop, and one after the
           stop re-enables the dead channel.  Any byte below the cap on
           hardware is a stop that a trigger could not cancel, and its k is
           the cycle the stop becomes irrevocable.
    0F     the same row with NO restart, polled from cycle 45 with a cap of
           40: the control that says the sweep really does stop this
           channel.  dingbat: $14 (20 polls ~ cycle 6152).
    10-1E  j = 0..14 (CGB/AGB only): where the duty step sits across a sweep
           writeback.  NR10 = $1F (pace 1, DECREMENT, shift 7) and freq
           $7FE, so the duty step period is 2 M-cycles until the sweep step
           on cycle 6144 writes back $7EF and stretches it to 17 M — the
           waveform visibly freezes.  Byte = PCM12 read on cycle 6140+j (1
           M-cycle apart, so this is the waveform itself at CPU
           resolution).  The last 2 M edge before the freeze pins the cycle
           the new period takes effect on: the `reload_now` race in
           sweep_step (channel1.nim ~147), which is the race
           channel1.nim:212 assumes for a frequency write and no ROM pins.
           dingbat: 0F 0F then 00 in all thirteen — the waveform's high
           step ends on cycle 6138, and the writeback on 6144 freezes the
           position it lands on, so the high step an unfrozen 2 M waveform
           would show again on 6146 never arrives.
    1F     EE = not CGB/AGB (rows 10-1E are blank there; 00-0F still ran)
    """
    for k in range(16):
        apu_off(a)
        div_anchor(a)
        m = reg_w(a, 0x26, 0x80)       # 5   APU on (tap bit clear: no skip)
        m += reg_w(a, 0x25, 0xFF)      # 10
        m += reg_w(a, 0x24, 0x77)      # 15
        m += reg_w(a, 0x10, 0x11)      # 20  NR10 pace 1, add, shift 1
        m += reg_w(a, 0x11, 0x80)      # 25  NR11 duty 2
        m += reg_w(a, 0x12, 0xF0)      # 30  NR12 volume $F
        m += reg_w(a, 0x13, 0x00)      # 35  NR13 freq lo (1024 = $400)
        m += reg_w(a, 0x14, 0x84)      # 40  NR14 trigger, freq hi 4
        if k < 15:
            restart = 6144 - 5 + k
            m = wait_reg_w(a, m, restart - 5, 0x13, 0x00)
            m = wait_reg_w(a, m, restart, 0x14, 0x80)
        # a restart row only has to answer "did it die at all" — the death is
        # 8 M after the sweep step, so 8 polls is a generous cap and keeps a
        # surviving row down to 2536 M of boot time.  The control row has to
        # COUNT to the death and gets 40.
        poll_nr52_coarse(a, f"{p}a{k}", slot + k, 8 if k < 15 else 40)
    apu_off(a)
    cgb_gate(a, slot, p)
    for j in range(15):
        apu_off(a)
        div_anchor(a)
        m = reg_w(a, 0x26, 0x80)       # 5
        m += reg_w(a, 0x25, 0xFF)      # 10
        m += reg_w(a, 0x24, 0x77)      # 15
        m += reg_w(a, 0x10, 0x1F)      # 20  NR10 pace 1, negate, shift 7
        m += reg_w(a, 0x11, 0x80)      # 25  NR11 duty 2
        m += reg_w(a, 0x12, 0xF0)      # 30  NR12 volume $F
        m += reg_w(a, 0x13, 0xFE)      # 35  freq $7FE -> 2 M per duty step
        m = wait_reg_w(a, m, 54, 0x14, 0x87)   # trigger on cycle 54: puts
        # the duty position on 4 (a low step, with a high one 2 M behind it)
        # when the sweep writeback lands, so the window below holds an edge
        # of the running waveform AND the freeze the writeback causes
        m = wait_pcm(a, m, 6136 + j, slot + 0x10 + j)
    apu_off(a)


@test("NOISEWAVE")
def t_noisewave(a, slot, p):
    """hwprobe row 14's other two halves: the noise divisor codes no test
    ROM reaches, and DMG's wave-RAM access window.

    00-0F  divisor codes 0-7 (lo, hi per code).  gb_noise_deadline
           (apu/abstract_channels.nim) says "Codes 5-7 are not exercised by
           any test and follow the >= 2 case", and ch4_frequency_timer makes
           the LFSR period (8 T for code 0, else 16*code T) << shift.  Each
           row: APU power cycle, NR42 = $F0, NR43 = $40 | code (shift 4,
           15-bit), NR44 = $80 trigger, then poll PCM34 ($FF77) every 14
           M-cycles until its HIGH nibble (channel 4) goes non-zero, 16-bit
           count (capped at $0400).  A trigger loads the LFSR with $7FFF and
           the output is the INVERTED bit 0, so the channel starts silent
           and goes loud on exactly the 15th shift: the count is
           14.5 periods + the trigger delay, i.e. a direct ruler of the
           divisor.  Codes 1-4 (measured by SameSuite) calibrate it; 5, 6
           and 7 must sit at 5:6:7 against them if the divisor really is
           16*code.
           On DMG/MGB $FF77 reads $FF, so every row reads 00 00 — that is
           the "no PCM readback" fingerprint, not a measurement.
    10-1F  k = 0..15: DMG's wave-RAM access window.  Wave RAM is loaded once
           with $01 $12 $23 ... $EF $00 (no byte is $FF) while CH3 is off,
           then each row power-cycles the APU, sets NR30 = $80, NR32 = $20
           (100%), NR33/NR34 = freq $7FD, triggers, and reads $FF30 k+3
           M-cycles later.  $7FD steps the wave pointer every 6 T-cycles,
           deliberately NOT a whole M-cycle: the fetch grid and the CPU's
           coincide only every 12 T, which is what makes a window tied to
           the fetch reachable at all.  ch3_wave_open (apu/channel3.nim,
           GB_WAVE_ACCESS_WINDOW = 2 T) says DMG lets the CPU through only
           in the half-cycle after a completed fetch, so dingbat predicts
           every third byte readable and the rest $FF:
           01 FF FF 12 FF FF 23 FF FF 34 FF FF 45 FF FF 56.  The pattern's
           PHASE is the window's position and how many bytes of each three
           are readable is its width; sixteen $FF means the window is
           narrower than 2 T or does not line up this way at all, sixteen
           wave bytes means DMG has no window.  On CGB/AGB the access
           always resolves, so all 16 are wave data and the row shows the
           pointer walking instead.
    """
    for code in range(8):
        apu_off(a)
        reg_w(a, 0x26, 0x80)
        reg_w(a, 0x25, 0xFF)
        reg_w(a, 0x24, 0x77)
        reg_w(a, 0x20, 0x00)           # NR41 length load 0 (length off)
        reg_w(a, 0x21, 0xF0)           # NR42 volume $F, envelope off
        reg_w(a, 0x22, 0x40 | code)    # NR43 shift 4, 15-bit, divisor code
        reg_w(a, 0x23, 0x80)           # NR44 trigger, length disabled
        a.ld_rr_nn("hl", 0xFF77)
        a.ld_rr_nn("bc", 0)            # 3
        a.label(f"{p}_n{code}")
        a.ld_r_r("a", "hl")            # 2   PCM34
        a.and_n(0xF0)                  # 2   channel 4's nibble
        a.jr(f"{p}_nd{code}", "nz")    # 2 not taken
        a.inc_rr("bc")                 # 2
        a.ld_r_r("a", "b")             # 1
        a.cp_n(0x04)                   # 2   cap $0400 (14336 M)
        a.jr(f"{p}_n{code}", "c")      # 3 taken  => 14 M per poll
        a.label(f"{p}_nd{code}")
        a.ld_r_r("a", "c")
        a.ld_nn_a(slot + 2 * code)
        a.ld_r_r("a", "b")
        a.ld_nn_a(slot + 2 * code + 1)
    apu_off(a)
    a.ld_r_n("a", 0x00)
    a.ldh_n_a(0x1A)                    # NR30 DAC off: wave RAM is plain RAM
    for i in range(16):
        reg_w(a, 0x30 + i, (i * 0x11 + 1) & 0xFF)
    for k in range(16):
        apu_off(a)
        reg_w(a, 0x26, 0x80)
        reg_w(a, 0x25, 0xFF)
        reg_w(a, 0x24, 0x77)
        reg_w(a, 0x1A, 0x80)           # NR30 DAC on
        reg_w(a, 0x1B, 0x00)           # NR31 length load 0
        reg_w(a, 0x1C, 0x20)           # NR32 volume 100%
        reg_w(a, 0x1D, 0xFD)           # NR33 freq $7FD -> 6 T per sample
        reg_w(a, 0x1E, 0x87)           # NR34 trigger, length disabled
        a.delay(k)                     # the read lands at trigger + k + 3
        a.ldh_a_n(0x30)
        a.ld_nn_a(slot + 0x10 + k)
    apu_off(a)


@test("ENVPHASE")
def t_envphase(a, slot, p):
    """Pan Docs audit A9: does the envelope timer get +1 when a trigger
    lands just before an envelope step?

    dingbat's init_volume_envelope sets timer = period unconditionally, so
    an envelope step one M-cycle after a trigger still counts.  Pan Docs
    says the freshly loaded timer is one longer, which moves the first
    volume change a whole envelope period (16384 M) later.  With DIV
    anchored and the sequencer stage zeroed the envelope steps are at 16384
    and 32768.  Both rows answer the SAME question with the same encoding —
    "did the step at 16384 count?", 02 = yes, 01 = no — and read the volume
    ONCE, as the OR of eight PCM12 reads, so the answer does not depend on
    where the duty phase happens to be.  (EE at +1F = not CGB/AGB.)

    00-07  k = 0..7, NR12 = $19 (start volume 1, increment, period 1): the
           trigger's NR14 write lands on cycle 16380+k, i.e. 4 M-cycles
           either side of the envelope step at 16384, and the volume is read
           on cycle 16896.  Counted => the volume already stepped to 2; not
           counted => still 1.  The k the byte steps from 02 to 01 is the
           arming boundary at 1 M resolution; an all-01 row is Pan Docs' +1.
    0F     NR52 after row 00-07 ($x1 = channel 1 still on)
    10-13  k = 0..3 with NR12 = $1A (period 2) and the volume read on cycle
           33280, where the same question moves the first volume change a
           whole envelope period instead of landing on the next one: the
           step at 16384 counted => 2, else 1.  Two different periods
           disagreeing the same way is what says the TIMER moved and not the
           step.  Four rows, because at two envelope periods each row costs
           twice the boot time of one in 00-07.
    1F     EE = not CGB/AGB
    """
    cgb_gate(a, slot, p)
    for nr12, base, first, count, read_at in ((0x19, 0x00, 16380, 8, 16896),
                                              (0x1A, 0x10, 16382, 4, 33280)):
        for k in range(count):
            apu_off(a)
            div_anchor(a)
            m = reg_w(a, 0x26, 0x80)   # 5   APU on
            m += reg_w(a, 0x25, 0xFF)  # 10
            m += reg_w(a, 0x24, 0x77)  # 15
            m += reg_w(a, 0x10, 0x00)  # 20  NR10 no sweep
            m += reg_w(a, 0x11, 0x80)  # 25  NR11 duty 2, length 0
            m += reg_w(a, 0x12, nr12)  # 30  NR12 start vol 1, increment
            m += reg_w(a, 0x13, 0xF8)  # 35  NR13 freq $7F8 -> 8 M steps
            m = wait_reg_w(a, m, first + k, 0x14, 0x87)
            m = pcm_or8(a, m, read_at, slot + base + k)
        if base == 0:
            a.ldh_a_n(0x26)
            a.ld_nn_a(slot + 0x0F)
    apu_off(a)


@test("NR10PACE")
def t_nr10pace(a, slot, p):
    """Pan Docs audit A10: does writing a non-zero pace into NR10 while the
    pace is 0 RELOAD the sweep timer?

    dingbat's NR10 write stores the fields only, so the timer keeps the
    count it has been running since the trigger — with pace 0 that count
    started at 8 (channel1.nim: `if sweep_period > 0: sweep_period else: 8`)
    and reaches 0 on the EIGHTH sweep step whatever the write does.  Pan
    Docs' reload puts the first calculation `pace` sweep steps after the
    WRITE instead.  The two disagree by up to seven sweep steps, and they
    disagree in shape: a descending staircase against a flat row, and a
    dependence on the new pace against none.

    Every row: APU power cycle, DIV anchor, NR10 = $01 (pace 0, increment,
    shift 1), duty 2, volume $F, freq 1000 ($3E8), triggered on cycle 2560
    (between sequencer events, far from any sweep step).  Sweep steps are at
    6144 + 8192n.  The first calculation that runs writes back 1500 and its
    trailing check calculates 2250 > $7FF, so the channel dies ~8 M after
    the sweep step that runs it; the trigger's own check (1500) is safe.
    Bytes are poll counts in units of 317 M-cycles from 6 M after the NR10
    write (00-02, 08-09) or after the trigger (10-12).
    dingbat predicts death on cycle 63496 in every row of 00-09, so each of
    those rows costs 3.6 frames of boot time and there are deliberately only
    five of them: two j values would answer A10, three make the staircase a
    staircase.

    00-02  j = 0, 3, 6: pace written as $11 on cycle 6656 + 8192j (half a
           sweep step after the trigger, then three sweep steps later per
           row).  dingbat: B4 66 19 = 180, 102, 25 — a descending staircase,
           one and the same death seen from a start that moves three sweep
           steps per row.  Pan Docs' reload: ~24 in all three (one sweep
           step after the write, wherever the write is).
    08-09  j = 0 and 6 again with pace 7 ($71).  dingbat: B4 19 — the same
           two bytes as 00 and 02, because the running count does not care
           what the new pace is.  Pan Docs: ~179 in both (seven sweep steps
           after the write).  So 00-02 answers "does the write reload?" by
           its shape and 08-09 answers it again by whether the pace matters,
           and neither answer needs the absolute counts to be right.
    10-12  calibration: pace 1, 2, 4 written BEFORE the trigger, polled from
           the trigger.  Death is then `pace` sweep steps after it: dingbat
           predicts 0C 26 59 = 12, 38, 89 — the ruler that turns every other
           byte on this page into sweep steps (one step is ~26 polls).
    1C     NR52 at the end of the page ($F0 = the channel really is dead)
    """
    def row(tag, dest, nr10_first, write_at, nr10_second, poll_from_trigger):
        apu_off(a)
        div_anchor(a)
        m = reg_w(a, 0x26, 0x80)       # 5   APU on
        m += reg_w(a, 0x25, 0xFF)      # 10
        m += reg_w(a, 0x24, 0x77)      # 15
        m += reg_w(a, 0x10, nr10_first)  # 20  NR10
        m += reg_w(a, 0x11, 0x80)      # 25  NR11 duty 2
        m += reg_w(a, 0x12, 0xF0)      # 30  NR12 volume $F
        m += reg_w(a, 0x13, 0xE8)      # 35  NR13 freq lo (1000 = $3E8)
        m = wait_reg_w(a, m, 2560, 0x14, 0x83)     # trigger on cycle 2560
        if not poll_from_trigger:
            m = wait_reg_w(a, m, write_at, 0x10, nr10_second)
        # 200 polls = 63400 M covers the death this page is waiting for; a
        # row that somehow never dies stops there instead of at $FF.
        poll_nr52_coarse(a, tag, dest, 200)

    for i, j in enumerate((0, 3, 6)):
        row(f"{p}a{j}", slot + i, 0x01, 6656 + 8192 * j, 0x11, False)
    for i, j in enumerate((0, 6)):
        row(f"{p}b{j}", slot + 8 + i, 0x01, 6656 + 8192 * j, 0x71, False)
    for i, pace in enumerate((1, 2, 4)):
        row(f"{p}c{i}", slot + 0x10 + i, (pace << 4) | 0x01, 0, 0, True)
    a.ldh_a_n(0x26)
    a.ld_nn_a(slot + 0x1C)
    apu_off(a)


@test("SEQRESET")
def t_seqreset(a, slot, p):
    """Does an NR52 master off->on reset the DIV-APU frame sequencer, and
    what does it leave `first_half_of_length_period` at?

    dingbat zeroes the sequencer STAGE on power-on but keeps its TIMING on
    DIV (apu.nim), and sets first_half_of_length_period = div_skip, where
    div_skip is SameSuite div_write_trigger_10's rule: powering the APU up
    while the DIV-APU tap bit is already set makes the first event do
    nothing.  So the length-expiry time after a power-on should be a sawtooth
    in the power-on phase, not a constant — a constant would mean the
    sequencer's clock restarts with the power.

    Every row: APU off, DIV anchor (cycle 0), APU on at cycle 128 + 256d,
    then NR51/NR50/NR11/NR12/NR13 and an NR14 = $C4 trigger (with length
    enabled) 30 M later, then a 15 M poll of NR52 bit 0, 16-bit, cap $0200
    (the longest real count on this page is 399 polls and four rows never
    die at all; at the $2000 cap those four alone would cost 28 frames of
    boot time).  Length steps are at 2048 then every 4096 M; a skipped first event pushes
    them to 4096 and every 4096 M.

    00-0F  d = 0..7 (lo, hi per d), NR11 = $BF => length counter 1, so the
           channel dies on the FIRST length step.  dingbat predicts 126,
           109, 92, 75 polls for d = 0..3 — the step at 2048 approached 256
           M (17 polls) closer each row, which is the whole point: a flat
           row would mean the power-on restarts the sequencer's CLOCK and
           not just its stage.  For d = 4..7 it predicts the $0200 cap:
           with the tap bit already set at power-on
           first_half_of_length_period is true, the trigger's own
           length-enable write clocks the counter from 1 to 0, and the
           trigger then reloads the zeroed counter to 64, so the channel
           outlives the poll ($0200 = the cap, not a measurement).  Where
           the row turns to the cap IS the tap bit (M-cycle 1024 = internal
           bit 12).
    10-1F  the same eight power-on phases with NR11 = $BE => counter 2, so
           the trigger-time clock cannot kill it and the expiry is always
           measurable: dingbat predicts ~399, 374, 348, 323 for d = 0..3
           (dying at 6144, the second length step) and ~194, 169, 143, 118
           for d = 4..7 (the first event skipped, the trigger's clock spent
           one count, so it dies at 4096).  The two halves together separate
           "the event was skipped" from "the counter was clocked early".
    """
    for row, (nr11, base) in enumerate(((0xBF, 0x00), (0xBE, 0x10))):
        for d in range(8):
            apu_off(a)
            div_anchor(a)
            m = wait_reg_w(a, 0, 128 + 256 * d, 0x26, 0x80)   # APU on
            m += reg_w(a, 0x25, 0xFF)
            m += reg_w(a, 0x24, 0x77)
            m += reg_w(a, 0x11, nr11)  # NR11 duty 0, length load
            m += reg_w(a, 0x12, 0xF0)  # NR12 volume $F, envelope off
            m += reg_w(a, 0x13, 0x00)  # NR13 freq $400 -> 1024 M per step
            m += reg_w(a, 0x14, 0xC4)  # NR14 trigger + LENGTH ENABLE
            # cap $0200: the longest real count on this page is 399 polls,
            # and four rows of row 1 never die at all — at the $2000 cap
            # those four alone would cost 28 frames of boot time.
            poll_nr52_16(a, f"{p}r{row}d{d}", slot + base + 2 * d, 0x02)
    apu_off(a)


# ═══════════════════════════════════════════════════════════════════════════
# program assembly
# ═══════════════════════════════════════════════════════════════════════════

def emit_program(a, autopage):
    npages = len(TESTS)

    # ── interrupt vectors -> WRAM trampolines ────────────────────────────
    for i, vec in enumerate((0x40, 0x48, 0x50, 0x58, 0x60)):
        a.org(vec)
        a.jp(TRAMP + i * 4)
    # address 0 catches the cancelled-dispatch jump of the IEPUSH probe
    if any(name == "IEPUSH" for name, _ in TESTS):
        a.org(0x0000)
        a.jp("iepush_zero")

    # fixed-address landmarks:
    #   0x150  jp main            (entry)
    #   0x160  IEPUSH stub, PC high byte 0x01 (cancels the timer IE bit)
    #   0x400  IEPUSH stub, PC high byte 0x04 (keeps the timer IE bit)
    #   0x500  0x100-byte DMA source pattern (page 0x05): i ^ 0xA5
    #   0x600  everything else, emitted linearly
    a.org(0x150)
    a.jp("entry")
    a.org(0x500)
    a.label("dma_pattern")
    for i in range(0x100):
        a.db(i ^ 0xA5)

    # ── entry: snapshot the boot handoff state before touching anything ──
    a.org(0x600)
    a.label("entry")
    a.push("af")                       # boot SP=FFFE on every model: safe
    for i, r in enumerate("bcdehl"):
        a.ld_r_r("a", r)
        a.ld_nn_a(SNAP + 2 + i)
    a.pop("bc")                        # b = boot A, c = boot F
    a.ld_r_r("a", "b")
    a.ld_nn_a(SNAP + 0)
    a.ld_r_r("a", "c")
    a.ld_nn_a(SNAP + 1)
    a.ld_nn_sp(SNAP + 8)
    a.ld_rr_nn("sp", STACK_TOP)
    for i, reg in enumerate((DIV, LY, STAT, IF, LCDC, IE)):
        a.ldh_a_n(reg)
        a.ld_nn_a(SNAP + 10 + i)
    a.di()
    a.xor_r("a")
    a.ldh_n_a(IE)
    a.ldh_n_a(IF)
    a.call("reset_tramps")

    # ── video init (LCD off first — only ever during vblank) ─────────────
    a.call("lcd_off_safe")
    # font: expand 1bpp -> 2bpp colour 3 at $8000
    a.ld_rr_nn("hl", 0x8000)
    a.ld_rr_nn("de", "font_data")
    a.ld_rr_nn("bc", len(FONT_ORDER) * 8)
    a.label("fl_loop")
    a.ld_a_rr("de")
    a.ld_hli_a()
    a.ld_hli_a()
    a.inc_rr("de")
    a.dec_rr("bc")
    a.ld_r_r("a", "b")
    a.or_r("c")
    a.jr("fl_loop", "nz")
    # clear tilemap bank 0, then "bank 1" (a no-op re-clear on DMG, the
    # attribute map on CGB — VBK writes are ignored on DMG so no branch)
    for bank in (1, 0):                # end with VBK=0 selected
        a.ld_r_n("a", bank)
        a.ldh_n_a(VBK)
        a.ld_rr_nn("hl", 0x9800)
        a.ld_rr_nn("bc", 0x0400)
        a.label(f"cm{bank}_loop")
        a.xor_r("a")
        a.ld_hli_a()
        a.dec_rr("bc")
        a.ld_r_r("a", "b")
        a.or_r("c")
        a.jr(f"cm{bank}_loop", "nz")
    # palettes: DMG BGP idx0 white / idx3 black; CGB palette 0 likewise
    # (BCPS/BCPD writes are ignored on DMG — again no branch)
    a.ld_r_n("a", 0xC0)
    a.ldh_n_a(BGP)
    a.ld_r_n("a", 0x80)
    a.ldh_n_a(BCPS)
    for lo, hi in ((0xFF, 0x7F), (0x94, 0x52), (0x4A, 0x29), (0x00, 0x00)):
        a.ld_r_n("a", lo)
        a.ldh_n_a(BCPD)
        a.ld_r_n("a", hi)
        a.ldh_n_a(BCPD)
    a.xor_r("a")
    a.ldh_n_a(SCY)
    a.ldh_n_a(SCX)
    a.ld_r_n("a", 0x91)                # LCD on, BG on, tiles $8000
    a.ldh_n_a(LCDC)

    # ── run every probe ──────────────────────────────────────────────────
    for i, (name, _fn) in enumerate(TESTS):
        a.ld_r_n("a", i)
        a.ldh_n_a(B_PROBE)
        a.xor_r("a")
        a.ldh_n_a(B_STAGE)
        a.ld_rr_nn("hl", slot_addr(i))
        a.call("clear_slot")
        a.call(f"t{i}_{name_label(name)}")
        # every probe must return with LCD on and IME off; re-park all the
        # state a probe may have dirtied so the next probe starts equal
        a.xor_r("a")
        a.ldh_n_a(IE)
        a.ldh_n_a(IF)
        a.ldh_n_a(SCY)
        a.ldh_n_a(SCX)
        a.ldh_n_a(TAC)
        a.ldh_n_a(TMA)
        a.ldh_n_a(TIMA)
        a.ldh_n_a(SB)
        a.ldh_n_a(SC)
        a.ldh_n_a(LYC)
        a.ldh_n_a(STAT)
        a.ld_r_n("a", 0xC0)
        a.ldh_n_a(BGP)
        a.ld_r_n("a", 0x91)
        a.ldh_n_a(LCDC)
        a.call("reset_tramps")

    # ── per-slot + global CRC16 tables ───────────────────────────────────
    a.ld_rr_nn("hl", SLOTS)
    a.ld_r_n("a", 0)
    a.ld_nn_a(SCRATCH)                 # slot index
    a.label("crc_slots")
    a.ld_rr_nn("de", 0xFFFF)
    a.ld_rr_nn("bc", SLOT_SIZE)
    a.call("crc16")                    # hl advances past the slot
    a.push("hl")
    a.ld_a_nn(SCRATCH)                 # crc table entry = CRCTAB + idx*2
    a.ld_r_r("l", "a")
    a.ld_r_n("h", 0)
    a.add_hl_rr("hl")
    a.ld_rr_nn("bc", "CRCTAB_slot")    # patched constant below via labels
    a.add_hl_rr("bc")
    a.ld_r_r("a", "e")
    a.ld_hli_a()
    a.ld_r_r("a", "d")
    a.ld_hli_a()
    a.ld_a_nn(SCRATCH)
    a.inc_r("a")
    a.ld_nn_a(SCRATCH)
    a.pop("hl")
    a.cp_n(npages)
    a.jr("crc_slots", "nz")
    # global: crc over all slots at once
    a.ld_rr_nn("hl", SLOTS)
    a.ld_rr_nn("de", 0xFFFF)
    a.ld_rr_nn("bc", npages * SLOT_SIZE)
    a.call("crc16")
    a.ld_r_r("a", "e")
    a.ld_nn_a(GCRC)
    a.ld_r_r("a", "d")
    a.ld_nn_a(GCRC + 1)

    # ── viewer ───────────────────────────────────────────────────────────
    a.ld_r_n("a", 0x01)
    a.ldh_n_a(B_ALIVE)
    a.xor_r("a")
    a.ldh_n_a(V_PAGE)
    a.ldh_n_a(V_FRAME)
    a.ld_r_n("a", 0xFF)
    a.ldh_n_a(V_PREV)
    a.call("draw_page")
    a.label("view_loop")
    a.ldh_a_n(V_PAGE)                  # breadcrumb: page on show
    a.ldh_n_a(B_PROBE)
    a.ldh_a_n(V_FRAME)
    a.ldh_n_a(B_STAGE)
    # count one frame: LY reaches 144, then leaves it
    a.label("vw_a")
    a.ldh_a_n(LY)
    a.cp_n(144)
    a.jr("vw_a", "nz")
    if autopage:
        a.ldh_a_n(V_FRAME)
        a.inc_r("a")
        a.ldh_n_a(V_FRAME)
        a.cp_n(64)
        a.jr("vw_next", "nz")
        a.xor_r("a")
        a.ldh_n_a(V_FRAME)
        a.ldh_a_n(V_PAGE)
        a.inc_r("a")
        a.cp_n(npages)
        a.jr("vw_wrapped", "c")
        a.xor_r("a")
        a.label("vw_wrapped")
        a.ldh_n_a(V_PAGE)
        a.call("draw_page")
        a.label("vw_next")
    else:
        a.call("read_pad")             # -> a = held buttons (edge-filtered)
        a.ld_r_r("b", "a")
        a.ldh_a_n(V_PREV)
        a.cpl()
        a.and_r("b")                   # newly pressed
        a.ld_r_r("c", "a")
        a.ld_r_r("a", "b")
        a.ldh_n_a(V_PREV)
        # RIGHT (bit0) or A (bit4): next page.  LEFT (bit1) or B (bit5): prev
        a.ld_r_r("a", "c")
        a.and_n(0x11)
        a.jr("vw_no_next", "z")
        a.ldh_a_n(V_PAGE)
        a.inc_r("a")
        a.cp_n(npages)
        a.jr("vw_store", "c")
        a.xor_r("a")
        a.jr("vw_store")
        a.label("vw_no_next")
        a.ld_r_r("a", "c")
        a.and_n(0x22)
        a.jr("vw_idle", "z")
        a.ldh_a_n(V_PAGE)
        a.dec_r("a")
        a.cp_n(0xFF)                   # wrapped below 0?
        a.jr("vw_store", "nz")
        a.ld_r_n("a", npages - 1)
        a.label("vw_store")
        a.ldh_n_a(V_PAGE)
        a.call("draw_page")
        a.label("vw_idle")
    a.label("vw_z")
    a.ldh_a_n(LY)
    a.cp_n(144)
    a.jr("vw_z", "z")                  # leave vblank line before re-arming
    a.jp("view_loop")

    # ── read_pad: returns a = dpad low nibble | buttons high nibble ──────
    # bit0 RIGHT bit1 LEFT bit2 UP bit3 DOWN bit4 A bit5 B bit6 SEL bit7 STA
    a.label("read_pad")
    a.ld_r_n("a", 0x20)                # select dpad
    a.ldh_n_a(P1)
    for _ in range(4):
        a.ldh_a_n(P1)
    a.cpl()
    a.and_n(0x0F)
    a.ld_r_r("b", "a")
    a.ld_r_n("a", 0x10)                # select buttons
    a.ldh_n_a(P1)
    for _ in range(4):
        a.ldh_a_n(P1)
    a.cpl()
    a.and_n(0x0F)
    a.swap_r("a")
    a.or_r("b")
    a.ld_r_r("b", "a")
    a.ld_r_n("a", 0x30)                # deselect
    a.ldh_n_a(P1)
    a.ld_r_r("a", "b")
    a.ret()

    # ── crc16 (CCITT, poly $1021): hl=ptr, bc=len, de=crc-in -> de, hl+len
    a.label("crc16")
    a.ld_a_hli()
    a.xor_r("d")
    a.ld_r_r("d", "a")
    a.push("bc")
    a.ld_r_n("b", 8)
    a.label("crc_bit")
    a.sla_r("e")
    a.rl_r("d")
    a.jr("crc_noxor", "nc")
    a.ld_r_r("a", "d")
    a.xor_n(0x10)
    a.ld_r_r("d", "a")
    a.ld_r_r("a", "e")
    a.xor_n(0x21)
    a.ld_r_r("e", "a")
    a.label("crc_noxor")
    a.dec_r("b")
    a.jr("crc_bit", "nz")
    a.pop("bc")
    a.dec_rr("bc")
    a.ld_r_r("a", "b")
    a.or_r("c")
    a.jr("crc16", "nz")
    a.ret()

    # ── draw_page: renders page V_PAGE.  LCD off (in vblank) during draw ─
    a.label("draw_page")
    a.call("lcd_off_safe")
    # row 0: "GBEDGE V1      Pxx"
    a.ld_rr_nn("hl", 0x9800)
    a.ld_rr_nn("de", "str_title")
    a.ld_r_n("b", 9)
    a.call("copy_tiles")
    a.ld_rr_nn("hl", 0x9800 + 15)
    a.ld_r_n("a", tile_of("P"))
    a.ld_hli_a()
    a.ldh_a_n(V_PAGE)
    a.call("print_hex")
    # row 2: test name, 10 tiles from the name table
    a.ldh_a_n(V_PAGE)
    a.ld_r_r("l", "a")
    a.ld_r_n("h", 0)
    a.add_hl_rr("hl")                  # *2
    a.add_hl_rr("hl")                  # *4
    a.add_hl_rr("hl")                  # *8
    a.ld_r_r("e", "l")
    a.ld_r_r("d", "h")
    a.ldh_a_n(V_PAGE)
    a.ld_r_r("l", "a")
    a.ld_r_n("h", 0)
    a.add_hl_rr("hl")                  # *2
    a.add_hl_rr("de")                  # *8 + *2 = *10
    a.ld_rr_nn("de", "name_table")
    a.add_hl_rr("de")
    a.ld_r_r("e", "l")
    a.ld_r_r("d", "h")
    a.ld_rr_nn("hl", 0x9800 + 2 * 32)
    a.ld_r_n("b", 10)
    a.call("copy_tiles")
    # rows 4..11: the 32 slot bytes, 4 per row, offset label in col 0
    a.ldh_a_n(V_PAGE)                  # de = slot base
    a.ld_r_r("l", "a")
    a.ld_r_n("h", 0)
    for _ in range(5):
        a.add_hl_rr("hl")              # *32
    a.ld_rr_nn("de", SLOTS)
    a.add_hl_rr("de")
    a.ld_r_r("e", "l")
    a.ld_r_r("d", "h")
    a.ld_r_n("c", 0)                   # c = running byte offset for the label
    for row in range(8):
        a.ld_rr_nn("hl", 0x9800 + (4 + row) * 32)
        a.ld_r_r("a", "c")
        a.call("print_hex")            # offset label
        a.inc_rr("hl")                 # gap
        for _col in range(4):
            a.ld_a_rr("de")
            a.inc_rr("de")
            a.call("print_hex")
            a.inc_rr("hl")
        a.ld_r_r("a", "c")
        a.add_a_n(4)
        a.ld_r_r("c", "a")
    # row 13: "CRC xxxx" (this slot)   row 14: "ALL xxxx" (global)
    a.ld_rr_nn("hl", 0x9800 + 13 * 32)
    a.ld_rr_nn("de", "str_crc")
    a.ld_r_n("b", 4)
    a.call("copy_tiles")
    a.ldh_a_n(V_PAGE)                  # de = CRCTAB_slot + page*2
    a.ld_r_r("e", "a")
    a.ld_r_n("d", 0)
    a.ld_rr_nn("bc", "CRCTAB_slot")
    a.push("hl")
    a.ld_r_r("l", "e")
    a.ld_r_r("h", "d")
    a.add_hl_rr("hl")
    a.add_hl_rr("bc")
    a.ld_a_hli()
    a.ld_r_r("e", "a")                 # e = lo
    a.ld_a_hli()
    a.ld_r_r("d", "a")                 # d = hi
    a.pop("hl")
    a.ld_r_r("a", "d")
    a.call("print_hex")
    a.ld_r_r("a", "e")
    a.call("print_hex")
    a.ld_rr_nn("hl", 0x9800 + 14 * 32)
    a.ld_rr_nn("de", "str_all")
    a.ld_r_n("b", 4)
    a.call("copy_tiles")
    a.ld_a_nn(GCRC + 1)
    a.call("print_hex")
    a.ld_a_nn(GCRC)
    a.call("print_hex")
    # row 16: model line — "MODEL xx yy" (boot A, boot B)
    a.ld_rr_nn("hl", 0x9800 + 16 * 32)
    a.ld_rr_nn("de", "str_model")
    a.ld_r_n("b", 6)
    a.call("copy_tiles")
    a.ld_a_nn(SNAP + 0)
    a.call("print_hex")
    a.inc_rr("hl")
    a.ld_a_nn(SNAP + 2)
    a.call("print_hex")
    a.ld_r_n("a", 0x91)
    a.ldh_n_a(LCDC)
    a.ret()

    # copy_tiles: de=src, hl=dst, b=count
    a.label("copy_tiles")
    a.ld_a_rr("de")
    a.inc_rr("de")
    a.ld_hli_a()
    a.dec_r("b")
    a.jr("copy_tiles", "nz")
    a.ret()

    # print_hex: a=byte -> two tiles at hl (hl += 2).  clobbers a only via b
    a.label("print_hex")
    a.push("bc")
    a.ld_r_r("b", "a")
    a.swap_r("a")
    a.and_n(0x0F)
    a.inc_r("a")                       # tile = nibble + 1 ('0' is tile 1)
    a.ld_hli_a()
    a.ld_r_r("a", "b")
    a.and_n(0x0F)
    a.inc_r("a")
    a.ld_hli_a()
    a.pop("bc")
    a.ret()

    emit_helpers(a)

    # ── the probes themselves ────────────────────────────────────────────
    for i, (name, fn) in enumerate(TESTS):
        pfx = f"t{i}_{name_label(name)}"
        a.label(pfx)
        fn(a, slot_addr(i), pfx)
        a.ret()

    # ── data ─────────────────────────────────────────────────────────────
    def str_tiles(s):
        return bytes(tile_of(c) for c in s)

    a.label("font_data")
    a.blob(font_1bpp())
    a.label("str_title")
    a.blob(str_tiles("GBEDGE V1"))
    a.label("str_crc")
    a.blob(str_tiles("CRC "))
    a.label("str_all")
    a.blob(str_tiles("ALL "))
    a.label("str_model")
    a.blob(str_tiles("MODEL "))
    a.label("name_table")
    for name, _fn in TESTS:
        assert len(name) <= 10, name
        a.blob(str_tiles(name.ljust(10)))

    a.resolve()


def name_label(name):
    return name.strip().replace(" ", "_").replace("-", "_").replace(".", "")


# WRAM addresses used by the CRC pass (defined late so emit_program reads them)
GCRC = SCRATCH + 2                     # 2 bytes global crc (lo, hi)


def build(autopage, out_name):
    a = Asm()
    # CRCTAB_slot lives in WRAM, but the assembler only patches labels —
    # register it as one
    a.labels["CRCTAB_slot"] = SCRATCH + 0x10
    emit_program(a, autopage)

    # header
    a.rom[0x100:0x104] = bytes([0x00, 0xC3, 0x50, 0x01])      # nop; jp $0150
    a.rom[0x134:0x144] = b"GBEDGE\0\0\0\0\0\0\0\0\0\0"
    a.rom[0x143] = 0x80                # CGB-enhanced, DMG-compatible
    a.rom[0x147] = 0x00                # ROM only
    a.rom[0x148] = 0x00                # 32 KiB
    a.rom[0x149] = 0x00                # no cart RAM
    csum = 0
    for adr in range(0x134, 0x14D):
        csum = (csum - a.rom[adr] - 1) & 0xFF
    a.rom[0x14D] = csum

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), out_name)
    open(out, "wb").write(a.rom)
    romfix.gb_logo(out)          # the header logo, via rgbfix
    code_end = max(addr for addr, byte in enumerate(a.rom) if byte) + 1
    print(f"{out}: {len(TESTS)} pages, image used {code_end:#x} bytes")


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        if arg.startswith("--only="):      # debug: keep just probes i..j
            lo, hi = arg.split("=")[1].split(":")
            del TESTS[int(hi):]
            del TESTS[:int(lo)]
    build(False, "gbedge.gb")
    build(True, "gbedge-auto.gb")
