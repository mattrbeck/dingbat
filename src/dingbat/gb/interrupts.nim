# GB Interrupts (included by gb.nim)

const
  INT_VBLANK* = 0x0040'u16
  INT_STAT*   = 0x0048'u16
  INT_TIMER*  = 0x0050'u16
  INT_SERIAL* = 0x0058'u16
  INT_JOYPAD* = 0x0060'u16
  INT_NONE*   = 0x0000'u16

when defined(gb_phase_trace):
  # ---- Which T-cycle of the M-cycle an IF bit rose on ------------------------
  #
  # Diagnostic only, compiled out of every shipping build. `gb_phase` is set by
  # the PPU's dot loop (fifo_tick_slow) and by the timer's per-cycle loop, and
  # read by the four IF-raise echoes hanging off them -- `STATIRQ` in ppu.nim,
  # `VBLIRQ` in fifo_ppu.nim, `TIMIRQ` in timer.nim -- plus `LYREAD` on the
  # `$FF44` read path in memory.nim. `gb_ticklen` is the length of the tick the
  # phase is counted within, which is 4 for an ordinary M-cycle and 2 for either
  # half of a split halted one.
  #
  # This is the instrument HALT_IF_SAMPLE_T in cpu.nim is derived with: which
  # half of its M-cycle each interrupt source rises in is the whole question,
  # and no suite reports it -- it has to be read off the tree and scored against
  # the halt/sled pairs.
  var gb_phase*: int32 = 0
  var gb_ticklen*: int32 = 0

proc new_gb_interrupts*(): GbInterrupts =
  GbInterrupts()

proc highest_priority*(irq: GbInterrupts): uint16 =
  if irq.vblank_interrupt   and irq.vblank_enabled:   INT_VBLANK
  elif irq.lcd_stat_interrupt and irq.lcd_stat_enabled: INT_STAT
  elif irq.timer_interrupt    and irq.timer_enabled:    INT_TIMER
  elif irq.serial_interrupt   and irq.serial_enabled:   INT_SERIAL
  elif irq.joypad_interrupt   and irq.joypad_enabled:   INT_JOYPAD
  else: INT_NONE

proc clear_interrupt*(irq: GbInterrupts; line: uint16) =
  case line
  of INT_VBLANK: irq.vblank_interrupt    = false
  of INT_STAT:   irq.lcd_stat_interrupt  = false
  of INT_TIMER:  irq.timer_interrupt     = false
  of INT_SERIAL: irq.serial_interrupt    = false
  of INT_JOYPAD: irq.joypad_interrupt    = false
  else: discard

proc irq_packed*(irq: GbInterrupts): uint8 {.inline.} =
  0xE0'u8 or
  (if irq.joypad_interrupt:   0x10'u8 else: 0'u8) or
  (if irq.serial_interrupt:   0x08'u8 else: 0'u8) or
  (if irq.timer_interrupt:    0x04'u8 else: 0'u8) or
  (if irq.lcd_stat_interrupt: 0x02'u8 else: 0'u8) or
  (if irq.vblank_interrupt:   0x01'u8 else: 0'u8)

when IF_READ_SAMPLE_T < 4:
  proc irq_latch_mcycle*(irq: GbInterrupts) {.inline.} =
    ## Called IF_READ_SAMPLE_T dots into the M-cycle of a $FF0F read, and only
    ## there (mem_tick_if_read in memory.nim). See irq_read.
    irq.if_prev = irq_packed(irq)

