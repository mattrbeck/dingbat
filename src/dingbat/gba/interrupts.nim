# Interrupts implementation (included by gba.nim)

proc new_interrupts*(gba: GBA): Interrupts =
  result = Interrupts(gba: gba, win_open_at: high(CycleCount),
                      win_close_at: high(CycleCount))
  result.reg_ie = InterruptReg()
  result.reg_if = InterruptReg()
  result.ime = false

const
  IRQ_TIMER_BIT_BASE* = 3
  IRQ_DMA_BIT_BASE*   = 8
  # Stop mode wakes only on serial (7), keypad (12), and game pak (13)
  STOP_WAKE_MASK* = 0x3080'u16

proc set_interrupt_flag*(intr: Interrupts; bit: int) {.inline.} =
  intr.reg_if = cast[InterruptReg](uint16(intr.reg_if) or (1'u16 shl bit))
  when WL_QUIET_EVENTS: intr.gba.wl_unsafe = true

# Cycles from a peripheral raising IF to CPU recognition (mGBA suite Timer
# IRQ rows). Register writes (IE/IF/IME) re-evaluate with no delay.
const IRQ_SYNC_DELAY* {.intdefine.} = 3
const UNDER_BURST_CREDIT {.intdefine.} = 1
  ## A timer interrupt raised while a burst holds the CPU off the bus is
  ## recognised IRQ_SYNC_DELAY - UNDER_BURST_CREDIT cycles after the CPU
  ## gets the bus back, or IRQ_SYNC_DELAY after the raise if that is later:
  ## one stage of the synchroniser keeps counting while the CPU is stopped.
  ## tests/roms/payloads/irqstorm.s on an AGB SP, TM0 every 16 cycles under
  ## a 1..4096-word EWRAM burst: 0 reads the five cells one cycle late, 2 four
  ## of them one cycle early.

# Cycles of continued execution after a register write (IME 0->1, IE unmask,
# msr clearing CPSR.I) releases an already-parked IF bit. The window is
# cycle-based, not instruction-based (hardware: gbaedge IRQWIN/IRQWIN2/
# IRQWIN3 on AGB SP, docs/hwprobe.md). The vector-entry cost itself is in
# cpu.irq. Those pages run their sleds from the cartridge at WAITCNT 0, six
# cycles an instruction, five of them wait states: with IRQ_LAST_WAITS
# taking an interrupt recognised in them one instruction later, the same
# counts come from 7 (it was 12 when the last cycle counted).
const
  IRQ_GATE_DELAY* = 7

proc window_open*(intr: Interrupts) =
  ## IRQ_LAST_WAITS: until the next check has run, the CPU's fetches and
  ## stores note their wait states (fetches leave the cache to do it).
  ## An interrupt on its way is not a quiet event for the waitloop
  ## detector (WL_QUIET_EVENTS): every raise and check books one of these.
  when WL_QUIET_EVENTS: intr.gba.wl_unsafe = true
  when IRQ_LAST_WAITS:
    let bus = intr.gba.bus
    bus.sync_bits = bus.sync_bits or 8
    bus.fetch_key = 0xFFFFFFFF'u32

proc window_open_event*(intr: Interrupts) =
  intr.win_open_at = high(CycleCount)
  intr.window_open()

proc window_close_event*(intr: Interrupts) =
  ## The guard close: a raise the window was opened for never came.
  intr.win_close_at = high(CycleCount)
  if not intr.gba.scheduler.has_event(etInterrupts):
    when WL_QUIET_EVENTS:
      if (intr.gba.bus.sync_bits and 8) != 0: intr.gba.wl_unsafe = true
    intr.gba.bus.sync_bits = intr.gba.bus.sync_bits and not 8'u8

const IRQ_WINDOW_LEAD* = 16
  ## How far ahead of a raise whose cycle is known (a timer overflow, the
  ## PPU's line events) the window opens, so that an instruction spanning
  ## both the raise and the recognition had its accesses noted: a raise in
  ## the middle of a six-cycle EWRAM fetch is recognised before it ends.
  ## Enough for irqwait.s's every cell; each cycle of it costs a little
  ## (FireRed, same work: +0.06% retired instructions at 16, +0.14% at 32).

proc window_ahead*(intr: Interrupts; raise_in: int) =
  ## A source will raise an interrupt `raise_in` cycles from now.
  when IRQ_LAST_WAITS:
    # One pending open (the soonest) and one close (the latest) serve every
    # source; a timer overflowing every few cycles books no more.
    let s = intr.gba.scheduler
    if raise_in <= IRQ_WINDOW_LEAD: intr.window_open()
    else:
      let at = s.cycles + CycleCount(raise_in - IRQ_WINDOW_LEAD)
      if at < intr.win_open_at:
        if intr.win_open_at != high(CycleCount): s.clear(etIrqWindowOpen)
        s.schedule(raise_in - IRQ_WINDOW_LEAD, etIrqWindowOpen)
        intr.win_open_at = at
    # Closed by the raise's check; this only guards one that never comes.
    let close_at = s.cycles + CycleCount(raise_in + 2 * IRQ_WINDOW_LEAD)
    if intr.win_close_at == high(CycleCount) or close_at > intr.win_close_at:
      if intr.win_close_at != high(CycleCount): s.clear(etIrqWindowClose)
      s.schedule(raise_in + 2 * IRQ_WINDOW_LEAD, etIrqWindowClose)
      intr.win_close_at = close_at

proc schedule_interrupt_check*(intr: Interrupts; delay: int = 0) =
  ## Book a recognition `delay` cycles out, with the window open until then.
  intr.window_open()
  intr.gba.scheduler.schedule(delay, etInterrupts)

proc schedule_raise_check*(intr: Interrupts; was_set: bool; delay: int) =
  ## The check for a raise of an IF bit, `delay` cycles out -- unless the
  ## raise found the bit already set and a check is booked at or before then:
  ## IF did not change, and that check re-evaluates the same level first (a
  ## write that clears the bit books its own), so this one would only repeat
  ## it. Bookkeeping: back-to-back DMA bursts hold the CPU off the bus and
  ## push every booked check past their end (DMA_STALLS_IRQ_SYNC), so an
  ## H-blank DMA longer than a line, raising its interrupt at the end of each
  ## burst, booked one more check per burst until the event queue overflowed.
  let s = intr.gba.scheduler
  if was_set and s.pending_at(etInterrupts) <= s.cycles + CycleCount(delay):
    return
  intr.schedule_interrupt_check(delay)

# A timer's interrupt goes through a synchroniser before the CPU sees it
# (alyosha irq/IF, irq/IE, both hardware-verified by their author):
# - the raising cycle's own register writes still count: an IF acknowledge
#   or an IE clear landing on it cancels the interrupt, one a cycle later
#   does not;
# - a read on that cycle still finds the IF bit clear;
# - what IE & IF held at the end of that cycle is taken IRQ_SYNC_DELAY
#   cycles later whatever IE and IF do in between.
# The synchroniser runs on the CPU's clock, so it stops while a DMA burst
# holds the CPU off the bus (DMA_STALLS_IRQ_SYNC), but not while the CPU
# runs internal cycles under the burst (alyosha Interactions ReadMe).
# Only timers go through here: the other sources' delays were fitted with
# no synchroniser in front of them (ppu.nim, IRQ_SYNC_DELAY's other users).

proc stalled_for(intr: Interrupts; now: CycleCount): int {.inline.} =
  ## Cycles until the CPU runs again when `now` falls inside the span the
  ## last burst stalled it. Catch-up dispatches an event raised under a
  ## burst after the burst, so this is where one learns it was stalled.
  if now >= intr.stall_from and now < intr.stall_to: int(intr.stall_to - now)
  else: 0

proc raise_synced*(intr: Interrupts; bit: int; late = 0) =
  ## `late`: the raise belongs to a cycle that far ahead of now (a timer's
  ## enable over 0xFFFF overflows when the timer starts, not at the write).
  let now = intr.gba.scheduler.cycles + CycleCount(late)
  when defined(itrace):
    itl("RAISE " & $bit & " t=" & $now & " stalled=" & $intr.stalled_for(now))
  if intr.pipe_raised == 0:
    let st = intr.stalled_for(now)
    let delay = if st == 0: IRQ_SYNC_DELAY
                else: max(IRQ_SYNC_DELAY, st + IRQ_SYNC_DELAY - UNDER_BURST_CREDIT)
    intr.pipe_bits = 0
    intr.pipe_sampled = false
    intr.pipe_at = now
    intr.pipe_due = now + CycleCount(delay)
    # Only a bit this raise sets is hidden from a read on its cycle.
    intr.pipe_new = (1'u16 shl bit) and not uint16(intr.reg_if)
    intr.schedule_interrupt_check(delay + late)
  # A raise while another is in flight rides with it, on that one's check:
  # a timer overflowing every cycle would otherwise push the recognition out
  # forever, and under a long burst (every raise waiting for its end) book
  # one check per raise until the event queue overflows.
  intr.pipe_raised = intr.pipe_raised or (1'u16 shl bit)
  intr.set_interrupt_flag(bit)

proc pipe_sample(intr: Interrupts; now: CycleCount) {.inline.} =
  ## Take IE & IF into the synchroniser once the raising cycle is over (before
  ## the first register write after it, or at the recognition itself).
  if intr.pipe_raised != 0 and not intr.pipe_sampled and now > intr.pipe_at:
    intr.pipe_bits = uint16(intr.reg_ie) and uint16(intr.reg_if)
    intr.pipe_sampled = true

proc unstall*(intr: Interrupts; ran: int) =
  ## The CPU ran `ran` internal cycles under the last burst, from its start
  ## (bus.idle_window): the synchroniser was not stopped for them.
  when DMA_STALLS_IRQ_SYNC:
    if ran <= 0: return
    let now = intr.gba.scheduler.cycles + CycleCount(intr.gba.bus.cycles)
    let new_from = min(intr.stall_to, intr.stall_from + CycleCount(ran))
    if intr.stall_pushed:
      # A recognition the burst pushed back gets those cycles back
      # (Internal_Cycle_DMA_IRQ_ldr_IWRAM, _IRQ_7).
      intr.gba.scheduler.advance_pending(etInterrupts, now, CycleCount(ran))
      if intr.pipe_raised != 0 and intr.pipe_due > now:
        intr.pipe_due = max(now + 1, intr.pipe_due - CycleCount(ran))
    elif intr.pipe_raised != 0 and intr.pipe_at >= intr.stall_from and
         intr.pipe_at < new_from:
      # Raised while those cycles ran: it counted until the CPU stopped, and
      # only the rest waits for the burst's end. Recognised before the burst
      # ends, it is taken at the next boundary (Internal_Cycle_DMA_MUL_IRQ:
      # a timer overflowing inside a multiply's internal cycles under an
      # H-blank DMA interrupts the instruction after the multiply).
      let k = new_from - intr.pipe_at
      let due = if k >= CycleCount(IRQ_SYNC_DELAY): intr.pipe_at + CycleCount(IRQ_SYNC_DELAY)
                else: intr.stall_to + CycleCount(IRQ_SYNC_DELAY) - k
      if due < intr.pipe_due:
        intr.gba.scheduler.advance_pending(etInterrupts, now - 1,
                                           intr.pipe_due - due)
        intr.pipe_due = max(now, due)
    intr.stall_from = new_from

proc irq_deliverable*(intr: Interrupts): bool {.inline.} =
  intr.ime and (uint16(intr.reg_ie) and uint16(intr.reg_if)) != 0

proc gate_opened*(intr: Interrupts) =
  ## A register write made a parked interrupt deliverable: drop the
  ## recognized line and re-recognize IRQ_GATE_DELAY cycles out.
  intr.gba.cpu.irq_line = false
  intr.gate_open_at = intr.gba.scheduler.cycles + CycleCount(IRQ_GATE_DELAY)
  intr.schedule_interrupt_check(IRQ_GATE_DELAY)

proc check_interrupts*(intr: Interrupts) =
  var pending = uint16(intr.reg_ie) and uint16(intr.reg_if)
  if intr.pipe_raised != 0:
    let now = intr.gba.scheduler.cycles
    intr.pipe_sample(now)
    if now >= intr.pipe_due:
      pending = pending or intr.pipe_bits
      intr.pipe_raised = 0
  intr.gba.cpu.irq_line = false
  if pending != 0:
    if intr.gba.cpu.stopped and (pending and STOP_WAKE_MASK) == 0:
      return  # Stop mode ignores other interrupt sources
    if intr.gba.cpu.stopped:
      # Waking from Stop turns the LCD back on without a memory write.
      intr.gba.ppu.render_dirty = true
    if intr.gba.cpu.halted:
      intr.gba.cpu.halt_wake = true
    intr.gba.cpu.stopped = false
    intr.gba.cpu.halted = false
    if intr.ime and intr.gba.scheduler.cycles >= intr.gate_open_at:
      intr.gba.cpu.irq_line = true
      intr.gba.cpu.irq_line_at = intr.gba.scheduler.cycles
      when defined(itrace):
        itl("ILINE t=" & $intr.gba.scheduler.cycles & " dot=" &
            $(int64(intr.gba.scheduler.cycles) - intr.gba.ppu.line_start_cycle) &
            " pend=" & toHex(pending, 4))
  when IRQ_LAST_WAITS:
    # The instruction this check landed in has noted its last access; the
    # window closes unless another check is still to run (a pending open
    # reopens it for the next raise).
    if not intr.gba.scheduler.has_event(etInterrupts):
      when WL_QUIET_EVENTS:
        if (intr.gba.bus.sync_bits and 8) != 0: intr.gba.wl_unsafe = true
      intr.gba.bus.sync_bits = intr.gba.bus.sync_bits and not 8'u8

proc `[]`*(intr: Interrupts; io_addr: uint32): uint8 =
  case io_addr
  of 0x200..0x201: read(intr.reg_ie, io_addr and 1)
  of 0x202..0x203:
    var v = uint16(intr.reg_if)
    if intr.pipe_raised != 0 and
       intr.gba.scheduler.cycles + CycleCount(intr.gba.bus.cycles) <= intr.pipe_at:
      v = v and not intr.pipe_new
    read(cast[InterruptReg](v), io_addr and 1)
  of 0x208: (if intr.ime: 1'u8 else: 0'u8)
  of 0x209: 0'u8
  else: raise newException(Exception, "Unimplemented interrupts read addr: " & hex_str(uint8(io_addr)))

proc `[]=`*(intr: Interrupts; io_addr: uint32; value: uint8) =
  intr.pipe_sample(intr.gba.scheduler.cycles + CycleCount(intr.gba.bus.cycles))
  let was_deliverable = intr.irq_deliverable
  case io_addr
  of 0x200..0x201: write(intr.reg_ie, value, io_addr and 1)
  of 0x202..0x203:
    let v = uint16(value) shl (8 * (io_addr and 1))
    intr.reg_if = cast[InterruptReg](uint16(intr.reg_if) and not v)
  of 0x208: intr.ime = bit(value, 0)
  of 0x209: discard
  else: raise newException(Exception, "Unimplemented interrupts write addr: " & hex_str(uint8(io_addr)) & " val: " & hex_str(value))
  if intr.irq_deliverable and not was_deliverable and
     not intr.gba.cpu.cpsr.irq_disable:
    # Gate opened with CPSR.I clear: late recognition. With I set,
    # recognition waits on the exception return, which is fast (mGBA suite
    # multi-IRQ Timer count-up rows).
    intr.gate_opened()
  else:
    # Clears re-evaluate immediately; check_interrupts holds irq_line off
    # until gate_open_at, so the second byte of a halfword IME/IE store
    # cannot recognize early.
    intr.schedule_interrupt_check()
