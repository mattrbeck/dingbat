# GB SM83 CPU (included by gb.nim)

proc new_gb_cpu*(): GbCpu =
  GbCpu(pc: 0, sp: 0, ime: false, halted: false, halt_bug: false,
        locked: false, stopped: false, cached_hl: -1, wl_head: -1)

proc skip_boot*(cpu: GbCpu; gb: GB) =
  # Registers at PC=0x100 per model (mooneye boot_regs-*, misc/boot_regs-*;
  # Pan Docs, "Power-Up Sequence").
  cpu.pc = 0x0100
  cpu.sp = 0xFFFE
  case gb.boot_model
  of bmDmg0:
    cpu.af = 0x0100; cpu.bc = 0xFF13; cpu.de = 0x00C1; cpu.hl = 0x8403
  of bmDmgABC, bmMgb:
    # H and C carry the header-checksum compare: both set unless $014D is $00
    # (Pan Docs, "Power-Up Sequence" [^dmg_c]).
    let rom = gb.cartridge.rom
    let f = 0x80'u16 or (if rom.len > 0x014D and rom[0x014D] == 0: 0'u16
                         else: 0x30'u16)
    cpu.af = (if gb.boot_model == bmMgb: 0xFF00'u16 else: 0x0100'u16) or f
    cpu.bc = 0x0013; cpu.de = 0x00D8; cpu.hl = 0x014D
  of bmSgb:
    cpu.af = 0x0100; cpu.bc = 0x0014; cpu.de = 0x0000; cpu.hl = 0xC060
  of bmSgb2:
    cpu.af = 0xFF00; cpu.bc = 0x0014; cpu.de = 0x0000; cpu.hl = 0xC060
  of bmCgb0, bmCgbABCDE, bmAgb:
    # A=0x11; the AGB boot ROM's extra `INC B` gives B=0x01, F=0x00 instead of
    # B=0x00, F=0x80. D/E/H/L depend on the cart's CGB flag (mooneye
    # misc/boot_regs-cgb vs -A).
    if gb.cgb_flag != cgbNone:
      if gb.boot_model == bmAgb:
        cpu.af = 0x1100; cpu.bc = 0x0100
      else:
        cpu.af = 0x1180; cpu.bc = 0x0000
      cpu.de = 0xFF56; cpu.hl = 0x000D
    else:
      # DMG cart on CGB/AGB: B, F and HL come from the header (Pan Docs,
      # "Power-Up Sequence" [^cgbdmg_b]/[^cgbdmg_hl]/[^agbdmg_f]). For a
      # Nintendo-licensee cart B is the title bytes summed (the colorization
      # hash); the AGB's `inc b` follows and its Z/H land in F. HL = $991A
      # marks the two logo-animation palette IDs.
      let rom = gb.cartridge.rom
      var b = 0'u8
      if rom.len > 0x0145 and
         (rom[0x014B] == 0x01 or
          (rom[0x014B] == 0x33 and rom[0x0144] == 0x30 and rom[0x0145] == 0x31)):
        for i in 0x0134 .. 0x0143: b = b + rom[i]
      if gb.boot_model == bmAgb:
        let half = (b and 0x0F) == 0x0F
        b = b + 1
        cpu.af = 0x1100'u16 or (if b == 0: 0x80'u16 else: 0'u16) or
                               (if half:   0x20'u16 else: 0'u16)
        cpu.hl = if b in [0x44'u8, 0x59'u8]: 0x991A'u16 else: 0x007C'u16
      else:
        cpu.af = 0x1180
        cpu.hl = if b in [0x43'u8, 0x58'u8]: 0x991A'u16 else: 0x007C'u16
      cpu.bc = uint16(b) shl 8
      cpu.de = 0x0008

proc cpu_memory_at_hl*(cpu: GbCpu; gb: GB): uint8 =
  if cpu.cached_hl < 0:
    cpu.cached_hl = int(mem_read(gb.memory, gb, int(cpu.hl)))
  uint8(cpu.cached_hl)

proc `cpu_memory_at_hl=`*(cpu: GbCpu; gb: GB; val: uint8) =
  cpu.cached_hl = int(val)
  mem_write(gb.memory, gb, int(cpu.hl), val)

proc cpu_inc_pc*(cpu: GbCpu) =
  if cpu.halt_bug:
    cpu.halt_bug = false
  else:
    cpu.pc = cpu.pc + 1