# ---- What a CPU read of $FF0F is allowed to see -----------------------------
#
# dingbat ticks a bus access's whole M-cycle and then serves the read, so a
# read of $FF0F returns IF as it stands at the END of its own M-cycle -- every
# source that rose anywhere inside it included. The dispatch is entitled to
# that view (it decides at the M-cycle boundary, and IRQ_SAMPLE_T in cpu.nim is
# where its own clear sits), but a READ is a bus transaction that latches its
# data part way through the cycle, and the suites say so in one voice.
#
# The signature is a single extra IF bit, always in dingbat's favour, on rows
# whose read lands in the same M-cycle as a line boundary. GBMicrotest states
# it most plainly, because those rows print IF itself:
#
#   vblank_int_if_a     got $E2  want $E0     lyc1_int_if_edge_a   $E2 / $E0
#   vblank2_int_if_a    got $E1  want $E0     oam_int_if_edge_a    $E2 / $E0
#   hblank_int_if_a     got $E2  want $E0     lcdon_to_if_oam_a    $E2 / $E0
#   line_144_oam_int_c  got $E3  want $E2     stat_write_glitch_l143_c  $E3 / $E2
#
# and gambatte says the same thing 100-odd times over in `got 2 expected 0`,
# `got 3 expected 1` and `got E2 expected E0`.
#
# The bracket that separates this from "the source rises a cycle late" is
# gambatte m1/lycint_vblankirq_{1,2}: STAT = $40 (LYC alone), LYC = 143, and the
# handler counts 103 / 104 NOPs from the LY 143 STAT dispatch to an IF read.
# Hardware -- and SameBoy -- read 0 then 1; dingbat reads 1 at both. If the
# VBlank IF bit itself were early, GBMicrotest's int_vblank1_nops sled (which
# times the DISPATCH, not a read) would be one M-cycle out too, and it is
# exact. So it is the read that is entitled to less, not the source that is
# early.
#
# It is NOT a whole M-cycle, and one family says so on its own. gambatte
# ly0/lycint152_lyc0irq_{1,2} wants E0 then E2, and the source it is waiting for
# is the LY 153 -> 0 snapback's LYC = 0 match, which lands at LYC_RELATCH_DOT --
# dot 9 of line 153, the SECOND dot of its M-cycle, not the last. Hardware sees
# it inside the reading M-cycle; a latch at the M-cycle's top does not. So the
# sample point is part way through, which is why this is a T-count and why the
# M-cycle's dots are run in two pieces around it (mem_tick_components) the way
# CGB_*_LATENCY already splits mem_write's.
#
# Swept, whole runner of 1225 / gambatte of 5005 / GBMicrotest of 482, one build
# per cell, against `main` at 6759d52 -- so the gambatte column is three rows
# below today's, the serial shift-clock fix having landed between; every cell is
# against the same tree. On the tree this ships in the shipping cell is
# 1042 / 4322 / 438 against 1016 / 4272 / 430 with it off.
#
#   IF_READ_SAMPLE_T   runner   gambatte   micro
#         -1              --        --       --   see the a_r paragraph below
#          0            1037      4322      433
#          1            1039      4320      435
#          2            1042      4319      438   <- ships
#          3            1039      4307      435
#          4 (off)      1016      4269      430
#
# Two-sided on GBMicrotest, which is the instrument that prints IF itself, and a
# strict maximum on the runner. gambatte prefers 0 by three rows and that column
# is not the bracket: every row between 0 and 2 there is a `_2`/`_1` step of a
# family whose OTHER arm moves the opposite way, i.e. the OAM-source phase this
# constant does not own (see STAT_M2_LEAD in ppu.nim). Mooneye-wilbertpol is
# +15 at every cell, mooneye proper, mealybug, AGE and the shootout unmoved.
#
# The split has to be proven neutral before the column means anything, and it
# is not neutral for free: `fifo_tick` re-snapshots `read_mode` on every entry,
# so a naive split re-latches the STAT/VRAM/OAM read mode mid-M-cycle and moves
# twelve gambatte rows that have nothing to do with IF. mem_tick_components
# carries the fix; `-d:gb_if_split_control` keeps the split and returns the live
# IF byte, and with the fix in place that build scores the baseline exactly
# (1225/1016, gambatte 4269).
#
# ---- `a_r = 0`: measured, and refused by ONE family ------------------------
#
# The serial write-up above SERIAL_TAP_DMG argues from three families that a CPU
# read samples at the TOP of its own M-cycle -- `a_r = 0` -- rather than after
# it, and names `tima`, `halt` and `irq_precedence` as the families on the other
# side. `IF_READ_SAMPLE_T = -1` is that cell for the $FF0F read: the latch goes
# in front of the whole M-cycle, timer and serial shifter included. Measured on
# the tree this ships in, against the shipping 2:
#
#   runner 1043 -> 1037, gambatte 4334 -> 4328
#   serial          53 -> 57   (+4, the direction the serial algebra predicts)
#   m2int_m0irq     52 -> 55   lcd_offset +4, window +2
#   tima           224 -> 211  (-13)
#   ly0             82 -> 79   enable_display -1, sprites -2
#   halt           136 -> 136  (unmoved)
#   irq_precedence  47 -> 47   (unmoved)
#
# So two of the three families named as blockers do not move at all, and the
# whole cost is `tima`. What `tima` is objecting to is not the read's phase: it
# is that this tree runs the timer's four T-cycles as ONE step at the head of
# the M-cycle (mem_tick_bus), so a latch in front of that step hides a timer IRQ
# that hardware's read does see. `a_r = 0` therefore needs the timer's overflow
# edge moved later inside the M-cycle at the same time -- it cannot be scored
# against `tima` until it is -- and it would want SPEED_SWITCH_DIV_RESET_T in
# timer.nim to go from 4 to 8 with it. The shipping 2 is a latch AFTER the bus
# half and part way through the PPU's dots, which is what leaves `tima` and
# `halt` exactly where they were.
#
# What is left after it, and what it is NOT: GBMicrotest's `oam_int_if_edge_b`
# and `_d` still disagree in OPPOSITE directions with `_a` and `_c` green, and
# `lcdon_to_if_oam_b` with them. That is the OAM STAT source rising one M-cycle
# before the line boundary -- STAT_M2_LEAD, bucket 14 -- read through a now-
# sharp instrument, not a second read phase.
proc irq_read*(irq: GbInterrupts; idx: int): uint8 =
  case idx
  of 0xFF0F:
    # `gb_if_split_control` keeps the split tick and returns the live byte: the
    # control that says the split itself moved nothing (see above).
    when IF_READ_SAMPLE_T < 4 and not defined(gb_if_split_control):
      irq.if_prev
    else:
      irq_packed(irq)
  of 0xFFFF:
    irq.top_3_ie_bits or
    (if irq.joypad_enabled:   0x10'u8 else: 0'u8) or
    (if irq.serial_enabled:   0x08'u8 else: 0'u8) or
    (if irq.timer_enabled:    0x04'u8 else: 0'u8) or
    (if irq.lcd_stat_enabled: 0x02'u8 else: 0'u8) or
    (if irq.vblank_enabled:   0x01'u8 else: 0'u8)
  else: 0xFF'u8

