# GB Interrupts (included by gb.nim)

const
  INT_VBLANK* = 0x0040'u16
  INT_STAT*   = 0x0048'u16
  INT_TIMER*  = 0x0050'u16
  INT_SERIAL* = 0x0058'u16
  INT_JOYPAD* = 0x0060'u16
  INT_NONE*   = 0x0000'u16

when defined(gb_phase_trace):
  # Diagnostic (compiled out of shipping builds): which T-cycle of its M-cycle
  # an IF bit rose on. `gb_phase` is set by the PPU dot loop and the timer's
  # per-cycle loop and read by the STATIRQ/VBLIRQ/TIMIRQ/LYREAD echoes;
  # `gb_ticklen` is the tick length the phase counts within (4, or 2 for a
  # split halted M-cycle). The instrument HALT_IF_SAMPLE_T was derived with.
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
  of INT_TIMER:
    irq.timer_interrupt     = false
    when TIMER_IRQ_RUN_LEAD != 0: irq.timer_interrupt_early = false
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

# What a CPU read of $FF0F sees. The dispatch decides at the M-cycle boundary
# (IRQ_SAMPLE_T in cpu.nim) but a read latches its data part way through its
# M-cycle: GBMicrotest vblank_int_if_a, hblank_int_if_a, lyc1_int_if_edge_a and
# oam_int_if_edge_a all print one extra IF bit for an end-of-M-cycle read, and
# gambatte m1/lycint_vblankirq_{1,2} separate a late read from an early source
# (GBMicrotest int_vblank1_nops, which times the dispatch, is exact). Not a
# whole M-cycle: gambatte ly0/lycint152_lyc0irq_{1,2} wait for the snapback's
# LYC = 0 match on the second dot of its M-cycle and hardware sees it.
# IF_READ_SAMPLE_T (gb.nim) is the T-count; it is only scorable together with
# STAT_M0_LEAD_T, the two being compensating errors. The split M-cycle must
# keep fifo_tick's read_mode latch (mem_tick_if_read); -d:gb_if_split_control
# keeps the split and returns the live byte as the control. -1 (the latch
# ahead of the bus half too) loses gambatte tima/* because the timer runs its
# four T-cycles as one step at the head of the M-cycle.
proc irq_read*(irq: GbInterrupts; idx: int): uint8 =
  case idx
  of 0xFF0F:
    # gb_if_split_control: the split tick with the live byte (control build).
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
  ## Run after every instruction and on every HALT; the five pairs directly
  ## rather than building the IF/IE bytes to mask them.
  (irq.vblank_interrupt   and irq.vblank_enabled)   or
  (irq.lcd_stat_interrupt and irq.lcd_stat_enabled) or
  (irq.timer_interrupt    and irq.timer_enabled)    or
  (irq.serial_interrupt   and irq.serial_enabled)   or
  (irq.joypad_interrupt   and irq.joypad_enabled)

proc interrupt_ready_run*(irq: GbInterrupts): bool {.inline.} =
  ## `interrupt_ready` for a running CPU: with TIMER_IRQ_RUN_LEAD (gb.nim) on,
  ## the timer's request arrives here one M-cycle before anywhere else.
  when TIMER_IRQ_RUN_LEAD == 0:
    interrupt_ready(irq)
  else:
    interrupt_ready(irq) or
      (irq.timer_interrupt_early and irq.timer_enabled)

proc irq_write*(irq: GbInterrupts; idx: int; val: uint8) =
  case idx
  of 0xFF0F:
    irq.vblank_interrupt    = (val and 0x01) != 0
    irq.lcd_stat_interrupt  = (val and 0x02) != 0
    irq.timer_interrupt     = (val and 0x04) != 0
    when TIMER_IRQ_RUN_LEAD != 0:
      # Clearing bit 2 by hand must not leave a dispatch armed behind it.
      irq.timer_interrupt_early = irq.timer_interrupt
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