when HDMA_GRANT_FETCH_DOTS >= 0:
  proc hdma_grant(gb: GB; slack: int32) {.noinline.} =
    ## An owed HBlank block taking the bus at one of the CPU's three hand-over
    ## points: the end of an opcode fetch, an instruction boundary, or a HALT.
    ## `slack` is the dots of allowance the point gets over the request dot.
    let ppu = gb.ppu
    # A request an FF55 write raised in mode 0 stands after mode 0 ends
    # (HDMA_START_GRANT_FETCH).
    let start_req = gb.hdma_start_req
    if ppu.hdma_active and ((ppu.lcd_status and 3'u8) == 0'u8 or start_req):
      # `high(int32)` = owed to a halted CPU, waiting for its wake. Reaching a
      # fetch or boundary means the CPU is running and that wake has passed
      # (armed by the dispatch's own dots), so the debt is owed now
      # (gambatte dma/hdma_ei_m3halt_m0unhalt_ly_2).
      if ppu.hdma_due_deadline == high(int32):
        ppu.hdma_due_deadline = ppu.cycle_counter
      when defined(gb_dma_trace):
        echo "GRANT? dot=", ppu.cycle_counter, " slack=", slack, " dl=", ppu.hdma_due_deadline
      if ppu.cycle_counter + slack >= ppu.hdma_due_deadline or
         (start_req and (ppu.lcd_status and 3'u8) != 0'u8):
        gb.hdma_start_req = false
        ppu_step_hdma(ppu, gb, in_cpu_cycle = HDMA_GRANT_FETCH_HOLD)
    else:
      gb.hdma_start_req = false
      ppu.hdma_block_due = false

const HALT_IME_PENDING_REDO* {.intdefine.} = 1
  ## A HALT that finds IME on and IF & IE != 0 does not halt: the opcode after
  ## it was fetched without moving PC, the dispatch undoes that fetch and
  ## pushes the HALT's own address, and RETI runs the HALT again (the halt
  ## bug's IME-on shape; gambatte-core models it as the prefetch undo).
  ## gambatte `halt/late_m0int_halt_m0stat_scx{2,3}_3a` (both devices) and
  ## `scx3_3b` [dmg] halt again after the handler; 0 returns past the HALT.
const DMG_HALT_MIN_MCYCLES* {.intdefine.} = 2
  ## Halted M-cycles a DMG spends before a pending interrupt can end the HALT:
  ## an interrupt raised during the HALT's first M-cycle is answered at the
  ## end of the second. gambatte `halt/late_m0{int,irq}_halt_m0stat_scx3_2b`
  ## [dmg] want 2; 3 loses six `_1b`/`_2a` rows. The CGB's side of this is
  ## CGB_HALT_PPU_LEAD.
proc cpu_halt*(cpu: GbCpu; gb: GB) =
  ## Pan Docs, "Halt Bug": with IME = 0 and IF & IE != 0 the CPU does not halt
  ## and PC fails to increment for the next instruction. The IME that decides
  ## it is the one the HALT was FETCHED with: EI raises IME 4 T-cycles later,
  ## inside the HALT's own fetch (gambatte halt/ifandie_ei_halt_sra prints
  ## $0A only with the bug armed; SameSuite interrupt/ei_delay_halt).
  let ime_at_fetch = cpu.ime and
    cpu.ime_set_cycle + CycleCount(4) <= gb.scheduler.cycles
  if not ime_at_fetch and interrupt_ready(gb.interrupts):
    cpu.halt_bug = true
    cpu.halted   = false
  elif HALT_IME_PENDING_REDO != 0 and cpu.ime and interrupt_ready(gb.interrupts):
    # IME on and a request already up: the HALT does not halt; its fetch of
    # the next opcode is undone by the dispatch, which pushes the HALT's own
    # address (dispatch_interrupt's halt-bug path), so RETI runs it again.
    cpu.halt_bug = true
    cpu.halted   = false
  else:
    cpu.halted = true
    when DMG_HALT_MIN_MCYCLES > 1: gb.halt_start = gb.scheduler.cycles
    when HDMA_GRANT_FETCH_DOTS >= 0:
      # The third hand-over point, the HALT: charged at the HALT's fetch rather
      # than per halted M-cycle (at most 4 dots apart, row-for-row identical,
      # and free for a HALT-idling title). A block owed to an already halted
      # CPU carries a high(int32) deadline and is paid at the wake instead
      # (gambatte dma/hdma_late_m3halt_m2unhalt_scx2_2).
      if unlikely(gb.ppu.hdma_block_due) and
         gb.ppu.hdma_due_deadline != high(int32):
        when HDMA_HALT_DEFERS_DUE != 0:
          # The HALT finds the request pending and parks it for the wake
          # (HDMA_HALT_REQ_DOTS' "requested" state), with its prefetch.
          if gb.ppu.hdma_active and (gb.ppu.lcd_status and 3'u8) == 0'u8:
            gb.ppu.hdma_due_deadline = high(int32)
            gb.hdma_due_forced = true
            gb.hdma_prefetch_op = int16(gb.memory.read_byte(gb, int(cpu.pc)))
          else:
            gb.ppu.hdma_block_due = false
        else:
          hdma_grant(gb, int32(HDMA_GRANT_FETCH_DOTS))
    when HDMA_HALT_M0_BLIND != 0:
      # The dot the VRAM DMA's HBlank edge detector stops being clocked on
      # (HDMA_HALT_M0_BLIND in gb.nim).
      gb.ppu.hdma_halt_dot = gb.ppu.cycle_counter
    when defined(gb_dma_trace):
      echo "HALT ly=", gb.ppu.ly, " dot=", gb.ppu.cycle_counter,
           " mode=", (gb.ppu.lcd_status and 3'u8)

proc cpu_lock*(cpu: GbCpu) =
  ## The SM83's undefined-opcode lockup (Pan Docs, "CPU Instruction Set": only
  ## a reset ends it). `halted` keeps the machine ticking as in HALT (the
  ## gambatte undef_ops ROMs read back a real frame); sticky `locked` stops
  ## handle_interrupts clearing `halted` and is only tested on the halted
  ## path. STOP mode reuses the pair plus `stopped`, and cpu_stop_tick is the
  ## only thing that clears `locked`.
  cpu.halted = true
  cpu.locked = true

const IRQ_PUSH_T* {.intdefine.} = 12
  ## T-cycles of internal wait charged before the dispatch's two push
  ## M-cycles. Ships 12 with IRQ_PUSH_LATE: three waits, then the pushes, the
  ## low one being the dispatch's last M-cycle (gambatte-core's order). 0
  ## (pushes first) and 8 (Pan Docs' wait-wait-push-push-jump) score alike
  ## everywhere but on an OAM DMA's bus: gambatte `oamdma/oamdma_src0000_
  ## busyint0002` (both devices) reads the pushed PC back from DMA slots
  ## $9E/$9F, three M-cycles after where pushes-first puts it.
const IRQ_PUSH_LATE* {.intdefine.} = 1
  ## With IRQ_PUSH_T = 12: the low push is split at the IF clear
  ## (IRQ_SAMPLE_T, plus IRQ_SAMPLE_CGB_TIMER_SERIAL_ADD), so the clear keeps
  ## its T-cycle inside the push's M-cycle (mem_write_split). Without the
  ## split the clear moves to 20 and 19 rows are lost.
static:
  doAssert IRQ_PUSH_LATE == 0 or IRQ_PUSH_T == 12,
    "IRQ_PUSH_LATE splits the dispatch's last M-cycle; it needs IRQ_PUSH_T = 12"

const IRQ_SAMPLE_T_DS* {.intdefine.} = 18
  ## IRQ_SAMPLE_T for a dispatch taken in double speed, in CPU T-cycles: 18,
  ## as single speed, since STAT_M0_LEAD_DS's joint move (16 and 20 lose there;
  ## it was 16 with the one-dot lead). An odd value is off the dot grid
  ## (17/17 loses 150 `_ds_` rows), and 20 flips every `_ds_1`
  ## *_late_retrigger arm the other way.
const IRQ_SAMPLE_T* {.intdefine.} = 18
  ## T-cycles into the 5 M-cycle interrupt dispatch at which the taken line's
  ## IF bit is cleared: inside the fifth M-cycle, after the two waits and two
  ## pushes (Pan Docs, "Interrupt Handling"). Only the clear is here; which
  ## line is taken is decided between the push bytes (dispatch_interrupt;
  ## mooneye acceptance/interrupts/ie_push).
  ##
  ## Bracket: gambatte *_late_retrigger (six STAT sources and the timer, both
  ## devices) re-request the handler's own interrupt one M-cycle later per
  ## member and read IF inside the second dispatch, so each family measures
  ## the clear against its source's next rise. 16 (the fifth M-cycle's first
  ## T) loses the `_2` arms of ly0/lycint152_lyc0irq and irq_precedence/
  ## late_m0irq_retrigger, whose sources rise mid-M-cycle (the snapback's
  ## LYC = 0 match, the mode-0 source at STAT_M0_LEAD_T); 17 takes only the
  ## first pair; 18 takes both (+4); 19 loses late_m0irq_retrigger_scx1_1,
  ## and 20 also m2int_m2irq_late_retrigger_1 (both devices).
  ##
  ## Open (docs/gb-failure-triage.md A2): the `_2` arms of the LYC-, mode-1-
  ## and timer-first families (12 rows) want the clear at 20 while the mode-2-
  ## first families want it below 19, one full M-cycle apart with the same
  ## handler bytes. The dispatch cannot be in two places, so those sources
  ## reach the dispatch one M-cycle later, relative to the instant IF rises,
  ## than the mode-2 source does. Settling the per-source rise phases (A3) is
  ## what moves them, not this constant.
when HDMA_EDGE_BEATS_DISPATCH != 0:
  proc hdma_edge_lookahead(gb: GB) {.noinline.} =
    ## HDMA_EDGE_BEATS_DISPATCH: mode 3 retiring on this very dot raises the
    ## HBlank request now, and it takes the bus ahead of the dispatch.
    fifo_sync(gb)
    if gb.ppu.hdma_active and not gb.ppu.hdma_block_due and
       gb.fifo_ppu != nil and (gb.ppu.lcd_status and 3'u8) == 3'u8 and
       fetcher_retired(gb.fifo_ppu) and gb.fifo_ppu.m3_hold == 0:
      ppu_step_hdma(gb.ppu, gb)

const IRQ_VECTOR_T* {.intdefine.} = 16
  ## T-cycles into the dispatch at which the vector is chosen: after the high
  ## push, inside the fifth M-cycle's lead-in (gambatte-core picks it at the
  ## low push's cycle, 16 in), so a request rising in the dispatch's fourth
  ## M-cycle still wins on priority. IE is the value the high push left, and
  ## a low push aimed at IF decides ahead of its own byte. gambatte
  ## `irq_precedence/late_m0irq_vs_tima_scx{2,3}{,_halt}_1` (both devices: the
  ## mode-0 request rises 16 T in, beats the timer, and the handler reads the
  ## timer bit still set); 14 and 18 lose four, 4 (the old choice after the
  ## high push) takes none of them.
const IRQ_SAMPLE_CGB_TIMER_SERIAL_ADD* {.intdefine.} = 2
  ## T-cycles past IRQ_SAMPLE_T at which a CGB dispatch clears a TIMER or
  ## SERIAL request: those two lines are acknowledged later than the LCD
  ## ones, so a timer or serial request raised in the dispatch's last T-cycles
  ## is still taken back. gambatte `tima/tc00_irq_late_retrigger_3` [cgb] and
  ## `serial/start_wait_trigger_int8_read_if_2` [cgb]; 0 and 1 take neither,
  ## and above 2 the clear would fall outside the dispatch's 20 T. One-sided:
  ## `tc00_irq_late_retrigger_2` [cgb] wants the timer later still, i.e. its
  ## request rises later here than on hardware (A2).
proc dispatch_interrupt(cpu: GbCpu; gb: GB) {.noinline.} =
  ## The taken half of handle_interrupts: push PC, vector, charge 5 M-cycles.
  ## Out of line: two inlined mem_writes give handle_interrupts a prologue
  ## paid on every non-taken call (+0.8% retired instructions).
  when HDMA_EDGE_BEATS_DISPATCH != 0:
    # Here and not in handle_interrupts, which is inlined into `tick`: the
    # call there cost +0.4% retired instructions on a title with no HDMA.
    hdma_edge_lookahead(gb)
  cpu.ime = false
  # An armed halt bug is spent here when the dispatch follows the HALT
  # (EI; HALT with IF & IE != 0): the pushed address is the HALT's own, so
  # the bug recurs on the RET (gambatte halt/ifandie_ei_halt_sra). Holding
  # the dispatch off instead moves ifandie_ei_halt_m2int_m0stat_1 an M-cycle.
  if cpu.halt_bug:
    cpu.halt_bug = false
    cpu.pc = cpu.pc - 1
  when defined(gb_ss_trace):
    echo "IRQDISP tdiv=", gb.timer.tdiv, " pc=", toHex(cpu.pc, 4)
  when defined(gb_irq_trace):
    # One line per interrupt taken, with the PPU dot (diagnostic, tools only).
    if gb.fifo_ppu != nil:
      echo "IRQ ly=", gb.fifo_ppu.ly, " dot=", gb.fifo_ppu.cycle_counter,
           " if=", toHex(irq_read(gb.interrupts, 0xFF0F), 2),
           " pc=", toHex(cpu.pc, 4)
  when IRQ_PUSH_T > 0:
    mem_tick_components(gb.memory, gb, IRQ_PUSH_T)
  # The same OAM-bug M-cycles as PUSH (cpu_push16; Pan Docs lists interrupt
  # handling with it).
  oam_bug_if(gb, cpu.sp, obWrite)
  cpu.sp = cpu.sp - 1
  oam_bug_if(gb, cpu.sp, obWrite)
  mem_write(gb.memory, gb, int(cpu.sp), uint8(cpu.pc shr 8))
  # Which line is taken is decided between the two push bytes, not at the
  # clear below: gambatte irq_precedence/if_and_ie_0_vector pushes over $FFFF
  # and vectors to $0000 from SP = $0000 (new IE seen) but $0050 from $0001.
  when IRQ_VECTOR_T <= 4 + IRQ_PUSH_T:
    let interrupt = highest_priority(gb.interrupts)
  else:
    # The vector is chosen IRQ_VECTOR_T into the dispatch, against the IE the
    # high push left (the low push's own byte is not seen). A low push onto
    # IF itself decides here, ahead of its byte (irq_precedence/
    # if_and_ie_0_vector_4).
    let ie_hi = irq_read(gb.interrupts, 0xFFFF)
    let early_irq = highest_priority(gb.interrupts)
    # Only a timer, serial or joypad choice can still be overtaken; the split
    # tick costs every other dispatch (0.24% retired instructions).
    let early = (cpu.sp - 1) == 0xFF0F'u16 or early_irq == INT_VBLANK or
                early_irq == INT_STAT
  cpu.sp = cpu.sp - 1
  oam_bug_if(gb, cpu.sp, obWrite)
  when IRQ_PUSH_LATE != 0:
    # The low push is the dispatch's last M-cycle; the IF clear falls inside
    # it (IRQ_PUSH_LATE).
    let sample_t0 =
      if gb.memory.current_speed == 1: IRQ_SAMPLE_T_DS else: IRQ_SAMPLE_T
    when IRQ_VECTOR_T > 4 + IRQ_PUSH_T:
      let interrupt = if early: early_irq
                      else: highest_priority_ie(gb.interrupts, ie_hi)
    var sample_t1 = sample_t0
    when IRQ_SAMPLE_CGB_TIMER_SERIAL_ADD != 0:
      if gb.cgb_enabled and (interrupt == INT_TIMER or interrupt == INT_SERIAL):
        sample_t1 += IRQ_SAMPLE_CGB_TIMER_SERIAL_ADD
    let pre = max(0, min(4, sample_t1 - 16))
    mem_write_split(gb.memory, gb, int(cpu.sp), uint8(cpu.pc and 0xFF), pre)
    cpu.pc = interrupt
    clear_interrupt(gb.interrupts, interrupt)
    when TIMER_ACK_LOOKAHEAD != 0:
      if interrupt == INT_TIMER:
        const k = TIMER_ACK_LOOKAHEAD
        let t = gb.timer
        var due = -1
        if t.countdown > 0: due = t.countdown
        elif t.enabled and t.tima == 0xFF'u8:
          let period = 1 shl (t.bit_for_tima + 1)
          due = period - (int(t.tdiv) and (period - 1)) + 4
        if due > 0 and due <= k:
          gb.timer_irq_acked = true
    mem_write_finish(gb.memory, gb, 4 - pre)
    mem_tick_extra(gb.memory, gb, 20)
    return
  mem_write(gb.memory, gb, int(cpu.sp), uint8(cpu.pc and 0xFF))
  var elapsed = 8 + IRQ_PUSH_T
  when IRQ_VECTOR_T > 4 + IRQ_PUSH_T:
    if IRQ_VECTOR_T > elapsed and not early:
      mem_tick_components(gb.memory, gb, IRQ_VECTOR_T - elapsed)
      elapsed = IRQ_VECTOR_T
    let interrupt = if early: early_irq
                    else: highest_priority_ie(gb.interrupts, ie_hi)
  cpu.pc = interrupt
  # Run out to the sample point before clearing IF (IRQ_SAMPLE_T). One call,
  # not one per M-cycle.
  let sample_t =
    if gb.memory.current_speed == 1: IRQ_SAMPLE_T_DS else: IRQ_SAMPLE_T
  if sample_t > elapsed:
    mem_tick_components(gb.memory, gb, sample_t - elapsed)
  when IRQ_SAMPLE_CGB_TIMER_SERIAL_ADD != 0:
    if gb.cgb_enabled and (interrupt == INT_TIMER or interrupt == INT_SERIAL):
      mem_tick_components(gb.memory, gb, IRQ_SAMPLE_CGB_TIMER_SERIAL_ADD)
  clear_interrupt(gb.interrupts, interrupt)
  when TIMER_ACK_LOOKAHEAD != 0:
    # A timer request due within the lookahead is acknowledged with this one.
    if interrupt == INT_TIMER:
      const k = TIMER_ACK_LOOKAHEAD
      let t = gb.timer
      var due = -1
      if t.countdown > 0: due = t.countdown
      elif t.enabled and t.tima == 0xFF'u8:
        let period = 1 shl (t.bit_for_tima + 1)
        due = period - (int(t.tdiv) and (period - 1)) + 4
      if due > 0 and due <= k:
        gb.timer_irq_acked = true
  mem_tick_extra(gb.memory, gb, 20)

proc handle_interrupts*(cpu: GbCpu; gb: GB) =
  # The running CPU's test: the timer's request reaches it one M-cycle ahead
  # of everyone else's view of IF (TIMER_IRQ_RUN_LEAD in gb.nim; inert at 0).
  if interrupt_ready_run(gb.interrupts):
    # STOP mode is entered with an interrupt pending on one of its leaves
    # (Pan Docs' STOP chart; daid stop_instr.gb) and only a joypad line ends
    # it, so this must not un-halt the CPU the M-cycle STOP retires.
    if cpu.stopped: return
    when defined(gb_dispatch_trace):
      if cpu.ime and highest_priority(gb.interrupts) == INT_STAT:
        echo "DISPATCH ly=", gb.ppu.ly, " cc=", gb.ppu.cycle_counter,
             " raised=", gb.ppu.stat_if_dot, " ds=", gb.memory.current_speed
    when STAT_DISPATCH_MIN_AGE_DS != 0:
      # A STAT request younger than the threshold waits a boundary at double
      # speed (STAT_DISPATCH_MIN_AGE_DS, gb.nim), unless something else is up.
      if gb.memory.current_speed != 0'u8 and gb.ppu.stat_if_m0 and
         highest_priority(gb.interrupts) == INT_STAT and
         gb.ppu.ly == gb.ppu.stat_if_ly and
         gb.ppu.cycle_counter - gb.ppu.stat_if_dot < STAT_DISPATCH_MIN_AGE_DS:
        return
    when STOP_OPERAND_LATCH != 0:
      # A dispatch discards STOP's latched opcode; the pushed PC is its byte's
      # address, re-fetched on return.
      if gb.stop_op_latch > 0:
        gb.stop_op_latch = 0
        cpu.locked = false
    cpu.halted = false
    if cpu.ime: dispatch_interrupt(cpu, gb)

# Where inside an M-cycle a HALTED CPU latches the interrupt line. A running
# CPU asks after all four T-cycles. GBMicrotest int_hblank_nops_scx0..7 vs
# int_hblank_halt_scx0..7 walk the mode-0 edge across two M-cycles and the
# halt half is one M-cycle late exactly when the flag rises on T 2 or 3, so
# the halted latch sits at the M-cycle's midpoint; the int_lyc, int_vblank1
# and int_timer pairs (head sources) are level and int_oam (tail) differs by
# one. A uniform "halt costs one M-cycle" cannot produce four-and-four.
# Ships at 4 anyway: mooneye acceptance/ppu/hblank_ly_scx_timing-GS goes red
# at 2 (it times the dispatch against LY rather than TIMA and the two disagree
# by this M-cycle; an LY read-side lag does not fix it and costs seven
# GBMicrotest LY rows). At 2 the split also doubles the PPU tick calls of
# every halted M-cycle (+4.8% retired instructions on a HALT-idling title).
const HALT_IF_SAMPLE_T* {.intdefine.} = 4
  ## T-cycles into a halted M-cycle at which the interrupt line is latched.
  ## 4 is the M-cycle's end (ships; compiles the split out); 2 is the
  ## GBMicrotest measurement above.

# STAT_M2_LEAD (ppu.nim) moves the mode 2 STAT source one M-cycle ahead of
# the line boundary, and every instrument deriving it has the CPU running.
# The five halted mooneye acceptance/interrupts/intr_2_* ROMs (hardware-
# verified on every model) say a halted CPU does not see the lead: with it on
# and no blinding all five collapse onto their late arm. So the source rises
# in the tail of its M-cycle and a halted CPU catches it at the boundary,
# the same classification HALT_IF_SAMPLE_T's table makes for the OAM source.
# On the CGB, CGB_HALT_PPU_LEAD already pays for it: blinding there too
# fails all five intr_2_* on CGB C and E and gambatte halt/noime_m2irq_
# m0stat_1 [cgb]; DMG-only passes all six (M2_LEAD_HALT_BLIND_DMG_ONLY).
const M2_LEAD_HALT_BLIND* {.booldefine.} = true
  ## Whether a HALTED CPU is blind to the mode 2 STAT source for the
  ## STAT_M2_LEAD M-cycles it leads the line boundary by. Ships on with
  ## STAT_M2_LEAD; false is the control build.
const M2_LEAD_HALT_BLIND_DMG_ONLY* {.intdefine.} = 1
  ## The blindness on DMG-family machines only (see above). 0 = both.

when STAT_M2_EARLY and M2_LEAD_HALT_BLIND:
  proc halt_m2_lead_blind(gb: GB): bool {.noinline.} =
    ## Is the interrupt line up only because the OAM source is inside its lead
    ## window? Approximate in one direction: a STAT bit raised earlier by
    ## another source and re-masked mid-halt by an IE write is deferred too.
    when M2_LEAD_HALT_BLIND_DMG_ONLY != 0:
      if gb.cgb_enabled: return false
    let irq = gb.interrupts
    if not (irq.lcd_stat_interrupt and irq.lcd_stat_enabled): return false
    if (irq.vblank_interrupt and irq.vblank_enabled) or
       (irq.timer_interrupt  and irq.timer_enabled)  or
       (irq.serial_interrupt and irq.serial_enabled) or
       (irq.joypad_interrupt and irq.joypad_enabled): return false
    let ppu = gb.ppu
    ppu.lcd_enabled and ppu.oam_interrupt_enabled and
      m2_lead_active(gb) and ppu.m2_early and
      ppu.cycle_counter >= ppu.m2_early_dot(gb)

template halt_lead_live(gb: GB): bool =
  ## Is this halted M-cycle the head of a CGB halt, whose PPU half is held
  ## back (CGB_HALT_PPU_LEAD)? Shared with wl_halt_skip.
  gb.cgb_enabled and
    gb.cpu.halt_ppu_debt < int32(CGB_HALT_PPU_LEAD_DOTS shr gb.memory.current_speed) and
    (when CGB_HALT_LEAD_SKIP_LYC0 != 0:
       not (gb.ppu.lyc == 0'u8 and (gb.ppu.lcd_status and 0x40'u8) != 0'u8)
     else: true) and
    (when CGB_HALT_LEAD_LYC_ONLY != 0:
       # Experiment: is the lead the LYC comparator's alone, absent for a
       # mode-sourced STAT edge (gambatte halt/m0*_m0stat_scx*)?
       (gb.ppu.lcd_status and 0x38'u8) == 0'u8
     else: true)

proc cpu_halt_tick(gb: GB): bool {.inline.} =
  ## One halted M-cycle, answering "does it end with the CPU awake". The whole
  ## M-cycle is spent either way; only the latch point moves.
  when CGB_HALT_PPU_LEAD_ANY:
    # The head of a CGB halt: the bus half runs and the PPU half does not, so
    # the PPU spends the halt one M-cycle of dots behind and the wake pays it
    # back (CGB_HALT_PPU_LEAD in gb.nim): a STAT/LYC/vblank wake lands one
    # M-cycle later in the line while a timer wake, and TIMA, do not move.
    # `halt_ppu_debt` doubles as the per-halt latch. `cgb_enabled` is tested
    # first because a DMG title idling in HALT walks this too (+1.3% retired
    # instructions the other way round). The LY 153 -> 0 snapback wake does
    # not carry the lead: daid ppu_scanline_bgp, whose wake is LYC = 0, is
    # exact only without it; that the lead holds on every other line is
    # assumed; no ROM pins it. Tested last so its loads run once per halt.
    if halt_lead_live(gb):
      let mdots = int32(4 shr gb.memory.current_speed)
      let lead  = int32(CGB_HALT_PPU_LEAD_DOTS shr gb.memory.current_speed)
      # What the head holds back is exactly what the wake pays.
      let take = min(mdots, lead - gb.cpu.halt_ppu_debt)
      gb.cpu.halt_ppu_debt += take
      mem_tick_bus(gb.memory, gb, 4)
      if take < mdots:
        mem_tick_ppu(gb.memory, gb, int(mdots - take), ignore_speed = true)
      mem_reset_cycle_count(gb.memory)
      return interrupt_ready(gb.interrupts)
  when HALT_IF_SAMPLE_T >= 4:
    mem_tick_extra(gb.memory, gb, 4)
    result = interrupt_ready(gb.interrupts)
    when STAT_M2_EARLY and M2_LEAD_HALT_BLIND:
      if result and halt_m2_lead_blind(gb): result = false
    when M0_HALT_BLIND_DOTS > 0 or CGB_M0_HALT_BLIND_DOTS > 0 or
         CGB_M0_HALT_BLIND_DS_DOTS > 0:
      # The mode-0 source's half of the same question (M0_HALT_BLIND_DOTS in
      # ppu.nim; ships at 0).
      if result and halt_m0_tail_blind(gb): result = false
  else:
    # Bus half whole, PPU half split: the timer IRQ is a head source
    # (HALT_IF_SAMPLE_T) and the timer runs its four T-cycles as one step, so
    # the head can only be in front of the latch.
    mem_tick_bus(gb.memory, gb, 4)
    let ly0 = gb.ppu.ly
    mem_tick_ppu(gb.memory, gb, HALT_IF_SAMPLE_T)
    result = interrupt_ready(gb.interrupts)
    mem_tick_ppu(gb.memory, gb, 4 - HALT_IF_SAMPLE_T)
    mem_reset_cycle_count(gb.memory)
    # LY-derived sources are head sources too (GBMicrotest int_lyc_*,
    # int_vblank1_*), but the whole line boundary runs on the line's last dot,
    # after the latch; an LY change in the tail is that case and the only one.
    if not result and gb.ppu.ly != ly0:
      result = interrupt_ready(gb.interrupts)

proc cpu_stop_tick(cpu: GbCpu; gb: GB) {.noinline.} =
  ## One step of STOP mode (stop_instr in memory.nim): nothing is ticked;
  ## mem_tick_stopped only keeps the frontend's frames coming. Pan Docs: "STOP
  ## is terminated by one of the P10 to P13 lines going low" (a zero bit from
  ## joypad_lines). The same edge sets the joypad interrupt, so with IME set
  ## the CPU vectors through tick's ordinary path on the next M-cycle.
  mem_tick_stopped(gb.memory, gb)
  if joypad_lines(gb.joypad) != 0x0F'u8:
    cpu.stopped = false
    cpu.locked  = false
    cpu.halted  = false

when defined(gbfuzz_trace):
  # Instruction trace for tools/gbfuzz; compiled out of normal builds.
  var gbfuzz_trace_hook*: proc(pc: uint16; opcode: uint8) {.closure.}

template cpu_exec_fetched(cpu: GbCpu; gb: GB; opcode: uint8) =
  ## Everything after the opcode fetch: shared by `tick` and the STOP operand
  ## latch's run (cpu_run_latched).
  when HDMA_GRANT_FETCH_DOTS >= 0:
    # Hand-over point 1: an owed block takes the bus at the end of the opcode
    # fetch, never on the operand or data M-cycles (the gambatte two-M-cycle
    # `LD A,[HL]` vs mealybug three-M-cycle `LDH A,[rHDMA5]` split;
    # HDMA_GRANT_FETCH_DOTS in gb.nim).
    if unlikely(gb.ppu.hdma_block_due):
      when GDMA_AFTER_FETCH != 0:
        if gb.gdma_owed:
          gb.gdma_owed = false
          gb.ppu.hdma_block_due = false
          ppu_run_gdma(gb.ppu, gb)
        else: hdma_grant(gb, 0)
      else: hdma_grant(gb, 0)
  when STAT_M0_TAIL_MAX_MC != 0:
    # So stat_read_mode can tell a read on its instruction's second M-cycle
    # from one on its third.
    cpu.cur_opcode = opcode
  let cycles_taken = UNPREFIXED[opcode](cpu, gb)
  cpu.cached_hl = -1
  mem_tick_extra(gb.memory, gb, cycles_taken)
  when HDMA_GRANT_FETCH_DOTS >= 0:
    # Hand-over point 2: the instruction boundary, BEFORE handle_interrupts so
    # a block already owed takes the bus ahead of the dispatch (gambatte
    # irq_precedence/hdma_vs_m0, late_hdma_vs_{ei,ie,tima}: the DMA's source
    # is the stack the dispatch pushes onto).
    if unlikely(gb.ppu.hdma_block_due) and
       (HDMA_HALT_DEFERS_DUE == 0 or not cpu.halted) and
       (GDMA_AFTER_FETCH == 0 or not gb.gdma_owed):
      hdma_grant(gb, int32(HDMA_GRANT_FETCH_DOTS - HDMA_GRANT_BOUNDARY_DOTS))
  when HDMA_STEAL_DELAY_M != 0 and HDMA_STEAL_LEAD_DOTS < 0 and
       HDMA_GRANT_FETCH_DOTS < 0:
    # A block due on a mode-0 edge takes the bus at this boundary after
    # HDMA_STEAL_DELAY_M of them; `in_cpu_cycle` keeps the HDMA_VISIBLE_DOTS
    # hold. Before handle_interrupts, or the whole gambatte irq_precedence
    # hdma_vs_* family is lost.
    if unlikely(gb.ppu.hdma_block_due):
      if gb.ppu.hdma_active and (gb.ppu.lcd_status and 3'u8) == 0'u8:
        if gb.ppu.hdma_due_delay > 0'i8:
          dec gb.ppu.hdma_due_delay
        else:
          ppu_step_hdma(gb.ppu, gb, in_cpu_cycle = true)
      else:
        gb.ppu.hdma_block_due = false
  handle_interrupts(cpu, gb)

proc cpu_halt_wake(cpu: GbCpu; gb: GB) {.noinline.} =
  ## The M-cycle a halt ends on (the line is up). Out of line: none of it runs
  ## on a halted M-cycle, and inline it grew `tick` past clang's inline
  ## threshold for the halted loop (+0.5% retired instructions on a
  ## HALT-idling DMG title).
  when DMG_HALT_MIN_MCYCLES > 1:
    # A DMG HALT answers no earlier than its second M-cycle.
    if not gb.cgb_enabled and
       gb.scheduler.cycles - gb.halt_start < CycleCount(4 * DMG_HALT_MIN_MCYCLES):
      return
  when defined(gb_halt_trace):
    # One line per halt exit, with the PPU dot the CPU resumed on.
    if gb.fifo_ppu != nil:
      echo "HALTWAKE ly=", gb.fifo_ppu.ly, " dot=", gb.fifo_ppu.cycle_counter,
           " mode=", (gb.ppu.lcd_status and 3'u8),
           " if=", toHex(irq_read(gb.interrupts, 0xFF0F), 2),
           " ime=", (if cpu.ime: 1 else: 0)
  # CGB halt-exit charge (CGB_HALT_EXIT_MCYCLES in gb.nim; ships at 0).
  # Here rather than at the dispatch because the IME-clear wakes want it
  # too (gambatte halt/*_irq_*), and ahead of the HBlank DMA block.
  when CGB_HALT_EXIT_MCYCLES != 0:
    if gb.cgb_enabled:
      mem_tick_extra(gb.memory, gb, 4 * CGB_HALT_EXIT_MCYCLES)
  # An HBlank block that came due while halted transfers the moment the
  # CPU is back on the bus, ahead of the dispatch below, and only if the
  # mode 0 that owed it is still running. Copied at the boundary, not
  # inside a CPU access's dots (HDMA_VISIBLE_DOTS, `in_cpu_cycle`).
  when defined(gb_dma_trace):
    echo "WAKE ly=", gb.ppu.ly, " dot=", gb.ppu.cycle_counter,
         " due=", (if gb.ppu.hdma_block_due: 1 else: 0),
         " act=", (if gb.ppu.hdma_active: 1 else: 0),
         " mode=", (gb.ppu.lcd_status and 3'u8)
  when HDMA_WAKE_BLIND_DOTS > 0:
    gb.hdma_wake_dot = gb.ppu.cycle_counter
  let prefetched = ppu_hdma_wake(gb.ppu, gb,
                                prefetch = not cpu.ime or HDMA_HALT_REQ_BUG_IME != 0) and
    HDMA_HALT_REQ_BUG != 0
  when CGB_HALT_PPU_LEAD_ANY:
    # The dots the head of this halt held back, paid with no bus half: a
    # phase, not a charge.
    if gb.cpu.halt_ppu_debt != 0:
      mem_tick_ppu(gb.memory, gb, int(gb.cpu.halt_ppu_debt),
                   ignore_speed = true)
      gb.cpu.halt_ppu_debt = 0
  cpu.halted = false
  when HDMA_EDGE_BEATS_DISPATCH != 0 and HDMA_WAKE_DEBT_RECHECK != 0:
    # A block the debt's dots made due also goes ahead of the dispatch (the
    # dispatch runs HDMA_EDGE_BEATS_DISPATCH's lookahead itself).
    if cpu.ime and gb.ppu.hdma_block_due: ppu_hdma_wake(gb.ppu, gb)
  when HDMA_HALT_REQ_BUG_IME != 0:
    if cpu.ime and prefetched and gb.hdma_prefetch_op >= 0:
      # HDMA_HALT_REQ_BUG_IME: the prefetched opcode runs (PC still on it)
      # before the dispatch.
      let op = uint8(gb.hdma_prefetch_op)
      gb.hdma_prefetch_op = -1
      mem_reset_cycle_count(gb.memory)
      mem_tick_components(gb.memory, gb, 4)
      cpu.halt_bug = true
      cpu_exec_fetched(cpu, gb, op)
      return
  if cpu.ime: dispatch_interrupt(cpu, gb)
  elif prefetched and not cpu.ime and gb.hdma_prefetch_op >= 0:
    # The HALT found the HBlank request pending and had already fetched
    # the next opcode without moving PC past it (HDMA_HALT_REQ_BUG): it
    # runs now, from the prefetch, and PC still points at it.
    let op = uint8(gb.hdma_prefetch_op)
    gb.hdma_prefetch_op = -1
    mem_reset_cycle_count(gb.memory)
    mem_tick_components(gb.memory, gb, 4)
    cpu.halt_bug = true
    let cycles_taken = UNPREFIXED[op](cpu, gb)
    cpu.cached_hl = -1
    mem_tick_extra(gb.memory, gb, cycles_taken)

when STOP_OPERAND_LATCH != 0:
  proc cpu_run_latched(cpu: GbCpu; gb: GB) {.noinline.} =
    ## STOP_OPERAND_LATCH: the byte STOP latched as its next opcode runs now.
    ## The fetch M-cycle is still spent; its byte is not used. Parked behind
    ## `halted`/`locked` so the running CPU's fetch pays nothing for it.
    cpu.halted = false
    cpu.locked = false
    discard mem_read(gb.memory, gb, int(cpu.pc))
    let opcode = uint8(gb.stop_op_latch - 1)
    gb.stop_op_latch = 0
    cpu_exec_fetched(cpu, gb, opcode)

# ==================== IDLE-LOOP SKIP ====================
# A loop that polls memory until an interrupt or the PPU changes it runs the
# same iteration over and over: same registers at the head, no writes, the
# same reads answering the same values. Once one iteration has been seen to
# repeat another, and every read the body can make is of something that only
# changes at a scheduler event, a PPU stop or a timer overflow, the
# iterations up to the next such point are replicas, and the machine is
# advanced over them in one step (mem_tick_components, as the iterations'
# own M-cycles would have). A halted CPU is advanced the same way up to the
# same horizon. -d:gb_idlecheck runs the iterations instead and checks they
# came back to the head unchanged on the cycle the skip would have landed.

type WlScan = object
  ok: bool
  period: int          # CPU cycles of the straight-line iteration
  reads_ly, reads_stat: bool

proc wl_read_ok(gb: GB; a: int; sc: var WlScan): bool =
  ## Is a read of `a` side-effect free, and constant between idle stops?
  case a
  of 0x0000..0x7FFF, 0xC000..0xFDFF, 0xFF80..0xFFFF, 0xFF0F: true
  of 0xFF00: gb.sgb == nil
  of 0xFF44: sc.reads_ly = true; true
  of 0xFF41: sc.reads_stat = true; true
  of 0xFF40, 0xFF42, 0xFF43, 0xFF45, 0xFF47..0xFF4B, 0xFF4D: true
  else: false

proc wl_code_ok(a: int): bool {.inline.} =
  a < 0x8000 or (a >= 0xC000 and a < 0xE000) or (a >= 0xFF80 and a < 0xFFFF)

proc wl_scan(cpu: GbCpu; gb: GB; head, last: int): WlScan =
  ## Decode head..last as one straight line (no internal branch taken) of
  ## side-effect-free instructions ending in the backward branch at `last`.
  ## Anything outside the safe subset rejects the loop.
  if last < head or last - head > 64 or not wl_code_ok(head) or
     not wl_code_ok(last + 2): return
  let mem {.cursor.} = gb.memory
  template rd(a: int): int = int(read_byte(mem, gb, a))
  var pc = head
  var cyc = 0
  while pc <= last:
    let op = rd(pc)
    var len = 1
    var c = 4
    var ra = -1                    # address read, if any
    case op
    of 0x00: discard                                             # NOP
    of 0x07, 0x0F, 0x17, 0x1F, 0x27, 0x2F, 0x37, 0x3F: discard   # A rotates, DAA, CPL, SCF, CCF
    of 0x04, 0x05, 0x0C, 0x0D, 0x14, 0x15, 0x1C, 0x1D,
       0x24, 0x25, 0x2C, 0x2D, 0x3C, 0x3D: discard               # INC/DEC r
    of 0x06, 0x0E, 0x16, 0x1E, 0x26, 0x2E, 0x3E: len = 2; c = 8  # LD r,n
    of 0x01, 0x11, 0x21, 0x31: len = 3; c = 12                   # LD rr,nn
    of 0x0A: ra = int(cpu.bc); c = 8                             # LD A,(BC)
    of 0x1A: ra = int(cpu.de); c = 8                             # LD A,(DE)
    of 0x40..0x6F, 0x78..0xBF:                                   # LD r,r' and ALU A,r
      if (op and 7) == 6: ra = int(cpu.hl); c = 8
    of 0xC6, 0xCE, 0xD6, 0xDE, 0xE6, 0xEE, 0xF6, 0xFE: len = 2; c = 8   # ALU A,n
    of 0xF0: len = 2; c = 12; ra = 0xFF00 + rd(pc + 1)           # LDH A,(n)
    of 0xF2: c = 8; ra = 0xFF00 + int(cpu.c)                     # LD A,(C)
    of 0xFA: len = 3; c = 16; ra = rd(pc + 1) or (rd(pc + 2) shl 8)   # LD A,(nn)
    of 0xCB:
      let cb = rd(pc + 1)
      len = 2; c = 8
      if (cb and 7) == 6:
        if cb >= 0x40 and cb < 0x80: ra = int(cpu.hl); c = 12    # BIT b,(HL)
        else: return                                             # writes (HL)
    of 0x20, 0x28, 0x30, 0x38, 0x18:                             # JR
      len = 2
      if pc == last: c = 12
      elif op == 0x18: return                                    # always taken
      else: c = 8
    of 0xC2, 0xCA, 0xD2, 0xDA, 0xC3:                             # JP
      len = 3
      if pc == last: c = 16
      elif op == 0xC3: return
      else: c = 12
    else: return
    if ra >= 0 and not wl_read_ok(gb, ra, result): return
    cyc += c
    if pc == last:
      result.ok = true
      result.period = cyc
      return
    pc += len
  # Ran past `last` without landing on it: not the branch we came from.

proc wl_horizon(gb: GB; reads_ly, reads_stat: bool; period = 0): int =
  ## CPU cycles from now to the first point anything an idle loop reads can
  ## change: a scheduler event other than the APU's own, the PPU's next stop
  ## (the dot fifo_tick stops bumping the counter on), a timer overflow. 0 when
  ## something in flight rules a skip out altogether.
  let mem {.cursor.} = gb.memory
  if mem.requested_oam_dma or mem.dma_position <= 0xA0 or mem.dma_busy or
     mem.write_deferred: return 0
  when CGB_WRITE_LATENCY_ANY:
    if mem.pipe_reg != 0: return 0
  if gb.ppu.hdma_block_due or gb.serial.shifting: return 0
  # A requested transfer with a peer on the cable: an external-clock one ends
  # when the peer's coordinator catches this core up to the master's time
  # (link.nim complete_transfer), which a skip would have run past. With no
  # peer it never ends, and a game listening for one (SC = $80) skips.
  if (gb.serial.sc and 0x80'u8) != 0 and gb.serial.driver != nil and
     serial_peer_committed(gb.serial.driver): return 0
  let t {.cursor.} = gb.timer
  if t.countdown >= 0 or t.hold_t != 0: return 0
  var dots: int32
  let ppu {.cursor.} = gb.fifo_ppu
  if ppu == nil:
    # The scanline renderer: a halted CPU only (no loop marks a head on it,
    # wl_on), to its next mode boundary.
    if reads_ly or reads_stat: return 0
    dots = scanline_idle_dots(gb.ppu, gb)
  elif not ppu.lcd_enabled: return 0
  elif (ppu.lcd_status and 3'u8) == 3'u8:
    if ppu.lazy_end == 0: return 0
    dots = ppu.lazy_end - ppu.cycle_counter
  else:
    let m = ppu.lcd_status and 3'u8
    if m == 1 and ppu.cycle_counter <= LYC_RELATCH_DOT: return 0
    dots = fifo_skip_target(ppu, gb, m) - ppu.cycle_counter
  if reads_ly:
    # LY ripples on the line's last dot (ly_edge_rippling) and line 153 reads
    # 0 part way through (LY153_READ_SPLIT).
    if ppu.ly == 153'u8: return 0
    dots = min(dots, gb_line_end(ppu) - 2'i32 - ppu.cycle_counter)
  if reads_stat:
    # STAT reads the mode a few dots back from a change (stat_read_mode): the
    # iteration being copied, which began `period` cycles ago, must have
    # started clear of it too.
    if ppu.first_line or
       ppu.cycle_counter - ppu.stat_chg_dot -
         int32(period shr mem.current_speed) < 32'i32: return 0
  if dots <= 0: return 0
  result = int(dots) shl mem.current_speed
  let s {.cursor.} = gb.scheduler
  for ev in s.pending:
    if ev.kind notin GB_APU_EVENTS:
      result = min(result, int(ev.cycles - s.cycles))
      break
  if t.enabled:
    if t.previous_bit != ((t.tdiv and (1'u16 shl t.bit_for_tima)) != 0): return 0
    let sh = t.bit_for_tima + 1
    let to_ovf = (((int(t.tdiv) shr sh) + (256 - int(t.tima))) shl sh) - int(t.tdiv)
    result = min(result, to_ovf)

when defined(gb_idlecheck):
  var wl_chk_until: CycleCount
  var wl_chk_on: bool
  var wl_chk_halt: bool
  var wl_chk_pc: uint16
  var wl_chk_regs: array[5, uint16]
  var wl_chk_writes: int
  var wl_checked*, wl_bad*: int
  import std/exitprocs
  addExitProc(proc() =
    stderr.writeLine "idlecheck skips=", wl_checked, " bad=", wl_bad)
  var wl_chk_desc: string
  proc wl_chk_arm(cpu: GbCpu; gb: GB; adv: int; halt: bool) =
    wl_chk_desc = "arm ly=" & $gb.ppu.ly & " dot=" & $gb.ppu.cycle_counter &
      " mode=" & $(gb.ppu.lcd_status and 3'u8) & " adv=" & $adv &
      " spd=" & $gb.memory.current_speed & " next_ev=" &
      $(int(gb.scheduler.next_event) - int(gb.scheduler.cycles))
    wl_chk_on = true
    wl_chk_halt = halt
    wl_chk_until = gb.scheduler.cycles + CycleCount(adv)
    wl_chk_pc = cpu.pc
    wl_chk_regs = [cpu.af and 0xFFF0'u16, cpu.bc, cpu.de, cpu.hl, cpu.sp]
    wl_chk_writes = gb.memory.write_count
  proc wl_chk_tick(cpu: GbCpu; gb: GB) =
    ## At every instruction / halted M-cycle boundary while a check is armed:
    ## the run the skip replaced must stay put (halted, or looping without a
    ## write) and be back at the head, unchanged, on the cycle it would land.
    let now = gb.scheduler.cycles
    let regs = [cpu.af and 0xFFF0'u16, cpu.bc, cpu.de, cpu.hl, cpu.sp]
    var bad = ""
    if gb.memory.write_count != wl_chk_writes: bad = "write"
    elif wl_chk_halt and not cpu.halted: bad = "woke"
    elif now > wl_chk_until: bad = "overshot"
    elif now == wl_chk_until:
      if cpu.pc != wl_chk_pc: bad = "pc"
      elif regs != wl_chk_regs: bad = "regs"
      else:
        wl_chk_on = false
        inc wl_checked
    if bad.len > 0:
      wl_chk_on = false
      inc wl_bad
      if wl_bad <= 20:
        stderr.writeLine "IDLECHECK ", bad, " pc=", toHex(wl_chk_pc, 4),
          " halt=", wl_chk_halt, " ly=", gb.ppu.ly, " dot=", gb.ppu.cycle_counter,
          " | ", wl_chk_desc

proc wl_advance(gb: GB; adv: int) {.inline.} =
  mem_tick_components(gb.memory, gb, adv)
  mem_reset_cycle_count(gb.memory)

proc wl_head_check(cpu: GbCpu; gb: GB) {.noinline.} =
  ## The fetch after a taken backward branch: is this the head of an
  ## iteration that repeated the last one, and how far can it be skipped?
  cpu.wl_edge = false
  let now = gb.scheduler.cycles
  let regs = [cpu.af and 0xFFF0'u16, cpu.bc, cpu.de, cpu.hl, cpu.sp]
  # The iteration just finished read what the next ones will only if nothing
  # it reads changed since it started (gb.wl_mark).
  if int32(cpu.pc) == cpu.wl_head and cpu.wl_from == cpu.wl_head_from and
     gb.memory.write_count == cpu.wl_writes and regs == cpu.wl_snap and
     gb.wl_mark <= cpu.wl_stamp and
     not (cpu.ime and interrupt_ready(gb.interrupts)) and
     wl_horizon(gb, false, false) > 0:
    # The horizon before the decode: the reads it adds only shorten it, and a
    # repeating loop mostly meets 0 (mode 3 not deferred, the scanline
    # renderer), where decoding the body every iteration cost up to 20 %.
    let sc = wl_scan(cpu, gb, int(cpu.pc), int(cpu.wl_from))
    if sc.ok and now - cpu.wl_stamp == CycleCount(sc.period):
      let h = wl_horizon(gb, sc.reads_ly, sc.reads_stat, sc.period)
      let n = (h - 1) div sc.period
      if n >= 1:
        when defined(gb_idlecheck):
          if not wl_chk_on: wl_chk_arm(cpu, gb, n * sc.period, false)
        else:
          wl_advance(gb, n * sc.period)
          cpu.wl_stamp = gb.scheduler.cycles
          return
  cpu.wl_head = int32(cpu.pc)
  cpu.wl_head_from = cpu.wl_from
  cpu.wl_snap = regs
  cpu.wl_stamp = now
  cpu.wl_writes = gb.memory.write_count

proc wl_halt_skip(cpu: GbCpu; gb: GB): bool {.noinline.} =
  ## A halted CPU with nothing to wake it before the horizon spends those
  ## M-cycles as cpu_halt_tick would, in one step. true = advanced.
  if interrupt_ready(gb.interrupts): return false
  when CGB_HALT_PPU_LEAD_ANY:
    if halt_lead_live(gb): return false
  let h = wl_horizon(gb, false, false)
  let n = (h - 1) div 4
  if n < 2: return false
  when defined(gb_idlecheck):
    if not wl_chk_on: wl_chk_arm(cpu, gb, n * 4, true)
    false
  else:
    wl_advance(gb, n * 4)
    true

proc tick*(cpu: GbCpu; gb: GB) =
  # `locked` is only tested behind the `halted` branch, so the running CPU
  # pays nothing for it.
  if cpu.halted:
    cpu.cached_hl = -1
    # The two halts no interrupt ends: the opcode lockup (still ticking) and
    # STOP mode (not). Testing `locked` here rather than `stopped` alone is
    # the cheapest shape measured on a HALT-idling title.
    if cpu.locked:
      if cpu.stopped: cpu_stop_tick(cpu, gb)
      elif STOP_OPERAND_LATCH != 0 and gb.stop_op_latch > 0: cpu_run_latched(cpu, gb)
      else:           mem_tick_extra(gb.memory, gb, 4)
      return
    when defined(gb_idlecheck):
      if wl_chk_on: wl_chk_tick(cpu, gb)
    when GB_IDLE_SKIP != 0:
      if gb.wl_mark != cpu.wl_halt_fail:
        if wl_halt_skip(cpu, gb): return
        cpu.wl_halt_fail = gb.wl_mark
    # The halt ends on IF & IE whether or not IME lets the interrupt be taken;
    # where in the M-cycle that is asked is HALT_IF_SAMPLE_T.
    if cpu_halt_tick(gb): cpu_halt_wake(cpu, gb)
    return
  when defined(gbfuzz_trace):
    if gbfuzz_trace_hook != nil:
      gbfuzz_trace_hook(cpu.pc, read_byte(gb.memory, gb, int(cpu.pc)))
  when defined(gb_idlecheck):
    if wl_chk_on: wl_chk_tick(cpu, gb)
  when GB_IDLE_SKIP != 0:
    if unlikely(cpu.wl_edge): wl_head_check(cpu, gb)
  let opcode = mem_read(gb.memory, gb, int(cpu.pc))
  cpu_exec_fetched(cpu, gb, opcode)
