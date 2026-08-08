# GB PPU shared base (included by gb.nim)

# Dots the re-enabled PPU is already into line 0 by the time the LCDC write
# retires. See the LCDC-enable path in ppu_write for the derivation; it is
# overridable because both ROMs that pin it read STAT, so the sweep has to be
# re-run whenever the STAT read model moves (see STAT_READ_LAG).
const LCD_ON_HEAD_START* {.intdefine.} = 5'i32

# Dots past the start of VBlank at which the CGB boot ROM hands off. See
# skip_boot for the derivation; overridable so the sweep can be re-run.
const CGB_BOOT_PHASE* {.intdefine.} = 161

# Dot of line 153 at which the DMG/MGB boot ROM hands off. See skip_boot for the
# derivation; overridable so the sweep can be re-run.
const DMG_BOOT_PHASE* {.intdefine.} = 397

# ---- Where STAT's mode bits are sampled, and where its interrupt line sits --
#
# The gambatte m2int_* families bracket each mode boundary with pairs of ROMs
# whose STAT read moves by exactly one M-cycle, all anchored on the mode-2 STAT
# interrupt: m2int_m2stat_{1,2} at the 2->3 edge, m2int_m3stat plus its
# scx/{0,2,3,5} sweep at the 3->0 edge, m2int_m0stat_{1,2} at 0->2, and
# m2int_m0irq_{1,2} on the interrupt itself. Writing the STAT value a read
# returns as "the internal mode in effect during dot (last dot of the read's
# M-cycle) - L", and letting the whole STAT interrupt line sit D M-cycles
# earlier than the mode flag, every one of those ROMs is satisfied by exactly
# one equation:
#
#     4*D + L = 4
#
# The scx sweep is what makes it an equation rather than an inequality: at
# SCX&7 = 3 the mode-0 edge lands on the last dot of an M-cycle, which pins the
# sum from below, and the 2->3 edge pins it from above. Two integer solutions
# fit, and they are NOT interchangeable:
#
#   (a) D = 0, L = 4 -- the mode bits are a copy of the internal mode taken one
#       M-cycle ago, and the interrupt line is already right.
#   (b) D = 1, L = 0 -- the mode bits are the live mode as of the last dot of
#       the read's own M-cycle, and the STAT interrupt line leads the mode flag
#       by one M-cycle.
#
# BOTH ARE WRONG. Measured 2026-08-02, full runner, one build per cell, as
# `gambatte mooneye microtest` (of 5005 / 115 / 513), at the shipping
# STAT_M2_PULSE and from e86cb34 -- so the absolute gambatte column is 112 rows
# below today's (cb2aaa6's object penalty landed after), but every cell of it
# was taken against the same tree and the comparison holds:
#
#   D \ L        0                1                2                3 (ship)        4
#   0     3393 111 412     3414 111 410     3400 111 409     3422 112 399    3347 108 374
#   1     3238 108 369     3246 108 367     3254 108 366     3251 109 356    3261 105 331
#
# Read that table before spending a day on this again. Three things in it:
#
#   * The whole D = 1 ROW is a loss, at every L: -184 gambatte rows and -4
#     mooneye acceptance rows at (1, 0), and no cell of it beats 3261/105.
#     GBMicrotest says why in one line. Its int_hblank_nops_scx0..7,
#     int_lyc_nops, int_vblank1_nops and lyc1_int_nops_b rows count how many
#     NOPs of a sled retire before the interrupt lands -- no STAT read is
#     involved at all -- and every one of them goes from dingbat's exact
#     hardware value to exactly one M-cycle early. So do the mooneye rows (b)
#     loses: hblank_ly_scx_timing-GS, intr_1_2_timing-GS, intr_2_0_timing and
#     six intr_2_mode0_scx*_timing_nops, which time a STAT interrupt against LY,
#     against another interrupt, or against a NOP count -- against anything that
#     is not a STAT read. The STAT interrupt line does not lead the mode flag,
#     and that is the one thing (b) needs.
#   * D and L are not independent for the ROMs that motivated them, so buying
#     the m2int_* dot with D is not an alternative to buying it with L -- it is
#     the same purchase. Those ROMs read STAT from inside a STAT handler, so
#     moving the interrupt moves the read with it and the sampled dot is
#     (today's last dot) - 4D - L: every cell on the 4D + L = 4 diagonal samples
#     the SAME dot. What differs is everything else in the handler, and D moves
#     all of that by a whole M-cycle where L moves none of it. That is why (b)
#     costs 184 gambatte rows for the same dot (a) costs 75 for -- and with the
#     OAM source modelled as a pulse (below), (b) does not even collect: its
#     m2int_m3stat goes 27 -> 21 and m2int_m0irq 45 -> 34, the wrong way, while
#     (a) still takes them 27 -> 35 and 3 -> 5.
#   * L alone is a real trade, not a window. gambatte and mooneye-wilbertpol
#     want L = 3; GBMicrotest wants L <= 2 (its win*_b and ppu_sprite0_scx*_b
#     rows against wilbertpol's intr_2_mode0_scx*_timing_nops), and the two
#     cross between 2 and 3. L = 3 is kept because it is the best gambatte cell
#     and the only one that regresses nothing.
#
# Where the m2int_* dot actually lives is still open. The GBMicrotest
# hblank_int_scx0..7 family splits by SCX & 3 rather than by anything an M-cycle
# wide, and this note used to read that as "a mode-3 LENGTH residual per
# SCX & 7". **That reading is wrong and it was measured out on 2026-08-03.**
# Each of the eight ROMs writes one SCX and nothing else differs between them,
# so one sweep of a uniform dot offset reads out all eight windows at once (a
# per-residue table cannot carry more, which is the tell). They come out as one
# single 4-dot window shifted by one dot per residue, and the unique
# constant-offset
# model fitting all of them is a UNIFORM two dots (L = 170 + SCX&7, not
# 172 + SCX&7 with a per-residue correction). The SCX & 3 "split" is what a
# uniform 2-dot error looks like when eight lengths one dot apart are sampled by
# a ROM that counts `INC A`s, i.e. on a 4-dot grid. The table is at
# M3_END_EARLY in fifo_ppu.nim, with what a uniform -2 costs; the same 2 dots
# reached through the LCD-on path and through the boot phase, and what refuses
# each route, are at LCD_ON_LINE0_TRIM in gb.nim. Nothing in this file can give
# them, and neither can mode 3's length.
#
# Both knobs stay, at the values that reproduce this tree, so the next attempt
# is a build flag rather than a restructure. They compile out entirely at those
# values -- no fields, no branches, no per-tick store -- so an experiment cannot
# cost the shipping build anything. `-d:STAT_READ_LAG=4` is model (a);
# `-d:STAT_IRQ_LEAD=1 -d:STAT_READ_LAG=0` is model (b).
# Both constants are declared at the top of gb.nim (the GbPpu fields they gate
# are in that file's type block), and both are `intdefine`s:
#
#   STAT_IRQ_LEAD   D, in CPU M-cycles: how far the STAT interrupt line's copy
#                   of the mode and of LY runs ahead of the ones the CPU reads
#                   back. One M-cycle is 4 dots at normal speed and 2 in double
#                   speed (Pan Docs, "Dots"), so it is scaled per use rather
#                   than baked into a dot count -- the gambatte *_ds_* rows are
#                   what catch it if it is not.
#   STAT_READ_LAG   L, in dots back from the last dot of the reading M-cycle.
#
# with STAT_IRQ_SPLIT / STAT_READ_HOLD the derived "does this cost anything"
# bits. At L = 3 the sampled dot is the first of the M-cycle, which the tick
# already latches into `read_mode` for the CPU's VRAM/OAM locks, so the hold
# is not needed either.

when STAT_IRQ_SPLIT:
  # The STAT interrupt line is a level-triggered OR of the enabled sources
  # feeding one rising-edge detector (Pan Docs, "STAT interrupt" -- that is what
  # makes STAT blocking work), so the sources are free to be a distinct signal
  # from the bits the CPU reads back. These are that signal. What stays behind
  # with the flag, because a ROM pins it there: the mode FLAG and the VRAM/OAM
  # lock edges hanging off it (mooneye lcdon_timing-GS, intr_2_oam_ok_timing),
  # LY and the coincidence BIT (gambatte lycint_lycflag), and the vblank
  # interrupt with the DMG OAM pulse measured to coincide with it (mooneye
  # vblank_stat_intr-GS).
  template irq_mode_of(ppu: GbPpu): uint8 = ppu.irq_mode
  template irq_ly_of(ppu: GbPpu): uint8 = ppu.irq_ly
else:
  template irq_mode_of(ppu: GbPpu): uint8 = ppu.mode_flag
  template irq_ly_of(ppu: GbPpu): uint8 = ppu.ly

when not LCD_ON_TRIM_ANY:
  template gb_line_end*(ppu: GbPpu): int32 = 456'i32