proc interrupt_ready*(irq: GbInterrupts): bool {.inline.} =
  ## Run after every instruction and on every HALT. Testing the five
  ## request/enable pairs directly is the same predicate the packed form
  ## computes — irq_read's 0xE0 and top_3_ie_bits padding is masked off by the
  ## 0x1F — without building the two IF/IE bytes to throw them away.
  (irq.vblank_interrupt   and irq.vblank_enabled)   or
  (irq.lcd_stat_interrupt and irq.lcd_stat_enabled) or
  (irq.timer_interrupt    and irq.timer_enabled)    or
  (irq.serial_interrupt   and irq.serial_enabled)   or
  (irq.joypad_interrupt   and irq.joypad_enabled)

proc irq_write*(irq: GbInterrupts; idx: int; val: uint8) =
  case idx
  of 0xFF0F:
    irq.vblank_interrupt    = (val and 0x01) != 0
    irq.lcd_stat_interrupt  = (val and 0x02) != 0
    irq.timer_interrupt     = (val and 0x04) != 0
    irq.serial_interrupt    = (val and 0x08) != 0
    irq.joypad_interrupt    = (val and 0x10) != 0
  of 0xFFFF:
    irq.top_3_ie_bits    = val and 0xE0
    irq.vblank_enabled   = (val and 0x01) != 0
    irq.lcd_stat_enabled = (val and 0x02) != 0
    irq.timer_enabled    = (val and 0x04) != 0
    irq.serial_enabled   = (val and 0x08) != 0
    irq.joypad_enabled   = (val and 0x10) != 0
  else: discard