else:
  template gb_line_end*(ppu: GbPpu): int32 =
    (case ppu.lcdon_lines
     of 2'u8: 456'i32 - LCD_ON_LINE0_TRIM
     of 1'u8: 456'i32 - LCD_ON_LINE1_TRIM
     else: 456'i32)

proc new_ppu_base(cgb: bool): GbPpu =
  result = GbPpu(
    lcd_control:  0x00,
    lcd_status:   0x80,
    first_line:   true,
    current_window_line: 0,
  )
  result.vram[0] = newSeq[uint8](0x2000)
  result.vram[1] = newSeq[uint8](0x2000)
  result.sprite_table = newSeq[uint8](0xA0)
  result.framebuffer  = newSeq[uint16](GB_WIDTH * GB_HEIGHT)
  result.bgp  = [0'u8, 0, 0, 0]
  result.obp0 = [0'u8, 0, 0, 0]
  result.obp1 = [0'u8, 0, 0, 0]
  if not cgb:
    cast[ptr uint16](addr result.pram[0])[]    = DMG_COLORS[0]
    cast[ptr uint16](addr result.pram[2])[]    = DMG_COLORS[1]
    cast[ptr uint16](addr result.pram[4])[]    = DMG_COLORS[2]
    cast[ptr uint16](addr result.pram[6])[]    = DMG_COLORS[3]
    cast[ptr uint16](addr result.obj_pram[0])[] = DMG_COLORS[0]
    cast[ptr uint16](addr result.obj_pram[2])[] = DMG_COLORS[1]
    cast[ptr uint16](addr result.obj_pram[4])[] = DMG_COLORS[2]
    cast[ptr uint16](addr result.obj_pram[6])[] = DMG_COLORS[3]
    cast[ptr uint16](addr result.obj_pram[8])[] = DMG_COLORS[0]
    cast[ptr uint16](addr result.obj_pram[10])[] = DMG_COLORS[1]
    cast[ptr uint16](addr result.obj_pram[12])[] = DMG_COLORS[2]
    cast[ptr uint16](addr result.obj_pram[14])[] = DMG_COLORS[3]
  # HDMA1-5 all read back as $FF (1-4 are write-only, 5's bit 7 says "no
  # transfer active"), and the address counters hold the $FF the four registers
  # would have been written with.
  result.hdma5    = 0xFF
  result.hdma_src = 0xFFF0'u16
  result.hdma_dst = 0xFFF0'u16
  result.ran_bios = cgb

method reset_render_scratch*(ppu: GbPpu) {.base.} =
  ## Reset the renderer's per-line scratch to a clean pre-line state. The
  ## savestate is renderer-agnostic and does NOT serialize this scratch
  ## (it is fully rebuilt on every mode 2->3 transition and never read at
  ## vblank, where states are captured). Loading a state onto a FRESH core
  ## is therefore fine, but a rollback restore onto a RUNNING core would
  ## otherwise leave stale scratch (e.g. a FIFO lx past 160 that never hits
  ## its `== 160` line-end and runs off the framebuffer). Called after every
  ## state load; the base (scanline) renderer rebuilds its scratch per line,
  ## so it is a no-op here.
  discard

method skip_boot*(ppu: GbPpu; gb: GB) {.base.} =
  # Reproduce the post-boot VRAM tiles: blank tile $00 (VRAM inits to zero), the
  # Nintendo logo $01-$18 decompressed from the cart's OWN header (so no Nintendo
  # logo data lives in our source), and the generic ® tile $19.
  write_boot_logo(gb.cartridge.rom, ppu.vram[0])
  for i in 0 ..< POST_BOOT_RA_TILE.len:
    ppu.vram[0][0x190 + i] = POST_BOOT_RA_TILE[i]  # tile $19 = byte offset 400
  if not gb.cgb_enabled:
    # ...and the tile MAP those tiles are placed through. The DMG boot ROM's
    # last drawing act, verbatim from the published disassembly:
    #
    #   LD A,$19 / LD ($9910),A / LD HL,$992f
    #   .row:  LD C,$0c
    #   .cell: DEC A / JR Z,done / LD (HL-),A / DEC C / JR NZ,.cell
    #          LD L,$0f / JR .row
    #
    # so $9910 holds the (R) tile $19, $992F..$9924 hold $18..$0D and
    # $990F..$9904 hold $0C..$01 — two 12-tile rows of logo with the (R) tile
    # to the right of the first one. Everything else stays $00, which the boot
    # ROM's VRAM clear already left there. dingbat wrote the logo tile DATA at
    # the handoff but never the map, so a cart that reads the map back sees an
    # all-zero one: BullyGB's `initmap` prints "Invalid initial map data".
    # The CGB path is deliberately not seeded here — its boot ROM builds a
    # different map and nothing in the tree measures it.
    ppu.vram[0][0x1910] = 0x19
    for i in 0 ..< 12:
      ppu.vram[0][0x1904 + i] = uint8(0x01 + i)
      ppu.vram[0][0x1924 + i] = uint8(0x0D + i)
  if gb.cgb_enabled:
    # The CGB boot ROM hands off mid-VBlank (gambatte display_startstate/ly
    # reads LY=0x90); the sub-frame phase is calibrated against gambatte
    # display_startstate/stat_*, div/ and serial/ tests.
    # 159..162 is the window gambatte display_startstate/stat_1+stat_2 leaves
    # open; 161 is the only member of it with the right sub-M-cycle phase.
    # The CPU and the PPU are driven from one clock and every instruction is a
    # whole number of M-cycles, so the offset between the PPU's dot grid and
    # the CPU's M-cycle grid is a fixed property of the machine, identical on
    # DMG and CGB — the boot ROM's handoff only says WHERE in the frame the
    # handoff lands, not where inside an M-cycle. On DMG that offset comes out
    # of the LCDC-enable seed of 5 (mooneye lcdon_timing-GS /
    # hblank_ly_scx_timing-GS): the line ends 457-5 = 452 dots later, a whole
    # number of M-cycles. Matching it here means 457 - phase ≡ 0 (mod 4), i.e.
    # phase ≡ 1 (mod 4). At 160 every CGB row of the gambatte m2int_* families
    # missed its DMG twin by exactly one M-cycle while the DMG rows passed.
    const phase = CGB_BOOT_PHASE
    ppu.ly = uint8(144 + phase div 456)
    ppu.cycle_counter = int32(phase mod 456)
    ppu.lcd_status = (ppu.lcd_status and not 3'u8) or 1'u8  # mode 1
    when STAT_IRQ_SPLIT:
      ppu.irq_mode = 1
      ppu.irq_ly = ppu.ly
    ppu.first_line = false
    when LCD_ON_TRIM_ANY: ppu.lcdon_lines = 0
    if not gb.cgb_native:
      # DMG cart on CGB hardware. The last thing the real boot ROM does before
      # it hands over is fill palette 0 through BCPD/OCPD, because from the
      # instant it sets KEY0 those ports are gone and the cart can never write
      # a colour again — everything it draws indexes these entries via
      # BGP/OBP0/OBP1. Skipping the boot ROM has to leave the same thing
      # behind; without it a compatibility cart renders through an all-zero
      # palette, i.e. a black screen (which is what the three gambatte
      # m2int_m3stat/nobg/*_cgb04c rows were reading as an unknown glyph).
      for i in 0 ..< 4:
        cast[ptr uint16](addr ppu.pram[i * 2])[]      = CGB_COMPAT_BG_COLORS[i]
        cast[ptr uint16](addr ppu.obj_pram[i * 2])[]  = CGB_COMPAT_OBJ_COLORS[i]
        cast[ptr uint16](addr ppu.obj_pram[8 + i * 2])[] = CGB_COMPAT_OBJ_COLORS[i]
    else:
      # CGB cart on CGB hardware. The boot ROM's closing act is a fade of the
      # whole background palette to white, and Pan Docs states the resulting
      # handoff state outright: "All background colors are initialized as white
      # by the boot ROM." It also blesses the encoding used here — "the
      # canonical pure white is $7FFF and not $FFFF, but the hardware treats
      # both identically: it's fine to fill color RAM with $FF bytes to set it
      # to all-white."
      #
      # The OBJ half is deliberately the same fill even though it is NOT
      # specified: "In CGB mode, the boot ROM leaves all object colors
      # uninitialized (and thus somewhat random/unreliable), aside from setting
      # the first byte of OBJ0 color #0 to $00, which is unused." Undefined on
      # hardware still has to be *something* here — a savestate and a rollback
      # both have to reproduce it — so it gets the documented-safe white rather
      # than a random fill, and any cart that reads an OBJ colour it never
      # wrote is relying on garbage on real hardware too.
      #
      # Skipping this is not cosmetic: a native-CGB cart that leans on the boot
      # ROM's palette renders through an all-zero one, i.e. a black screen.
      # BullyGB is exactly that cart — its only palette write anywhere is BG
      # palette 0 colour 3 (`rBCPS = BCPSF_AUTOINC | 6`, then two zero bytes to
      # rBCPD), so colours 0-2 have to arrive from the boot ROM.
      for i in 0 ..< ppu.pram.len: ppu.pram[i] = 0xFF
      for i in 0 ..< ppu.obj_pram.len: ppu.obj_pram[i] = 0xFF
  elif gb.boot_model in {bmDmgABC, bmMgb}:
    # Pan Docs, "Console state after boot ROM hand-off" (values recorded at
    # PC = $0100): DMG/MGB hand off with STAT = $85 and LY = $00. Mode 1 with
    # LY reading 0 happens exactly once per frame — on line 153, where LY snaps
    # back to 0 four dots in — so the handoff is inside VBlank's last line, not
    # at the top of line 0, and the LCD has been on since the boot logo (so no
    # first_line quirk). $85's bit 2 is the LYC=LY that seeds from LYC = 0.
    #
    # WHICH dot of line 153 is a property of the boot ROM's length, and it is
    # calibrated the same way the two phases above are — by the ROMs that read
    # the PPU a known number of M-cycles after $0100. Two GBMicrotest families
    # are exactly that instrument, and between them the answer is one dot wide:
    #
    #  * poweron_* — 45 ROMs that pad with N NOPs and then read STAT / LY / OAM
    #    / VRAM. One seed has to satisfy all of them at once: line 0's first
    #    mode-2 M-cycle lands 7 NOPs in (poweron_stat_007 = $86), the line 0->1
    #    advance 114 M-cycles later (poweron_ly_119/_120), and the OAM and VRAM
    #    locks bracket both of mode 3's edges (poweron_oam_069/_070,
    #    poweron_vram_025/_026). They resolve the seed to the M-cycle: 397..400.
    #  * mooneye acceptance/ppu/hblank_ly_scx_timing-GS closes it mod 4. The
    #    PPU's dot grid sits at a fixed offset against the CPU's M-cycle grid
    #    (one clock drives both), and that ROM is what fixes the offset — it is
    #    also what fixes LCD_ON_HEAD_START at 1 mod 4. 397 is the member of the
    #    window that carries it, so the seed and the LCD-enable seed describe
    #    the same machine rather than two.
    #
    # The GBMicrotest hblank_int_scx0..7 family measures the same thing at DOT
    # resolution (sweeping SCX walks the mode 3 -> 0 edge across an M-cycle a
    # dot at a time) and asks for 399 instead: 12 of its rows want the PPU two
    # dots later against the CPU than 397 puts it. That is not this constant's
    # to give. Seeding 399 does buy those 12 and costs hblank_ly_scx_timing-GS
    # itself, its wilbertpol twin, four intr_2_mode0_scx*_timing_nops rows and
    # 28 gambatte rows (halt, m0enable, oam_access, vram_m3, window) — the same
    # single-dot residual the STAT_READ_LAG write-up is about, moved onto the
    # boot seed. Neither of that write-up's two candidate models absorbs it
    # either: the whole (D, L) grid was swept against this seed at 397 and at
    # 399 and no cell buys those 12 rows without spending more elsewhere.
    # Where the two families disagree, the phase that reproduces both suites'
    # steady-state timing wins over the one that reproduces this ROM's.
    ppu.ly = 0             # line 153, past the LY snapback
    ppu.cycle_counter = int32(DMG_BOOT_PHASE)
    ppu.lcd_status = (ppu.lcd_status and not 3'u8) or 1'u8  # mode 1
    when STAT_IRQ_SPLIT:
      ppu.irq_mode = 1
      ppu.irq_ly = ppu.ly
    ppu.first_line = false
    when LCD_ON_TRIM_ANY: ppu.lcdon_lines = 0
  elif gb.boot_model == bmDmg0:
    # The DMG0 boot ROM hands off at a different LCD phase than DMG-ABC
    # (which uses the ly=0/cc=0 default above): mooneye boot_hwio-dmg0 reads
    # STAT mid-mode-3 of line 1 / LY=1 shortly after handoff, which places
    # the handoff itself mid-VBlank. Seed found by sweeping that ROM's
    # passing window, 540..708, and taking the center (same method as the
    # per-model DIV seeds in timer.nim).
    const phase = 624  # dots past the start of VBlank (line 144)
    ppu.ly = uint8(144 + phase div 456)
    ppu.cycle_counter = int32(phase mod 456)
    ppu.lcd_status = (ppu.lcd_status and not 3'u8) or 1'u8  # mode 1
    when STAT_IRQ_SPLIT:
      ppu.irq_mode = 1
      ppu.irq_ly = ppu.ly
    ppu.first_line = false
    when LCD_ON_TRIM_ANY: ppu.lcdon_lines = 0

# Bit 7 of GbPpu.read_mode: LY advanced during the M-cycle a read belongs to.
const LY_JUST_CHANGED* = 0x80'u8

# ---- LCDC helpers ----
proc lcd_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_control and 0x80) != 0

const DOTS_PER_FRAME* = 70224   # 154 lines x 456 dots
# Turning the LCD back on pushes a frame straight away once this much time has
# gone by since the last one, so the panel's output rate survives the gap.
#
# This threshold is a frontend-pacing rule, not a hardware one, and it is worth
# being precise about which: with the PPU off there is no LCD refresh at all
# (the panel just relaxes to white), so hardware has no "frame" to emit and Pan
# Docs defines none. What hardware does define is what happens on re-enable —
# the PPU restarts at the top of line 0, so the next drawn frame's VBlank is
# 144*456 = 65664 dots away — and left alone that stretches the gap between two
# consecutive presents past one frame period, which a frame-paced frontend sees
# as a dropped frame forever after. SameBoy solves it the same way and with the
# same number (Core/memory.c, GB_IO_LCDC: `cycles_since_vblank_callback >
# 10 * 456` -> GB_VBLANK_TYPE_ARTIFICIAL), which is what makes the two agree
# frame-for-frame across LCD toggling; see tools/gbfuzz/sameboy_fps.c. mGBA
# picks the other option and lets the frame run long instead.
const LCD_ON_FRAME_DOTS* = 10 * 456

when defined(gb_dot_counter):
  # Diagnostic frame-pacing instrumentation (tools only; compiled out of every
  # shipping build). gb_total_dots is the panel's dot clock — 4194304 Hz, never
  # scaled by CGB double speed — so frames-per-emulated-second is
  # presents / (gb_total_dots / 4194304).
  var gb_total_dots*: uint64
  var gb_frame_normal*: uint64    # pushed at LY=144, PPU drew it
  var gb_frame_lcd_off*: uint64   # pushed by lcd_off_frame while LCD disabled
  var gb_frame_lcd_on*: uint64    # pushed by the LCDC-enable catch-up

when defined(gb_m3_trace):
  # Diagnostic mode-3 trace (tools only; compiled out of every shipping build).
  # `-d:gb_m3_trace -d:GB_TRACE_LY=n` prints one line per mode-3 dot of line n
  # plus every LCDC write that lands inside that line's mode 3, which is what
  # turns a mid-scanline-write reference image into a solvable equation: the
  # write's dot on one side, the fetcher step that consumed it on the other.
  # See the KNOWN RESIDUAL note in fifo_ppu.nim for the measurement it produced.
  #
  # `-d:GB_TRACE_LY=-1` traces EVERY drawn line instead of one. A mealybug m3_*
  # ROM sweeps its object's OAM X down the screen, so what its reference frame
  # brackets is one measurement per 8-line band and not one line -- reading it
  # needs all 144 of them in one run.
  const GB_TRACE_LY* {.intdefine.} = 20
  template gb_traced*(ly: untyped): bool = GB_TRACE_LY < 0 or int(ly) == GB_TRACE_LY

when defined(gb_m3_len):
  # Diagnostic mode-3 LENGTH trace (tools only; compiled out of every shipping
  # build). One line per drawn scanline: the measured mode 3 duration in dots
  # next to the inputs Pan Docs' "Mode 3 length" section says decide it (SCX,
  # WX/WY, and the OBJ X list in fetch order). Scoring the two against each
  # other offline is what turns the gambatte sprites m3stat rows -- which only
  # bracket the end of mode 3 to one M-cycle -- into a per-object dot count.
  var gb_m3_len_lines*: int = 1_000_000

proc ppu_blank_frame*(ppu: GbPpu; gb: GB) =
  ## Push a frame the PPU did not draw: the panel shows white with the PPU
  ## switched off.
  let blank = if gb.cgb_enabled: 0x7FFF'u16 else: DMG_COLORS[0]
  for i in 0 ..< ppu.framebuffer.len: ppu.framebuffer[i] = blank
  ppu.frame = true
  ppu.dots_since_frame = 0

proc lcd_off_frame*(ppu: GbPpu; gb: GB) {.inline.} =
  ## Drive frame output while the LCD is disabled. The panel shows white with
  ## the PPU switched off, but the frontend still needs frames at the usual
  ## rate to keep running; a game that turns the LCD off
  ## to bulk-load VRAM must not stop producing frames. Without this, step_frame
  ## (which runs until ppu.frame is set) makes no progress for as long as the
  ## LCD is off — the emulator drops those frames and, for a game that idles
  ## with the LCD off, never returns at all.
  if ppu.dots_since_frame >= DOTS_PER_FRAME:
    when defined(gb_dot_counter): inc gb_frame_lcd_off
    ppu_blank_frame(ppu, gb)
proc window_tile_map*(ppu: GbPpu): uint8 {.inline.} = ppu.lcd_control and 0x40
proc window_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_control and 0x20) != 0

# The one `lx` either window rule can fire on is cached on GbFifoPpu (see
# GbFifoPpu.win_lx) so the shifter can test for it with a single compare per
# mode 3 dot. Every register write below that feeds it re-derives it; this is
# the forward declaration, the body is in fifo_ppu.nim, which gb.nim includes
# after this file.
proc fifo_arm_window*(ppu: GbFifoPpu)

# The mixer stage runs one dot behind the FIFO pop, so a mid-mode-3 write to a
# register the MIXER reads still reaches the pixel already emitted. Forward
# declaration for the same reason as the line above; the body and the
# measurement that pins it are at fifo_recompose_last in fifo_ppu.nim.
proc fifo_recompose_last*(ppu: GbFifoPpu; gb: GB; back: int32) {.noinline.}
proc fifo_recompose_at*(ppu: GbFifoPpu; gb: GB; back: int32) {.noinline.}

template mixer_write_repaint(gb: GB; back: int32) =
  ## Every register write below that the mixer reads ends with this. `back` is
  ## how many stages of the mixer tail the register is read at the far end of
  ## (see fifo_recompose_last), minus the CGB's own dot of write latency.
  ## `-d:MIXER_DOT_LAG=0` compiles the mixer's dot out entirely -- this call,
  ## the two stores in the shifter and the held pair with it -- which is the
  ## control arm for both the A/B measurements at fifo_recompose_last and the
  ## retired-instruction count.
  when MIXER_DOT_LAG != 0:
    if gb.fifo_ppu != nil:
      let n = back - (if gb.cgb_enabled: int32(CGB_MIXER_LATENCY) else: 0'i32)
      if n > 0: fifo_recompose_last(gb.fifo_ppu, gb, n)

proc bg_window_tile_data*(ppu: GbPpu): uint8 {.inline.} = ppu.lcd_control and 0x10
proc bg_tile_map*(ppu: GbPpu): uint8 {.inline.} = ppu.lcd_control and 0x08
proc sprite_height*(ppu: GbPpu): int {.inline.} =
  if (ppu.lcd_control and 0x04) != 0: 16 else: 8
proc sprite_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_control and 0x02) != 0
proc bg_display*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_control and 0x01) != 0

# ---- CPU access windows for VRAM and OAM ----
#
# The PPU takes VRAM away from the CPU for the whole of mode 3 and OAM for
# modes 2 and 3; a blocked read returns 0xFF and a blocked write is dropped.
# WHEN each edge lands, to the M-cycle, is what mooneye
# acceptance/ppu/lcdon_timing-GS and lcdon_write_timing-GS pin, and the three
# edges do not all line up with the STAT mode bits:
#
#   * The locks CLOSE on the live mode -- OAM one M-cycle before STAT reads
#     back mode 2 at the top of a line, VRAM one M-cycle before STAT reads back
#     mode 3 -- because it is the STAT mode bits that are late, not the locks.
#   * They OPEN with the STAT bits (the `read_mode` latch), one M-cycle after
#     mode 3 really ends.
#   * A write and a read in the same M-cycle are NOT asked at the same point.
#     A write's byte is applied before that M-cycle's PPU dots (mem_write), so
#     it asks with the mode at the START of the M-cycle -- the live mode as of
#     the call. A read is answered after the dots, so it asks with both the
#     latched mode (`read_mode`, again the mode at the start) and the live one,
#     and any lock closed at either end refuses it. That is what makes an OAM
#     write land on the last M-cycle of mode 2 while an OAM read in the same
#     M-cycle is refused.
#
#     The one thing a write still cannot answer from the start of its M-cycle
#     is whether mode 2 ENDS inside it, and mooneye lcdon_write_timing-GS says
#     that M-cycle's OAM write lands. Mode 2 always ends at dot 80, so the
#     M-cycle's own dot span answers it -- see cpu_oam_open.
#   * On the first line after the LCD is switched on the PPU's dot grid sits
#     2 T-cycles off the CPU's M-cycle grid (see the LCDC-enable write), so
#     every edge on that line rounds to the same M-cycle as the STAT bits do.
#     One line, one flag: `first_line` selects the latched mode for both.
proc cpu_vram_open*(ppu: GbPpu; is_write: bool): bool {.inline.} =
  if not lcd_enabled(ppu): return true
  if is_write:
    # A write is applied BEFORE its M-cycle's dots (see mem_write), so the live
    # mode here already IS the mode at the start of that M-cycle -- the same
    # value read_mode carries once the dots have run. Byte for byte the rule
    # this used to spell as `read_mode != 3`, evaluated at the write's own
    # commit point instead of one M-cycle after it.
    return (ppu.lcd_status and 3'u8) != 3
  if (ppu.read_mode and 3'u8) == 3: return false
  if ppu.first_line: return true
  (ppu.lcd_status and 3'u8) != 3

const OAM_WRITE_M2_TAIL {.intdefine.} = 1
  ## Whether an OAM write is still admitted on the M-cycle mode 2 ends in.
  ##
  ## Pan Docs says OAM belongs to the PPU for the whole of modes 2 and 3, which
  ## is what 0 spells; the exception is a measured one and it is not optional.
  ## Turning it off costs mooneye acceptance/ppu/lcdon_write_timing-GS outright
  ## and takes GBMicrotest 349 -> 347 (oam_write_l1_c and two others), so the
  ## last M-cycle of mode 2 really does still take an OAM write.

proc cpu_oam_open*(ppu: GbPpu; is_write: bool; mcycle_dots: int32 = 0): bool {.inline.} =
  if not lcd_enabled(ppu): return true
  let live = ppu.lcd_status and 3'u8
  if is_write:
    # Same sample point as the VRAM write above: the live mode here is the mode
    # at the start of the write's own M-cycle.
    if live == 3: return false
    # The first line's OAM scan does not lock OAM at all (it is also the mode
    # that STAT reports as 0 -- see ppu_read 0xFF41).
    if ppu.first_line: return true
    when OAM_WRITE_M2_TAIL != 0:
      if live == 2:
        # The one place a write still outlives the mode it starts in, and the
        # only thing in either lock that the start of an M-cycle cannot answer
        # on its own. The OAM scan releases the bus at dot 80 while the CPU's
        # write strobe is still to come, so the write lands; mode 2 ALWAYS ends
        # at dot 80, so "does this M-cycle span dot 80" is the same question,
        # and it is what the old post-tick rule was reading off the mode when
        # it asked `live != 2` after the dots had run. mcycle_dots is 4, or 2 in
        # double speed -- the caller has the speed, this does not.
        #
        # Exact for the FIFO renderer, whose dot counter runs 1..80 across mode
        # 2 and stops at 80 on the M-cycle that ends it. The scanline renderer
        # subtracts 80 on that same M-cycle instead, so it can answer one
        # M-cycle early at the boundary; it is the opt-in fast path (GB.fifo)
        # and does not model this edge at dot resolution anyway.
        return ppu.cycle_counter + mcycle_dots > 80
      return true
    else:
      return live != 2
  let lag = ppu.read_mode and 3'u8
  if lag == 3: return false
  if ppu.first_line: return true
  lag != 2 and live != 2 and live != 3

# ---- The DMG OAM corruption bug -------------------------------------------
#
# Pan Docs, "OAM Corruption Bug". The 16-bit increment/decrement unit is wired
# straight to the address bus, so an `inc rr` / `dec rr` puts its OPERAND (the
# value BEFORE the operation) out as an address even though no read or write is
# asserted. If that address is in $FE00-$FEFF while the PPU owns OAM, the
# access lands on the OAM scan and scrambles it.
#
# The whole of it is driven from the INSTRUCTIONS, not from the memory path.
# Every instruction that can put an OAM address on the bus knows that address
# already, and it knows on which of its own M-cycles each access falls, so each
# call site names both. That keeps the CPU's OAM read/write LOCK (cpu_oam_open,
# where gambatte oam_access and mooneye bits/mem_oam are won) completely
# untouched: a blocked read still answers $FF and a blocked write is still
# dropped, and the corruption is the separate side effect it is on hardware.
# It also keeps every test out of mem_read/mem_write, which are the two hottest
# procs in the emulator.
#
# The per-instruction classification, from Pan Docs' "Affected Operations", is:
#
#   inc/dec rr        M2: write, operand rr           (the bare IDU step)
#   ld [hl+/-],a      M2: write, address hl           (store and IDU step in
#                          one M-cycle -- "behaves just like a single write")
#   ld a,[hl+/-]      M2: read+write, address hl      (load and IDU step)
#   push rr, call,    M2: write, operand sp
#     rst, interrupt  M3: write, address sp-1         (store and IDU step)
#                     M4: write, address sp-2
#   pop rr, ret       M2: read+write, address sp      (load and IDU step)
#                     M3: read, address sp+1
#
# The one place that is a genuine choice rather than a reading: Pan Docs says
# POP triggers the bug three times rather than four, "one read, one glitched
# write, and another read without a glitched write", without saying which of
# the two SP steps loses its write. The table above puts it on the second,
# because that is what 2-causes ("LD SP,$FDFF : POP BC" must corrupt, and only
# its second M-cycle touches OAM at all) and 3-non_causes ("LD SP,$FDFE : POP
# BC" must not) leave once 8-instr_effect's POP pattern has to match too.
#
# NOT modelled: PC in OAM. Pan Docs says executing from $FE00-$FEFF triggers
# the bug twice per fetch. Hooking cpu_inc_pc is a test on the single hottest
# path in the interpreter to buy a case no test ROM and no commercial title
# reaches.
#
# The corruption patterns themselves: OAM is 20 rows of 8 bytes (four 16-bit
# words each, because OAM has a 16-bit data bus), and mode 2 reads one row per
# M-cycle, so the row is the M-cycle's index into mode 2. Every operand of
# every formula below sits at the same byte position inside its own word, so
# the 16-bit expressions are applied byte by byte and OAM's word endianness
# never comes into it. Pan Docs states three patterns and this implements all
# three, verbatim; which one a given M-cycle gets is the OamBugKind the caller
# passes, and that is decided per instruction (see OamBugKind).
type OamBugKind* = enum
  obWrite      ## a write, or a write and an IDU step in the same M-cycle
               ## ("this case behaves just like a single write")
  obRead       ## a read with no IDU step in the same M-cycle
  obReadWrite  ## a read and an IDU step in the same M-cycle

proc oam_bug_write_corrupt(ppu: GbPpu; row: int) =
  ## "Write Corruption": the first word of the row becomes
  ## `((a ^ c) & (b ^ c)) ^ c` where a is that word, b the first word and c the
  ## THIRD word of the preceding row; the other three words are copied from the
  ## preceding row.
  let dst = row shl 3
  let src = dst - 8
  for i in 0 .. 1:
    let a = ppu.sprite_table[dst + i]
    let b = ppu.sprite_table[src + i]
    let c = ppu.sprite_table[src + 4 + i]
    ppu.sprite_table[dst + i] = ((a xor c) and (b xor c)) xor c
  for i in 2 .. 7:
    ppu.sprite_table[dst + i] = ppu.sprite_table[src + i]

proc oam_bug_read_corrupt(ppu: GbPpu; row: int) =
  ## "Read Corruption": as the write corruption, with `b | (a & c)` for the
  ## first word instead.
  let dst = row shl 3
  let src = dst - 8
  for i in 0 .. 1:
    let a = ppu.sprite_table[dst + i]
    let b = ppu.sprite_table[src + i]
    let c = ppu.sprite_table[src + 4 + i]
    ppu.sprite_table[dst + i] = b or (a and c)
  for i in 2 .. 7:
    ppu.sprite_table[dst + i] = ppu.sprite_table[src + i]

proc oam_bug_read_write_corrupt(ppu: GbPpu; row: int) =
  ## "Read During Increase/Decrease": a read and an IDU write in one M-cycle.
  ## Pan Docs: it does not happen at all for the first four rows or the last
  ## one; otherwise the first word of the PRECEDING row becomes
  ## `(b & (a | c | d)) | (a & c & d)` -- a the first word two rows before the
  ## accessed one, b the first word of the preceding row (the one being
  ## corrupted), c the first word of the accessed row, d the third word of the
  ## preceding row -- and the preceding row is then copied, corrupted first
  ## word and all, both onto the accessed row and onto the row two before it.
  ## A normal read corruption is then applied on top, whether or not this ran;
  ## the caller does that part.
  if row < 4 or row >= 19: return
  let cur = row shl 3
  let pre = cur - 8
  let two = cur - 16
  for i in 0 .. 1:
    let a = ppu.sprite_table[two + i]
    let b = ppu.sprite_table[pre + i]
    let c = ppu.sprite_table[cur + i]
    let d = ppu.sprite_table[pre + 4 + i]
    ppu.sprite_table[pre + i] = (b and (a or c or d)) or (a and c and d)
  for i in 0 .. 7:
    let v = ppu.sprite_table[pre + i]
    ppu.sprite_table[cur + i] = v
    ppu.sprite_table[two + i] = v

proc oam_bug_access*(gb: GB; kind: OamBugKind) {.noinline.} =
  ## One access into the OAM page from the CPU's side of the bus. The caller
  ## has already established that the address is in $FE00-$FEFF; everything
  ## else is decided here, out of line, so the inlined half of the check is a
  ## compare and a not-taken branch.
  ##
  ## DMG-family only: Pan Docs, "Game Boy Color and Advance are not affected by
  ## this bug, even when running monochrome software", so the test is on the
  ## console (boot_model, what console_is_cgb reads) and not on cgb_enabled,
  ## which a DMG cart in compatibility mode clears.
  if gb.boot_model in {bmCgb0, bmCgbABCDE, bmAgb}: return
  let ppu = gb.ppu
  if not lcd_enabled(ppu): return
  when defined(gb_oam_trace):
    # -d:gb_oam_trace prints every OAM-address bus event the LCD is on for, in
    # or out of mode 2. This is what located the row phase: run blargg's
    # 4-scanline_timing under it and the last two lines are the M-cycles that
    # ROM calls "just before" and "at" the first corruption.
    echo "OAMBUG ly=", ppu.ly, " cc=", ppu.cycle_counter,
         " mode=", ppu.lcd_status and 3'u8, " fl=", ppu.first_line,
         " row=", (int(ppu.cycle_counter) + 3) shr 2, " kind=", kind
  if (ppu.lcd_status and 3'u8) != 2'u8: return
  # The first line after the LCD is switched on does not lock OAM at all (see
  # cpu_oam_open), i.e. that line's mode 2 is not a normal scan here. Whether
  # hardware corrupts on it is NOT established by any of blargg's rows -- all
  # of them place their event four frames after the LCD-on write -- so this
  # follows the lock rather than guessing the other way.
  if ppu.first_line: return
  # Which row the scan is on. cycle_counter is the dot this M-cycle starts on,
  # 1-based within the line (fifo_ppu resets it to 0 at the line end and then
  # increments before the first dot runs), and the scan reads one row per four
  # dots, so this M-cycle overlaps row `ceil(cc / 4)`. Row is always 1..19 here
  # and the two corrupt procs index at most `row * 8 + 7` = 159, so the whole
  # of it stays inside the 160-byte table without a bounds test.
  #
  # The scanline renderer restarts cycle_counter at each mode edge instead, so
  # there it reads 0, 4, ... 76 across mode 2 and the same expression puts the
  # skipped M-cycle at the START of the scan rather than the end. Same count of
  # corrupting M-cycles, one M-cycle out of phase; that renderer is the opt-in
  # fast path (GB.fifo) and is not scored against any timing suite.
  #
  # 1..19, never 0 and never 20, and BOTH ends of that are measured:
  #
  #   * 20 is the M-cycle that reaches dot 80, where the scan has already let
  #     go of OAM before the CPU's strobe -- the same edge OAM_WRITE_M2_TAIL
  #     models on the write side, and why an OAM write still lands on that
  #     M-cycle. blargg 4-scanline_timing test 5 ("just after last corruption",
  #     18+1 M-cycles past the first) says it does not corrupt.
  #   * 0 is read before the line's first CPU strobe can reach it, which is
  #     Pan Docs' "objects 0 and 1 are not affected by this bug".
  #
  # Together those two are the 19-M-cycle window 4-scanline_timing brackets at
  # +0 and +18 -- 20 M-cycles of mode 2, minus the one that runs past its end.
  #
  # WHICH absolute row each of those 19 M-cycles lands on does not follow from
  # the window's width; 0..18 would be just as wide. It is pinned separately,
  # by blargg 7-timing_effect: that ROM CRCs the whole of OAM after triggering
  # at 116 consecutive positions, and 1..19 is the assignment that produces its
  # $7D792E7C. (7-timing_effect is not one of the shootout's 261 rows --
  # upstream has it commented out -- but blargg's combined oam_bug.gb runs it
  # and reports 07:ok, and the standalone ROM matches its own reference.)
  let row = (int(ppu.cycle_counter) + 3) shr 2
  if row <= 0 or row >= 20: return
  when defined(gb_oam_trace): echo "  -> corrupt row ", row
  case kind
  of obWrite: oam_bug_write_corrupt(ppu, row)
  of obRead:  oam_bug_read_corrupt(ppu, row)
  of obReadWrite:
    oam_bug_read_write_corrupt(ppu, row)
    oam_bug_read_corrupt(ppu, row)

template oam_bug_if*(gb: GB; address: uint16; kind: OamBugKind) =
  ## The inlined half: does this M-cycle put an OAM address on the bus?
  if (address and 0xFF00'u16) == 0xFE00'u16: oam_bug_access(gb, kind)

# ---- STAT helpers ----
proc coincidence_interrupt_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_status and 0x40) != 0
proc oam_interrupt_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_status and 0x20) != 0
proc vblank_stat_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_status and 0x10) != 0
proc hblank_interrupt_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_status and 0x08) != 0
proc coincidence_flag*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_status and 0x04) != 0
proc `coincidence_flag=`*(ppu: GbPpu; on: bool) {.inline.} =
  if on: ppu.lcd_status = ppu.lcd_status or 0x04
  else:  ppu.lcd_status = ppu.lcd_status and not 0x04'u8
proc mode_flag*(ppu: GbPpu): uint8 {.inline.} = ppu.lcd_status and 0x03

proc stat_irq_lead*(gb: GB): int32 {.inline.} =
  ## How far ahead of the mode flag the STAT interrupt line runs, in dots.
  ## STAT_IRQ_LEAD is in CPU M-cycles, and one M-cycle is 4 dots at normal
  ## speed and 2 in double speed (Pan Docs, "Dots").
  when STAT_IRQ_SPLIT: int32(STAT_IRQ_LEAD) * int32(4 shr gb.memory.current_speed)
  else: 0'i32

proc stat_read_mode*(ppu: GbPpu): uint8 {.inline.} =
  ## The mode bits a CPU read of STAT returns: the mode in effect during the
  ## dot STAT_READ_LAG back from the last dot of the reading M-cycle.
  ##
  ## At the shipping L = 3 that dot is the first of the M-cycle, which is what
  ## the tick already latched into `read_mode` for the CPU's VRAM/OAM locks.
  ## Any other L needs the hold: a mode change stays visible to a read while
  ## `cycle_counter <= stat_hold_until`, where mode_flag= set that to the
  ## change's own dot + 1 + L (the change applies from the NEXT dot, and a read
  ## samples L dots back from where its M-cycle leaves the counter). Nothing
  ## per-tick maintains it -- the line wrap rebases it and 0 means "no hold".
  when STAT_READ_HOLD:
    if ppu.cycle_counter <= ppu.stat_hold_until: ppu.stat_hold_mode
    else: ppu.lcd_status and 3'u8
  else:
    ppu.read_mode and 3'u8

# The dot within line 143 at which CGB raises the line-144 mode 2 STAT source.
# See m2_line144 below: 456 - 4 dots, i.e. one M-cycle before the line ends.
const M2_144_EARLY_DOT* = 452'i32

# ---- The OAM (mode 2) STAT source is a pulse, not a level -------------------
#
# It goes high for the first four dots of a line and low again for the rest of
# mode 2, rather than tracking "the mode flag reads 2" across all 80. Two
# independent things say so before any ROM is run:
#
#   * the same source asserts once more per frame entering vblank on line 144,
#     where there is no mode 2 at all and none is coming (m2_line144, mooneye
#     vblank_stat_intr-GS/-C) -- it is tied to a line starting, not to a mode;
#   * GBMicrotest's stat_write_glitch_l{0_c,1_d,154_c} un-mask every STAT source
#     one M-cycle into mode 2 (the DMG write quirk, ppu_stat_write_glitch) and
#     hardware stays silent, while their siblings an M-cycle earlier fire.
#
# The level model only ever saw this source's RISING edge, so it was never
# contradicted: the difference is entirely in what happens when a ROM enables
# the source, or samples the line, PART-WAY THROUGH mode 2. gambatte's m2enable
# and miscmstatirq families do exactly that, several hundred times.
const STAT_M2_PULSE* {.intdefine.} = 3
  ## Last dot of a line on which the OAM STAT source is still high. -1 restores
  ## the old level-over-mode-2 model; -2 makes the pulse one CPU M-cycle rather
  ## than a fixed count of dots (see the table below for why it is not that).
  ##
  ## Width swept 2026-08-02 against the full runner (gambatte rows of 5005 /
  ## mooneye of 115 / GBMicrotest of 513), from e86cb34 -- so the gambatte
  ## column is 112 rows below today's, cb2aaa6's object penalty having landed
  ## between, but every cell is against the same tree:
  ##
  ##   width  gambatte  mooneye  micro
  ##     -1     3378      112     393   level, the old model
  ##      0     3414      112     399
  ##      1     3420      112     399
  ##      2     3420      112     399
  ##      3     3422      112     399   <- ships
  ##      4     3422      112     399   indistinguishable: nothing samples dot 4
  ##      5     3413      112     396
  ##      7     3410      112     396
  ##     -2     3421      112     399   one M-cycle, scaled by double speed
  ##
  ## +44 gambatte rows and +6 GBMicrotest at width 3 (3490 -> 3534 and
  ## 394 -> 400 on the tree this ships in), no row anywhere going the other way:
  ## m2enable 74 -> 93, miscmstatirq 245 -> 260, lycm2int 4 -> 8, lycEnable,
  ## scx_during_m3, enable_display, and GBMicrotest's oam_int_* / int_oam_* /
  ## lcdon_to_if_oam_a. The rest of the oam_int_* family stops being wrong by a
  ## whole line (0x00 vs 0x64) and becomes wrong by one M-cycle (0x65 vs 0x64),
  ## which is a different bug and not this one.
  ##
  ## DOTS, not an M-cycle. The -2 row above is the same pulse expressed as one
  ## CPU M-cycle, so 2 dots in double speed instead of 4, and it is one gambatte
  ## row worse -- three m2enable `_ds_` rows go red and two `_ds_lcdoffset1_`
  ## rows go green. That is thin evidence on its own, but it points the way the
  ## hardware argument does: this pulse is generated by the OAM scan starting,
  ## and the PPU's dot clock does not change with the CPU's speed (Pan Docs,
  ## "Dots"), so a PPU-side pulse is a fixed number of dots. The M-cycle-scaled
  ## spelling is kept reachable as -2 because those five rows are the only
  ## direct measurement of it.
proc m2_source*(ppu: GbPpu; gb: GB): bool {.inline.} =
  when STAT_M2_PULSE == -1: ppu.irq_mode_of == 2
  elif STAT_M2_PULSE == -2:
    ppu.irq_mode_of == 2 and ppu.cycle_counter < int32(4 shr gb.memory.current_speed)
  else: ppu.irq_mode_of == 2 and ppu.cycle_counter <= int32(STAT_M2_PULSE)

proc m2_line144*(ppu: GbPpu; gb: GB): bool {.inline.} =
  ## Is the mode 2 (OAM) STAT source asserted by the *start of vblank*?
  ##
  ## Besides mode 2 itself, the OAM STAT source goes high once more per frame,
  ## when the PPU enters vblank on line 144 (mooneye vblank_stat_intr). The two
  ## hardware families disagree on exactly when:
  ##
  ##   * DMG/MGB/SGB (vblank_stat_intr-GS): together with the vblank interrupt.
  ##   * CGB/AGB/AGS (misc/ppu/vblank_stat_intr-C): one M-cycle earlier.
  ##
  ## Both ROMs time the interrupt by resetting DIV a fixed number of NOPs into
  ## line 143 and reading it back in the handler. The vblank rounds bracket the
  ## DIV tick at 54/55 NOPs on every model; the STAT rounds bracket it at the
  ## same 54/55 on -GS but at 53/54 on -C, which places the CGB STAT exactly one
  ## M-cycle (4 dots) ahead of the vblank interrupt. So on CGB the source is
  ## already high for the last M-cycle of line 143, while the PPU is still in
  ## mode 0.
  ##
  ## Asked in the FLAG domain, deliberately, even though the CGB half of it is
  ## numerically the same dot the general STAT_IRQ_LEAD reaches: this pulse is
  ## pinned to the vblank interrupt, which does not lead, and on DMG it is
  ## measured to coincide with it exactly.
  if ppu.ly == 144:
    ppu.mode_flag == 1
  elif ppu.ly == 143:
    gb.cgb_enabled and ppu.mode_flag == 0 and
      ppu.cycle_counter >= M2_144_EARLY_DOT
  else:
    false

proc ppu_handle_stat_interrupt*(ppu: GbPpu; gb: GB) =
  # While the PPU is off the LY=LYC comparison clock is stopped: the coincidence
  # bit freezes at its last value and no STAT interrupt fires (mooneye
  # stat_lyc_onoff — LYC writes while off must not change the retained bit).
  if not ppu.lcd_enabled:
    return
  # The readable bit follows the readable LY; the SOURCE below follows irq_ly,
  # one M-cycle ahead of it (gambatte lycint_lycflag times the two apart).
  ppu.coincidence_flag = ppu.ly == ppu.lyc
  let stat_flag =
    (ppu.irq_ly_of == ppu.lyc and ppu.coincidence_interrupt_enabled) or
    (ppu.m2_source(gb)        and ppu.oam_interrupt_enabled) or
    # The OAM (mode 2) STAT source also asserts at the start of vblank
    # (line 144) — simultaneously with the vblank interrupt on DMG, one
    # M-cycle earlier on CGB. See m2_line144.
    (ppu.oam_interrupt_enabled and ppu.m2_line144(gb)) or
    (ppu.irq_mode_of == 0     and ppu.hblank_interrupt_enabled) or
    (ppu.irq_mode_of == 1     and ppu.vblank_stat_enabled)
  if not ppu.old_stat_flag and stat_flag:
    when defined(gb_stat_read_trace):
      echo "STATIRQ ly=", ppu.ly, " cc=", ppu.cycle_counter,
           " mode=", ppu.mode_flag
    gb.interrupts.lcd_stat_interrupt = true
  ppu.old_stat_flag = stat_flag

proc ppu_stat_write_glitch*(ppu: GbPpu; gb: GB) =
  ## The DMG STAT-write bug. Pan Docs, "Spurious STAT interrupts": "A hardware
  ## quirk in the monochrome Game Boy makes the LCD interrupt sometimes trigger
  ## when writing to STAT (including writing $00) during OAM scan, HBlank,
  ## VBlank, or LY=LYC. It behaves as if $FF were written for one M-cycle, and
  ## then the written value were written the next M-cycle. Because the GBC in
  ## DMG mode does not have this quirk, two games that depend on this quirk
  ## (Ocean's Road Rash and Vic Tokai's Xerd no Densetsu) will not run on a
  ## GBC." The hardware decides, not the cartridge — "the GBC in DMG mode does
  ## not have this quirk" is the whole sentence — so the caller gates this on
  ## `not cgb_enabled` (the console) and NOT on cgb_native (the mode). Those two
  ## were the same variable until DMG-compatibility mode became a thing dingbat
  ## could be in, and a DMG cart booted through a real CGB boot ROM used to end
  ## up here.
  ##
  ## $FF in the enable bits selects every source at once, so the quirk does not
  ## invent a condition — it un-masks whichever one the PPU is already in, and
  ## the STAT line goes high for that one M-cycle. An edge out of it is an
  ## interrupt; holding old_stat_flag high for the rest of the M-cycle is the
  ## other half of the same statement (a source that comes up inside the window
  ## finds the line already high, so it is not a second edge).
  ##
  ## WHERE the window sits is what GBMicrotest's stat_write_glitch_l* rows
  ## measure, and they put it at the write's own commit point rather than at the
  ## M-cycle boundary the store lands on: l1_a and l143_a write on the M-cycle
  ## the mode 3 -> 0 edge falls inside, and hardware stays silent, so the mask
  ## was already gone before mode 0 arrived. That is where every other CPU write
  ## commits (mem_write), and it is also exactly Pan Docs' "one M-cycle, and
  ## then the written value the next": the $FF is the write's data on the bus,
  ## and the deferred store (ppu_defer_machinery_write) is the M-cycle behind it.
  ##
  ## The OAM source is deliberately not in the set. Pan Docs lists OAM scan, but
  ## three of these ROMs write one M-cycle into mode 2 (l0_c, l1_d, l154_c, all
  ## at dot 1 of a line with LY != LYC) and hardware stays silent, while the
  ## siblings one M-cycle earlier — whose M-cycle starts in the previous line's
  ## mode 0 — fire.
  ##
  ## That reading was right about the shape and the source IS a pulse now (see
  ## m2_source), but the pulse is four dots wide, not one, so it is still high
  ## at dot 1 and putting it back in this set does not work: measured
  ## 2026-08-02, `m2_source(gb)` added here costs gambatte 3422 -> 3411 (all of
  ## it m2enable) and GBMicrotest 399 -> 395, i.e. these three rows are bought
  ## and eleven others sold. Narrowing the pulse to one dot to make the two
  ## agree costs the same 8 m2enable rows from the other side (3414/399). So
  ## the two instruments genuinely disagree about the width at their own sample
  ## points, this stays an exception, and the m2_source sweep is where to
  ## re-open it.
  if not ppu.lcd_enabled: return
  if ppu.old_stat_flag: return
  if ppu.ly == ppu.lyc or ppu.mode_flag == 0 or ppu.mode_flag == 1:
    when defined(gb_stat_read_trace):
      echo "STATGLITCH ly=", ppu.ly, " cc=", ppu.cycle_counter,
           " mode=", ppu.mode_flag
    gb.interrupts.lcd_stat_interrupt = true
    ppu.old_stat_flag = true

proc ppu_flush_stat_write*(ppu: GbPpu; gb: GB) =
  ## Take the STAT interrupt edge a CPU write to LCDC/STAT/LYC left pending.
  ## mem_write calls this on the M-cycle boundary that follows the write; the
  ## handful of write_byte callers that are not a CPU M-cycle at all (the
  ## post-boot register table, the cheat engine's RAM pokes) call it directly
  ## so nothing can carry a pending edge into an unrelated M-cycle.
  if ppu.stat_write_pending:
    ppu.stat_write_pending = false
    ppu_handle_stat_interrupt(ppu, gb)

proc ppu_copy_hdma_block*(ppu: GbPpu; gb: GB): bool =
  ## One $10-byte block, from wherever the address counters currently stand.
  ## Returns false if the transfer cannot go on, i.e. the destination counter
  ## overflowed off the top of the address space.
  #
  # "Only bits 12-4 are respected; others are ignored" and "the upper 3 bits are
  # ignored (destination is always in VRAM)" -- Pan Docs, FF53-FF54. That is a
  # mask on the address the counter DRIVES, not on the counter: the counter is
  # a full 16 bits, and gambatte's dma_dst_wrap pair is what separates the two.
  # Both of its ROMs put the destination at $9FF0 and copy two blocks, and they
  # differ only in a bit of HDMA3 that the VRAM address cannot see ($DF vs $FF).
  # The $DF one wraps its second block round to $8000; the $FF one, whose
  # counter would step off $FFF0, does not transfer it at all -- "if the
  # transfer's destination address overflows, the transfer stops prematurely".
  # (What that leaves in the registers is stated as uninvestigated there; this
  # simply stops, so FF55 reads back as inactive with the length it reached.)
  #
  # Both ends are resolved once, before the loop: the block is 16 aligned bytes,
  # and nothing it does -- a read anywhere, a write inside VRAM -- can reach the
  # counters. (Re-reading them per byte is also what the per-byte cost of a
  # heavy HDMA title is made of; this is ~0.15% of Pokemon Crystal.)
  let src_base = int(ppu.hdma_src)
  let dst_base = 0x8000 or int(ppu.hdma_dst and 0x1FF0'u16)
  # Pan Docs, FF51-FF52: the source is "$0000-$7FF0 or $A000-$DFF0" -- the
  # cartridge and WRAM, and nothing else. A block outside that range does not
  # read at all; the transfer moves the open bus, $FF. gambatte's dma_hiram_read
  # / dma_oam_read / dma_vram_read point the source at $FF80, $FE00 and $9000
  # and assert the destination does NOT match the source, and its companion
  # dma_hiram_read_result subtracts $FE from the byte that landed and prints 1 --
  # so the byte is $FF, measured rather than chosen. Decided once per block, not
  # per byte: HDMA2 masks the low nibble away, so a block is 16 aligned bytes and
  # cannot straddle a region boundary.
  let src_legal = src_base < 0x8000 or (src_base >= 0xA000 and src_base < 0xE000)
  for byte in 0 ..< 0x10:
    gb.memory.write_byte(gb, dst_base + byte,
      if src_legal: gb.memory.read_byte(gb, src_base + byte) else: 0xFF'u8)
    mem_tick_components(gb.memory, gb, 2, from_cpu = false, ignore_speed = true)
  # The source is the one that wraps rather than stops (dma/dma_src_wrap copies
  # its second block from $0000 after the first read $FFF0).
  ppu.hdma_src = ppu.hdma_src + 0x10
  let dst_overflow = ppu.hdma_dst == 0xFFF0'u16
  ppu.hdma_dst = ppu.hdma_dst + 0x10
  ppu.hdma5 = ppu.hdma5 - 1
  not dst_overflow

proc ppu_step_hdma*(ppu: GbPpu; gb: GB) =
  # The block copy ticks the PPU, which can drive another mode change; without
  # this guard a nested transition back into mode 0 re-enters the copy and
  # recurses until the stack overflows.
  if ppu.hdma_copying: return
  ppu.hdma_copying   = true
  ppu.hdma_block_due = false
  let may_continue = ppu_copy_hdma_block(ppu, gb)
  if ppu.hdma5 == 0xFF or not may_continue: ppu.hdma_active = false
  ppu.hdma_copying = false

when STAT_IRQ_SPLIT:
  proc ppu_set_irq_mode*(ppu: GbPpu; gb: GB; mode: uint8) {.inline.} =
    ## Move the STAT interrupt line's copy of the mode, STAT_IRQ_LEAD M-cycles
    ## before the flag follows. Only the sources move; nothing the CPU reads
    ## back does.
    if ppu.irq_mode != mode:
      ppu.irq_mode = mode
      ppu_handle_stat_interrupt(ppu, gb)

proc `mode_flag=`*(ppu: GbPpu; mode: uint8; gb: GB) =
  let prev_mode = ppu.mode_flag
  if ppu.first_line and ppu.mode_flag == 0 and mode == 2: ppu.first_line = false
  if mode == 1: ppu.window_trigger = false
  # The WY condition, half of it: Pan Docs says the window is drawn once
  # "WY == LY at any point in the frame", so the comparator is a level and the
  # latch it feeds is per frame -- cleared entering V-Blank above, set here at
  # the top of every visible line. The other half is the WY write itself (see
  # ppu_write $FF4A): those two are the ONLY events that can make LY == WY
  # newly true, so between them they are the whole level, at no per-dot cost.
  #
  # Testing it here rather than at the mode 2 -> 3 edge is what
  # gambatte window/arg/late_wy_1 vs late_wy_2 measure: one writes WY = $FF at
  # the end of line 153 and gets no window, the other writes it at dot 1 of
  # line 0 and gets one, so a WY of 0 is already latched by dot 1 of line 0.
  elif mode == 2 and ppu.ly == ppu.wy:
    when defined(gb_win_trace):
      echo "WYLATCH ly=", ppu.ly, " wy=", ppu.wy, " dot=", ppu.cycle_counter
    ppu.window_trigger = true
    if gb.fifo_ppu != nil: fifo_arm_window(gb.fifo_ppu)
  when STAT_READ_HOLD:
    if mode != prev_mode:
      # The change applies from the NEXT dot, so a read sampling this dot or
      # earlier still reports the old mode. See stat_read_mode.
      ppu.stat_hold_mode  = prev_mode
      ppu.stat_hold_until = ppu.cycle_counter + 1 + STAT_READ_LAG
  ppu.lcd_status = (ppu.lcd_status and 0b1111_1100'u8) or mode
  when STAT_IRQ_SPLIT:
    # The irq domain should already be here (it led by STAT_IRQ_LEAD); this is
    # the catch-up for the paths that do not lead it at all -- the LCD-off
    # tick, a speed switch that stepped over the lead's dot -- and a no-op
    # otherwise.
    ppu.irq_mode = mode
  ppu_handle_stat_interrupt(ppu, gb)
  # The HBlank DMA step must run AFTER lcd_status reflects mode 0: the block
  # copy ticks the PPU (mem_tick_components in ppu_copy_hdma_block), and a
  # nested tick that still observes mode 3 re-enters the FIFO renderer's
  # level-triggered `lx >= GB_WIDTH` mode-0 transition and recurses until the
  # stack overflows (Pokemon Crystal crashed at boot). With the status updated
  # first, nested ticks dispatch to the mode-0 branch and simply advance the
  # HBlank dot counter while the copy is in flight.
  #
  # One block per *entry* into HBlank, and only while the LCD is driving the
  # modes. The disabled-LCD path re-asserts mode 0 on every tick, so a
  # level-triggered step ran a block per tick and never terminated (Kirby
  # Tilt 'n' Tumble crashed the process this way); with the LCD off there are
  # no HBlank periods for an armed transfer to advance on.
  #
  # The block is owed to this HBlank, but it is the CPU's bus it takes it on:
  # "Upon halting the CPU (using the halt instruction), the transfer will also
  # be halted and will be resumed only when the CPU resumes execution" (Pan
  # Docs, FF55, citing MagenTests' hblank_vram_dma -- the ROM this tree scores).
  # So while the CPU is halted the block only becomes DUE, and cpu.tick hands it
  # the bus at the moment the halt ends -- if the machine is still in the HBlank
  # that owed it. Leave mode 0 with the CPU still halted and that line's block is
  # simply not transferred (gambatte dma/hdma_m3halt_m1unhalt_hdma5 halts across
  # the rest of a frame and finds the length untouched). That "still in mode 0"
  # is tested where the debt is PAID rather than cleared here on the way out,
  # which is the same rule -- every mode 0 entered in the meantime would have
  # re-armed the flag anyway -- and keeps this line, which every mode change in
  # the machine runs through, exactly the shape it was.
  if mode == 0 and prev_mode != 0 and ppu.hdma_active and ppu.lcd_enabled:
    if gb.cpu.halted: ppu.hdma_block_due = true
    else:             ppu_step_hdma(ppu, gb)

proc ppu_update_palette*(palette: var array[4, uint8]; val: uint8) =
  palette[0] = val and 0x3
  palette[1] = (val shr 2) and 0x3
  palette[2] = (val shr 4) and 0x3
  palette[3] = (val shr 6) and 0x3

proc ppu_palette_from_array*(palette: array[4, uint8]): uint8 =
  palette[0] or (palette[1] shl 2) or (palette[2] shl 4) or (palette[3] shl 6)

proc ppu_start_hdma*(ppu: GbPpu; gb: GB; val: uint8) =
  ## A write to FF55. The length register takes the low 7 bits either way -- it
  ## is one register, and the write lands in it whether it starts a transfer or
  ## stops one (same-suite dma/hdma_lcd_off writes $00 to stop a transfer with
  ## three blocks left and reads back $80, not $82). The address counters are
  ## NOT reloaded from anywhere: they are already where the last transfer, or
  ## the last write to FF51-FF54, left them.
  ppu.hdma5 = val and 0x7F
  if (val and 0x80) != 0:
    ppu.hdma_active = true
    # Arming an HBlank transfer while the PPU is *already* in HBlank starts it
    # right away — the edge into mode 0 has passed, so waiting for the next one
    # would lose a block per transfer. With the LCD off the mode reads 0
    # forever, which is why an armed transfer still makes exactly this much
    # progress and no more (same-suite dma/hdma_lcd_off: one block copied, the
    # length down by one, and nothing after that).
    if ppu.mode_flag == 0 or not ppu.lcd_enabled:
      ppu_step_hdma(ppu, gb)
  else:
    if not ppu.hdma_active:
      for _ in 0 .. int(ppu.hdma5):
        if not ppu_copy_hdma_block(ppu, gb): break
      # GDMA is short of the hardware by some amount here, and SHIPS AT ZERO
      # because no constant is that amount. See GDMA_SETUP_MCYCLES in gb.nim
      # for the measurement that rejected every setting of it.
      when GDMA_SETUP_MCYCLES != 0:
        mem_tick_components(gb.memory, gb, 4 * GDMA_SETUP_MCYCLES, from_cpu = false)
    else:
      # Terminating an armed HBlank transfer: the block this HBlank owed it is
      # owed no longer.
      ppu.hdma_block_due = false
    ppu.hdma_active = false

# ---- Which half of a CPU write moves, and which does not --------------------
#
# mem_write commits a write's byte at the top of its M-cycle because the mode-3
# pixel pipeline was running an M-cycle ahead of the CPU. That compensation is
# only correct for what the PIPELINE reads; everything else in the PPU was
# already in phase and must keep the commit point it had. Three cases, each
# settled by the ROMs that isolate it rather than by the rule:
#
#   * Pipeline registers -- SCX, SCY, WX, WY, the palettes, VBK, VRAM and OAM.
#     The byte moves. That is the whole point (gambatte bgtiledata/bgtilemap,
#     mealybug m3_*).
#   * Registers that GATE a PPU event -- STAT's source-enable bits and FF55.
#     The whole store waits for the M-cycle boundary, so a mode edge inside
#     those dots is still gated by the value the CPU has not replaced yet.
#     gambatte m0enable/disable_* (16 ROMs sweeping SCX across the mode 3->0
#     edge) and dma/hdma_late_disable_* exist to time exactly this; committing
#     early lets the CPU suppress an interrupt, or a HBlank block, that hardware
#     still delivers. With the store held back, every STAT-write family --
#     m0enable, m1, m2enable -- is byte-for-byte what it was before the reorder.
#   * Registers the PPU itself updates or compares against -- LYC and IF. The
#     byte moves, and the ROMs say so: ly_lyc_write-GS times an LYC write
#     against the LY advance, and gbmicrotest vblank_int_if_c / vblank2_int_if_c
#     / lyc1_int_if_edge_c time an IF clear against the flag the PPU raises.
#     Both want the CPU's store to win inside its own M-cycle.
#
# LCDC straddles the first and second cases -- the pipeline reads six of its
# bits and the mode machinery reads bit 7 -- so its byte moves and only its
# effect on the STAT line is held back (stat_write_pending).
proc ppu_write_machinery*(ppu: GbPpu; gb: GB; idx: int; val: uint8) =
  case idx
  of 0xFF41:
    ppu.lcd_status = (ppu.lcd_status and 0b1000_0111'u8) or (val and 0b0111_1000'u8)
    ppu_handle_stat_interrupt(ppu, gb)
  of 0xFF55:
    ppu_start_hdma(ppu, gb, val)
  else: discard

proc ppu_defer_machinery_write*(ppu: GbPpu; gb: GB; idx: int; val: uint8) =
  ## Park one of the two above until the M-cycle boundary (mem_flush_deferred).
  ## The slot is drained first: the bus path can only fill it once per M-cycle,
  ## but the write_byte callers that are not an M-cycle at all (the post-boot
  ## register table, cheat pokes) can, and none of them may lose a store.
  if gb.memory.deferred_reg != 0:
    ppu_write_machinery(ppu, gb, int(gb.memory.deferred_reg), gb.memory.deferred_val)
  gb.memory.deferred_reg = uint16(idx)
  gb.memory.deferred_val = val
  gb.memory.write_deferred = true

# ---- The pipeline registers' stores, split out so a CGB write can land late --
#
# Each of these is the whole of what a write to that register does to the pixel
# pipeline, and nothing else: no STAT edge, no LCD-enable restart, nothing the
# interrupt machinery reads. That is what makes them safe to move by a dot or
# two on their own (see mem_tick_ppu_latched); the parts that do NOT move stay
# in ppu_write where they always were.
proc ppu_store_scy*(ppu: GbPpu; gb: GB; val: uint8) {.inline.} =
  ppu.scy = val

proc ppu_store_scx*(ppu: GbPpu; gb: GB; val: uint8) {.inline.} =
  ppu.scx = val

proc ppu_store_wx*(ppu: GbPpu; gb: GB; val: uint8) {.inline.} =
  ppu.wx = val
  if gb.fifo_ppu != nil: fifo_arm_window(gb.fifo_ppu)

proc ppu_store_wy*(ppu: GbPpu; gb: GB; val: uint8) {.inline.} =
  ppu.wy = val

proc ppu_latch_wy*(ppu: GbPpu; gb: GB; val: uint8) {.inline.} =
  ## The other half of the level comparator described at `mode_flag=`: a write
  ## that makes WY equal the line being drawn latches the window for the rest
  ## of the frame, wherever in the line it lands. Whether it is in time for
  ## THIS line is not decided here -- the window's own WX equality (see
  ## tick_shifter) reads the latch on its own dot and a write past that dot
  ## simply misses it, which is what gambatte's arg/late_wy_* families
  ## measure. V-Blank is excluded because the latch is cleared entering it and
  ## a match on lines 144..153 would carry into the next frame.
  ##
  ## Split from ppu_store_wy because the two need not happen on the same dot:
  ## the CGB PPU takes the register and this latch at different latencies (see
  ## CGB_WY_LATENCY / CGB_WY_LATCH_LATENCY, both 0 today). `ppu.ly` is read here
  ## rather than passed in for exactly that reason -- the latch samples the line
  ## it lands on, not the one the byte was written on.
  if ppu.ly == val and (ppu.lcd_status and 3'u8) != 1'u8 and ppu.lcd_enabled:
    ppu.window_trigger = true
    if gb.fifo_ppu != nil: fifo_arm_window(gb.fifo_ppu)

proc ppu_store_lcdc_tdsel*(ppu: GbPpu; gb: GB; val: uint8) {.inline.} =
  ## LCDC.4 alone: gambatte's lcdcChange lands the tile-data-select bit one dot
  ## ahead of the other six on CGB, and this is the store that expresses it.
  ## Unreachable while CGB_LCDC_TDSEL_LATENCY is 0, which is where it ships.
  ppu.lcd_control = (ppu.lcd_control and not 0x10'u8) or (val and 0x10'u8)

proc ppu_store_lcdc*(ppu: GbPpu; gb: GB; val: uint8) {.inline.} =
  ppu.lcd_control = val
  if gb.fifo_ppu != nil: fifo_arm_window(gb.fifo_ppu)

when CGB_WRITE_LATENCY_ANY:
  proc ppu_apply_pipeline_write*(ppu: GbPpu; gb: GB; idx: int; val: uint8) =
    ## Every stage of a parked store at once, for the callers that have no dots
    ## left to spread them over.
    case idx
    of 0xFF40: ppu_store_lcdc(ppu, gb, val)
    of 0xFF42: ppu_store_scy(ppu, gb, val)
    of 0xFF43: ppu_store_scx(ppu, gb, val)
    of 0xFF4A:
      ppu_store_wy(ppu, gb, val)
      ppu_latch_wy(ppu, gb, val)
    of 0xFF4B: ppu_store_wx(ppu, gb, val)
    else: discard

  proc ppu_park_pipeline_write*(ppu: GbPpu; gb: GB; idx: int; val: uint8) =
    ## Park a CGB pipeline-register store for mem_write to apply part way
    ## through this M-cycle's PPU dots. Same drain-before-refill discipline as
    ## ppu_defer_machinery_write, and for the same reason: the bus path fills
    ## the slot once per M-cycle, but the write_byte callers that are not an
    ## M-cycle at all (the post-boot register table, cheat pokes) can fill it
    ## twice, and none of them may lose a store. Those callers have no dots for
    ## the latency to run in either, so mem_flush_deferred -- which each of them
    ## already calls -- applies whatever is left in the slot outright.
    if gb.memory.pipe_reg != 0:
      ppu_apply_pipeline_write(ppu, gb, int(gb.memory.pipe_reg), gb.memory.pipe_val)
    gb.memory.pipe_reg = uint16(idx)
    gb.memory.pipe_val = val
    gb.memory.write_deferred = true

# Sprite helpers
proc sprite_on_line*(s: GbSprite; line: uint8; sprite_height: int): bool =
  int(s.y) <= int(line) + 16 and int(line) + 16 < int(s.y) + sprite_height

proc sprite_priority*(s: GbSprite): uint8 = (s.attributes shr 7) and 0x1
proc sprite_y_flip*(s: GbSprite): bool = ((s.attributes shr 6) and 0x1) == 1
proc sprite_x_flip*(s: GbSprite): bool = ((s.attributes shr 5) and 0x1) == 1
proc sprite_dmg_palette*(s: GbSprite): uint8 = (s.attributes shr 4) and 0x1
proc sprite_bank_num*(s: GbSprite): uint8 = (s.attributes shr 3) and 0x1
proc sprite_cgb_palette*(s: GbSprite): uint8 = s.attributes and 0b111

proc sprite_tile_bytes*(s: GbSprite; line: uint8; sprite_height: int): tuple[lo: uint16; hi: uint16] =
  let actual_y = int(s.y) - 16
  var tile_ptr: uint16
  if sprite_height == 8:
    tile_ptr = uint16(s.tile_num) * 16
  else:
    if (actual_y + 8 <= int(line)) xor sprite_y_flip(s):
      tile_ptr = uint16(s.tile_num or 0x01) * 16
    else:
      tile_ptr = uint16(s.tile_num and 0xFE) * 16
  let sprite_row = (int(line) - actual_y) and 7
  if sprite_y_flip(s):
    result = (tile_ptr + uint16(7 - sprite_row) * 2,
              tile_ptr + uint16(7 - sprite_row) * 2 + 1)
  else:
    result = (tile_ptr + uint16(sprite_row) * 2,
              tile_ptr + uint16(sprite_row) * 2 + 1)

# PPU register read/write
proc ppu_read*(ppu: GbPpu; gb: GB; idx: int): uint8 =
  case idx
  of 0x8000..0x9FFF: ppu.vram[ppu.vram_bank][idx - 0x8000]
  of 0xFE00..0xFE9F:
    # OAM is inaccessible to the CPU during OAM scan (mode 2) and drawing
    # (mode 3): reads return 0xFF. See cpu_oam_open for where the two edges sit
    # (mooneye intr_2_oam_ok_timing, lcdon_timing-GS).
    if cpu_oam_open(ppu, is_write = false): ppu.sprite_table[idx - 0xFE00]
    else: 0xFF'u8
  of 0xFF40:         ppu.lcd_control
  of 0xFF41:
    when defined(gb_stat_read_trace):
      # Diagnostic only (tools; compiled out of every shipping build). What
      # the m2int_* derivation in STAT_MODE_HOLD was traced with.
      echo "STATRD ly=", ppu.ly, " cc=", ppu.cycle_counter,
           " rm=", ppu.read_mode and 3'u8, " live=", ppu.lcd_status and 3'u8
    # The mode bits (0-1) are sampled at the last dot of this read's own
    # M-cycle -- see stat_read_mode, and STAT_READ_LAG for what pins that dot.
    let rm = stat_read_mode(ppu)
    var live = (ppu.lcd_status and 0b1111_1100'u8) or rm
    # The LY=LYC comparator does not follow LY instantaneously: the M-cycle in
    # which LY advances reads back with the coincidence bit CLEAR whatever LYC
    # holds, and the comparison re-appears one M-cycle later. mooneye
    # acceptance/ppu/lcdon_timing-GS pins both halves of that -- at the M-cycle
    # of the line 0->1 advance it wants bit 2 clear for LYC=1 (a comparison that
    # has just become true) *and* for LYC=0 (one that has just become false), so
    # this is a suppression window, not a one-M-cycle-stale copy of the bit.
    if (ppu.read_mode and LY_JUST_CHANGED) != 0:
      live = live and not 0b0000_0100'u8
    # Leaving vblank, DMG's two mode bits do not move together: bit 0 drops as
    # mode 1 ends and bit 1 only comes up an M-cycle later, so the M-cycle the
    # 1 -> 2 transition falls inside reads back as mode 0. Nothing else in the
    # frame shows it -- every other line enters mode 2 out of mode 0, where the
    # bits are already 00 -- and it is the same shape as the `first_line` rule
    # above, which is mode 2 read as 0 for a whole line after an LCD enable.
    #
    # Three ROMs from two suites pin it, and they also pin it to DMG:
    # gbmicrotest poweron_stat_006 (STAT read on exactly that M-cycle, $84 not
    # $85) and mooneye-wilbertpol ly00_mode0_2-GS and ly00_mode1_0-GS. Its
    # CGB sibling ly00_mode1_2-C wants the plain lagged value, which is why the
    # hardware test is here rather than in `live` unconditionally.
    if (ppu.first_line and rm == 2) or
       (rm == 1 and not gb.cgb_enabled and (ppu.lcd_status and 3'u8) == 2):
      live and 0b1111_1100'u8
    else:
      live
  of 0xFF42: ppu.scy
  of 0xFF43: ppu.scx
  of 0xFF44: ppu.ly
  of 0xFF45: ppu.lyc
  of 0xFF46: 0xFF'u8  # DMA (write-only, return 0xFF)
  of 0xFF47: ppu_palette_from_array(ppu.bgp)
  of 0xFF48: ppu_palette_from_array(ppu.obp0)
  of 0xFF49: ppu_palette_from_array(ppu.obp1)
  of 0xFF4A: ppu.wy
  of 0xFF4B: ppu.wx
  of 0xFF4F: (if gb.cgb_enabled: 0xFE'u8 or ppu.vram_bank else: 0xFF'u8)
  # HDMA1-4 are write-only ("VRAM DMA source (high, low) [write-only]",
  # "VRAM DMA destination (high, low) [write-only]" -- Pan Docs, CGB
  # Registers). Pan Docs does not say what a read returns; gambatte's
  # ff51_bits/ff52_bits/ff53_bits/ff54_bits pin it, all four expecting FF on
  # cgb04c, i.e. not one bit of any of the four is readable. What was written
  # is still *kept* — it is the transfer's address counter — just not visible.
  of 0xFF51..0xFF54: 0xFF'u8
  # "Reading Bit 7 of FF55 can be used to confirm if the DMA transfer is active
  # (1=Not Active, 0=Active). This works under any circumstances - after
  # completion of General Purpose, or HBlank Transfer, and after manually
  # terminating a HBlank Transfer" -- Pan Docs, FF55. The low 7 bits are the
  # length register, which a completed transfer has left at $7F (it wrapped
  # past 0), so a finished transfer still reads the documented $FF.
  of 0xFF55:
    if gb.cgb_native:
      (ppu.hdma5 and 0x7F) or (if ppu.hdma_active: 0x00'u8 else: 0x80'u8)
    else: 0xFF'u8
  of 0xFF68:
    if gb.cgb_enabled:
      0x40'u8 or (if ppu.auto_increment: 0x80'u8 else: 0'u8) or ppu.palette_index
    else: 0xFF'u8
  of 0xFF69: (if gb.cgb_native: ppu.pram[ppu.palette_index] else: 0xFF'u8)
  of 0xFF6A:
    if gb.cgb_enabled:
      0x40'u8 or (if ppu.obj_auto_increment: 0x80'u8 else: 0'u8) or ppu.obj_palette_index
    else: 0xFF'u8
  of 0xFF6B: (if gb.cgb_native: ppu.obj_pram[ppu.obj_palette_index] else: 0xFF'u8)
  else: 0xFF'u8

proc ppu_write*(ppu: GbPpu; gb: GB; idx: int; val: uint8) =
  case idx
  of 0x8000..0x9FFF: ppu.vram[ppu.vram_bank][idx - 0x8000] = val
  of 0xFE00..0xFE9F: ppu.sprite_table[idx - 0xFE00] = val
  of 0xFF40:
    if (val and 0x80) != 0 and not ppu.lcd_enabled:
      # The PPU restarts at the top of the frame, so the next frame it draws is
      # 65664 dots away. If enough time has already passed since the last
      # present, push one now rather than let the gap stretch — skipping it
      # leaves the emulator one frame ahead of the panel for the rest of the
      # run, and games toggle the LCD constantly. See LCD_ON_FRAME_DOTS for why
      # this is a pacing rule rather than a hardware one.
      if ppu.dots_since_frame > LCD_ON_FRAME_DOTS:
        when defined(gb_dot_counter): inc gb_frame_lcd_on
        ppu_blank_frame(ppu, gb)
      ppu.ly = 0
      # The re-enabled PPU is already part-way into its first line by the time
      # the LCDC write retires -- it does not start at dot 0 there. This seed is
      # the whole of that head start, and because every line is a multiple of
      # 4 dots long it is also the PPU's dot phase against the CPU's M-cycle
      # grid for the rest of the run. Two tests pin it, and between them there
      # is exactly one answer:
      #
      #  * mooneye acceptance/ppu/lcdon_timing-GS reads LY and STAT at known
      #    M-cycle offsets from the write and pins all three of line 0's
      #    boundaries (mode 2->3, mode 3->0, and LY 0->1); the line-1 and line-2
      #    boundaries it also samples are a plain 456 dots apart, so only line 0
      #    is special. Those three fix the head start to 5..8 dots.
      #  * mooneye acceptance/ppu/hblank_ly_scx_timing-GS then fixes it mod 4.
      #    It measures the gap from the mode-0 STAT interrupt to the LY advance
      #    with SCX&7 = 0..7, which walks the mode-3 end across one M-cycle a
      #    dot at a time, and the gap has to shorten between SCX&7 = 0 and 1 --
      #    i.e. the M-cycle boundary sits immediately after the SCX&7 = 0 end
      #    dot, not three dots later. That is a head start of 1 mod 4.
      #
      # That second bullet does NOT bracket this constant, and a re-measurement
      # on 2026-08-03 says so: a full runner at `-d:LCD_ON_HEAD_START=7` leaves
      # mooneye at 112/115 and mooneye-wilbertpol at 82/117, both row for row
      # unchanged, so neither hblank_ly_scx_timing-GS nor lcdon_timing-GS can
      # tell 5 from 7. What actually refuses 7 is gambatte: enable_display
      # 133 -> 123 (the ly0_late_scx7_m3stat_scx{1,3}_1 and frame{1,2}_m0irq_
      # count_scx2_1 rows swap with their _2 siblings, i.e. it is exactly one
      # M-cycle too far) and the scx_during_m3 reference PNGs 34 -> 31. 7 is
      # otherwise attractive -- it is what all eight GBMicrotest
      # hblank_int_scx0..7 rows ask for, +9 GBMicrotest and +7 gambatte net --
      # so read the table at LCD_ON_LINE0_TRIM in gb.nim before re-deriving it:
      # those 2 dots are wanted by three families and refused by a fourth
      # whichever of the three constants carries them.
      #
      # 5 is the only value satisfying both. Physically it is the 2-T-cycle
      # skew mooneye's own notes describe (the PPU restarts mid-M-cycle, so
      # line 0 ends 2 T-cycles off the grid and the next line lands back on it),
      # rounded into this renderer's whole-dot counter. No rendered pixel moves:
      # mode 3 is still driven to 160 pixels by the shifter, not by this counter.
      #
      # Both of those ROMs measure the head start from an M-cycle BOUNDARY, and
      # this is the one write whose effect is a restart of the PPU's own clock:
      # the counter has to read 5 once this M-cycle's dots have run, not when
      # the byte lands at the top of it (mem_write applies CPU writes before the
      # dots). Backing the M-cycle out is what keeps the constant the one those
      # two ROMs pin at BOTH speeds -- an M-cycle is 2 dots in double speed, and
      # seeding 5 flat there restarts the PPU one double-speed M-cycle late
      # (gambatte enable_display/frame0_m2stat_count_ds_*, m2enable/disable_ds_*).
      ppu.cycle_counter = int32(int(LCD_ON_HEAD_START) - (4 shr gb.memory.current_speed))
      when STAT_IRQ_SPLIT:
        # The irq domain restarts with the flag domain: the lead is a lead over
        # the PPU's own schedule, and here the schedule itself is what restarts.
        ppu.irq_ly = 0
      when STAT_READ_HOLD:
        ppu.stat_hold_until = 0  # the counter it was expressed in is gone
      ppu.`mode_flag=`(2'u8, gb)
      ppu.first_line = true
      when LCD_ON_TRIM_ANY: ppu.lcdon_lines = 2
    when defined(gb_m3_trace):
      if gb_traced(ppu.ly) and (ppu.lcd_status and 3) == 3:
        let fp = if ppu of GbFifoPpu: $GbFifoPpu(ppu).fetch_counter &
                    " lx=" & $GbFifoPpu(ppu).lx & " fx=" & $GbFifoPpu(ppu).fetcher_x
                 else: "?"
        echo "LCDC ly=", ppu.ly, " dot=", ppu.cycle_counter, " old=",
             toHex(ppu.lcd_control, 2), " new=", toHex(val, 2), " fc=", fp
    when defined(gb_win_trace):
      echo "LCDC ly=", ppu.ly, " dot=", ppu.cycle_counter, " mode=",
           (ppu.lcd_status and 3), " old=", toHex(ppu.lcd_control,2), " new=", toHex(val,2)
    # Only the six bits the pixel pipeline reads are late on CGB; the enable
    # bit is not, because the branch above has already restarted the mode
    # machinery off it and the store has to agree with that on the same dot.
    when CGB_LCDC_LATENCY_ANY:
      if gb.cgb_enabled and ((ppu.lcd_control xor val) and 0x80'u8) == 0:
        ppu_park_pipeline_write(ppu, gb, idx, val)
      else:
        ppu_store_lcdc(ppu, gb, val)
    else:
      ppu_store_lcdc(ppu, gb, val)
    # Deferred to the end of this M-cycle -- see GbPpu.stat_write_pending and
    # the consume in mem_write. The LCD-enable branch above is NOT deferred:
    # that one restarts the mode machinery itself rather than feeding it.
    # LCDC.1 (OBJ enable) and, in CGB mode, LCDC.0 (BG priority) are mixer
    # reads, and mealybug m3_lcdc_obj_en_change is what times them; see
    # fifo_recompose_last.
    mixer_write_repaint(gb, MIXER_PRIORITY_BACK)
    ppu.stat_write_pending = true
    gb.memory.write_deferred = true
  of 0xFF41:
    # DMG only, and paid for by one predictable branch on a register write that
    # is already doing more than this. See ppu_stat_write_glitch: the $FF phase
    # of the write acts here, at the write's commit point, and only the real
    # value waits for the M-cycle boundary.
    if not gb.cgb_enabled: ppu_stat_write_glitch(ppu, gb)
    ppu_defer_machinery_write(ppu, gb, idx, val)
  of 0xFF42:
    when defined(gb_m3_trace):
      # The SCY half of the same instrument as the SCX line below. mealybug
      # m3_scy_change writes this register every 2 M-cycles across mode 3, so
      # the dot each write lands on is what the three per-fetch SCY reads (the
      # tile-map row, then one per bitplane) have to be read against.
      echo "SCY ly=", ppu.ly, " dot=", ppu.cycle_counter,
           " mode=", (ppu.lcd_status and 3), " old=", ppu.scy, " new=", val
    when CGB_SCY_LATENCY != 0:
      if gb.cgb_enabled: ppu_park_pipeline_write(ppu, gb, idx, val)
      else:              ppu_store_scy(ppu, gb, val)
    else:
      ppu_store_scy(ppu, gb, val)
  of 0xFF43:
    when defined(gb_m3_trace):
      # Same instrument as the LCDC line above, for the scroll register: which
      # dot of which line an SCX write lands on is what pins the fine-scroll
      # latch against it (see fifo_sample_smooth_scroll's caller).
      echo "SCX ly=", ppu.ly, " dot=", ppu.cycle_counter,
           " mode=", (ppu.lcd_status and 3), " old=", ppu.scx, " new=", val
    when CGB_SCX_LATENCY != 0:
      if gb.cgb_enabled: ppu_park_pipeline_write(ppu, gb, idx, val)
      else:              ppu_store_scx(ppu, gb, val)
    else:
      ppu_store_scx(ppu, gb, val)
  of 0xFF44: discard  # read-only
  of 0xFF45:
    # NOT deferred, unlike STAT and FF55 next door: LYC is the LY comparator's
    # other input, and mooneye-wilbertpol acceptance/gpu/ly_lyc_write-GS times an
    # LYC write against the LY advance and wants the new value to win inside its
    # own M-cycle. That row is RED on main and green with the byte committed at
    # the top of the M-cycle; deferring it puts it back to red and takes
    # gambatte lycEnable 166 -> 163. Only the STAT edge is held back.
    ppu.lyc = val
    ppu.stat_write_pending = true
    gb.memory.write_deferred = true
  of 0xFF46: discard  # handled by memory DMA
  # The three DMG palettes are pure mixer reads -- nothing else in the PPU looks
  # at them -- so each one carries the mixer's extra dot (fifo_recompose_last).
  of 0xFF47, 0xFF48, 0xFF49:
    when defined(gb_px_trace):
      # The palette half of the same instrument as the LCDC line above: which
      # dot a mid-mode-3 palette write lands on, read against the PX line for
      # the pixel it is supposed to reach. See fifo_recompose_last.
      echo "PAL ly=", ppu.ly, " dot=", ppu.cycle_counter, " reg=", toHex(idx, 4),
           " mode=", (ppu.lcd_status and 3), " new=", toHex(val, 2)
    # ---- The transition pixel: one dot of `old or new` ---------------------
    #
    # A DMG palette write is not a clean edge at the mixer. mealybug
    # m3_bgp_change reads it out directly: VRAM is all zeroes there, so every
    # pixel is colour 0 and the frame is literally BGP bits 1:0 sampled once per
    # dot, against a handler that writes BGP six times at known cycles. Its DMG
    # reference answers with a THREE-valued edge -- on LY 17 the run is
    #
    #   x      0    1     2..12   13     14..
    #   BGP  $11   $13     $12    $13    $11
    #
    # where $11 is the value before the write, $12 the value written at that
    # dot, $12 -> $11 the write twelve dots later, and $13 = $11 or $12 is
    # neither. The same single pixel of `old or new` sits at the FAR end of the
    # mixer tail at every one of the six writes, on every line of the frame, and
    # on m3_bgp_change_sprites next door. Lines where the OR happens to equal
    # the old or the new value (LY 1's $10 or $11 = $11) show a two-valued edge
    # and are where the effect hid: with the OR pixel drawn as `new`, that row
    # was 820 pixels out and this row's own runs were a pixel short at every
    # boundary.
    #
    # Physically it is the palette latch being read on the dot it is written --
    # the mixer's shade lookup is combinational off those four 2-bit fields, and
    # the pixel in flight sees both drives. What is measured is that it lasts
    # exactly one pixel and sits at MIXER_PALETTE_BACK, i.e. the oldest pixel
    # the write still reaches; every nearer pixel takes the new value cleanly.
    # The OR pixel sits at MIXER_PALETTE_BACK -- the OLDEST pixel a DMG write
    # reaches -- and the CGB's own dot of write latency (CGB_MIXER_LATENCY) puts
    # that pixel out of reach, so on CGB the one pixel the write does repaint
    # takes the new value cleanly. That is not an assumption: running these two
    # DMG carts on CGB hardware against the suite's `_cgb_c` references wants a
    # clean edge (m3_bgp_change 22732/23040 with it, 22321 with an OR pixel;
    # m3_bgp_change_sprites 22948 against 22600) while the DMG references want
    # the OR. Same cart, same write; only the console differs, exactly as at
    # CGB_MIXER_LATENCY.
    var or_pixel = false
    when MIXER_PALETTE_OR != 0:
      or_pixel = MIXER_DOT_LAG != 0 and gb.fifo_ppu != nil and
                 not gb.cgb_enabled and MIXER_PALETTE_BACK > 0
      if or_pixel:
        let cur = case idx
                  of 0xFF47: addr ppu.bgp
                  of 0xFF48: addr ppu.obp0
                  else:      addr ppu.obp1
        ppu_update_palette(cur[], ppu_palette_from_array(cur[]) or val)
        fifo_recompose_at(gb.fifo_ppu, gb, int32(MIXER_PALETTE_BACK))
    case idx
    of 0xFF47: ppu_update_palette(ppu.bgp,  val)
    of 0xFF48: ppu_update_palette(ppu.obp0, val)
    else:      ppu_update_palette(ppu.obp1, val)
    mixer_write_repaint(gb, int32(MIXER_PALETTE_BACK) - (if or_pixel: 1'i32 else: 0'i32))

  of 0xFF4A:
    when defined(gb_win_trace):
      echo "WY ly=", ppu.ly, " dot=", ppu.cycle_counter, " mode=",
           (ppu.lcd_status and 3), " old=", ppu.wy, " new=", val
    when CGB_WY_LATENCY_ANY:
      if gb.cgb_enabled:
        ppu_park_pipeline_write(ppu, gb, idx, val)
      else:
        ppu_store_wy(ppu, gb, val)
        ppu_latch_wy(ppu, gb, val)
    else:
      ppu_store_wy(ppu, gb, val)
      ppu_latch_wy(ppu, gb, val)
  of 0xFF4B:
    when defined(gb_win_trace):
      echo "WX ly=", ppu.ly, " dot=", ppu.cycle_counter, " mode=",
           (ppu.lcd_status and 3), " old=", ppu.wx, " new=", val
    when CGB_WX_LATENCY != 0:
      if gb.cgb_enabled: ppu_park_pipeline_write(ppu, gb, idx, val)
      else:              ppu_store_wx(ppu, gb, val)
    else:
      ppu_store_wx(ppu, gb, val)
  of 0xFF4F:
    # The register, not the console: VBK goes with the rest of the CGB set when
    # the boot ROM sets KEY0, so a DMG-compatibility cart is stuck on bank 0 and
    # the attribute plane the fetcher reads stays all zeroes. The READ above is
    # deliberately still on cgb_enabled -- it answers 0xFE either way once the
    # bank is pinned, which is what mooneye misc/bits/unused_hwio-C reads back.
    if gb.cgb_native: ppu.vram_bank = val and 0x1
  # Each of these edits one byte of the live address counter (see GbPpu's HDMA
  # fields). The four lower bits of both addresses "will be ignored and treated
  # as 0" (Pan Docs, FF51-FF54); the destination's upper bits are dropped where
  # the counter is turned into an address, not here -- see ppu_copy_hdma_block.
  of 0xFF51:
    if gb.cgb_native:
      ppu.hdma_src = (uint16(val) shl 8) or (ppu.hdma_src and 0x00F0'u16)
  of 0xFF52:
    if gb.cgb_native:
      ppu.hdma_src = (ppu.hdma_src and 0xFF00'u16) or uint16(val and 0xF0)
  of 0xFF53:
    if gb.cgb_native:
      ppu.hdma_dst = (uint16(val) shl 8) or (ppu.hdma_dst and 0x00F0'u16)
  of 0xFF54:
    if gb.cgb_native:
      ppu.hdma_dst = (ppu.hdma_dst and 0xFF00'u16) or uint16(val and 0xF0)
  of 0xFF55:
    if gb.cgb_native: ppu_defer_machinery_write(ppu, gb, idx, val)
  of 0xFF68:
    if gb.cgb_enabled:
      ppu.palette_index  = val and 0x3F
      ppu.auto_increment = (val and 0x80) != 0
  of 0xFF69:
    if gb.cgb_native:
      ppu.pram[ppu.palette_index] = val
      if ppu.auto_increment:
        ppu.palette_index = (ppu.palette_index + 1) and 0x3F
  of 0xFF6A:
    if gb.cgb_enabled:
      ppu.obj_palette_index  = val and 0x3F
      ppu.obj_auto_increment = (val and 0x80) != 0
  of 0xFF6B:
    if gb.cgb_native:
      ppu.obj_pram[ppu.obj_palette_index] = val
      if ppu.obj_auto_increment:
        ppu.obj_palette_index = (ppu.obj_palette_index + 1) and 0x3F
  else: discard

method tick*(ppu: GbPpu; gb: GB; cycles: int) {.base.} = discard
