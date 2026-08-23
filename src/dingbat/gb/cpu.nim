# GB SM83 CPU (included by gb.nim)

proc new_gb_cpu*(): GbCpu =
  GbCpu(pc: 0, sp: 0, ime: false, halted: false, halt_bug: false,
        locked: false, stopped: false, cached_hl: -1)

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
    if ppu.hdma_active and (ppu.lcd_status and 3'u8) == 0'u8:
      # `high(int32)` = owed to a halted CPU, waiting for its wake. Reaching a
      # fetch or boundary means the CPU is running and that wake has passed
      # (armed by the dispatch's own dots), so the debt is owed now
      # (gambatte dma/hdma_ei_m3halt_m0unhalt_ly_2).
      if ppu.hdma_due_deadline == high(int32):
        ppu.hdma_due_deadline = ppu.cycle_counter
      if ppu.cycle_counter + slack >= ppu.hdma_due_deadline:
        ppu_step_hdma(ppu, gb, in_cpu_cycle = HDMA_GRANT_FETCH_HOLD)
    else:
      ppu.hdma_block_due = false

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
  else:
    cpu.halted = true
    when HDMA_GRANT_FETCH_DOTS >= 0:
      # The third hand-over point, the HALT: charged at the HALT's fetch rather
      # than per halted M-cycle (at most 4 dots apart, row-for-row identical,
      # and free for a HALT-idling title). A block owed to an already halted
      # CPU carries a high(int32) deadline and is paid at the wake instead
      # (gambatte dma/hdma_late_m3halt_m2unhalt_scx2_2).
      if unlikely(gb.ppu.hdma_block_due) and
         gb.ppu.hdma_due_deadline != high(int32):
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

const IRQ_PUSH_T* {.intdefine.} = 0
  ## T-cycles of internal wait charged before the dispatch's two push
  ## M-cycles: 0 = pushes first (ships), 8 = Pan Docs' wait-first order.
  ## The two are indistinguishable by score.

const IRQ_SAMPLE_T_DS* {.intdefine.} = 16
  ## IRQ_SAMPLE_T for a dispatch taken in double speed; equal to IRQ_SAMPLE_T
  ## compiles the split out (ships). 20/16 gains the `_2` arm of seven gambatte
  ## *_late_retrigger families on both devices but loses
  ## m2int_m2irq_late_retrigger_1, the direct read-out of the clear; when each
  ## source rises needs settling before this flips.
const IRQ_SAMPLE_T* {.intdefine.} = 16
  ## T-cycles into the 5 M-cycle interrupt dispatch at which the taken line's
  ## IF bit is cleared. gambatte *_late_retrigger (under five STAT sources and
  ## the timer) move a handler's IF re-request one M-cycle per member;
  ## m2int_m2irq_late_retrigger_{1,2} bracket the clear to later than 15 T and
  ## no later than 19 T: the start of the fifth M-cycle, after the two waits
  ## and two pushes (Pan Docs, "Interrupt Handling"). Only the clear is here;
  ## which line is taken is decided between the push bytes (dispatch_interrupt;
  ## mooneye acceptance/interrupts/ie_push).
proc dispatch_interrupt(cpu: GbCpu; gb: GB) {.noinline.} =
  ## The taken half of handle_interrupts: push PC, vector, charge 5 M-cycles.
  ## Out of line: two inlined mem_writes give handle_interrupts a prologue
  ## paid on every non-taken call (+0.8% retired instructions).
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
  let interrupt = highest_priority(gb.interrupts)
  cpu.sp = cpu.sp - 1
  oam_bug_if(gb, cpu.sp, obWrite)
  mem_write(gb.memory, gb, int(cpu.sp), uint8(cpu.pc and 0xFF))
  cpu.pc = interrupt
  # Run out to the sample point before clearing IF (IRQ_SAMPLE_T); the two
  # writes above have charged 8 of it. One call, not one per M-cycle.
  when IRQ_SAMPLE_T_DS == IRQ_SAMPLE_T:
    when IRQ_SAMPLE_T > 8 + IRQ_PUSH_T:
      mem_tick_components(gb.memory, gb, IRQ_SAMPLE_T - 8 - IRQ_PUSH_T)
  else:
    let sample_t =
      if gb.memory.current_speed == 1: IRQ_SAMPLE_T_DS else: IRQ_SAMPLE_T
    if sample_t > 8 + IRQ_PUSH_T:
      mem_tick_components(gb.memory, gb, sample_t - 8 - IRQ_PUSH_T)
  clear_interrupt(gb.interrupts, interrupt)
  mem_tick_extra(gb.memory, gb, 20)

proc handle_interrupts*(cpu: GbCpu; gb: GB) =
  # The running CPU's test: the timer's request reaches it one M-cycle ahead
  # of everyone else's view of IF (TIMER_IRQ_RUN_LEAD in gb.nim; inert at 0).
  if interrupt_ready_run(gb.interrupts):
    # STOP mode is entered with an interrupt pending on one of its leaves
    # (Pan Docs' STOP chart; daid stop_instr.gb) and only a joypad line ends
    # it, so this must not un-halt the CPU the M-cycle STOP retires.
    if cpu.stopped: return
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
# Open: gambatte halt/noime_m2irq_m0stat_1 [cgb] is the one row this costs;
# either the rule is DMG-only or CGB_HALT_PPU_LEAD already pays for it there.
const M2_LEAD_HALT_BLIND* {.booldefine.} = true
  ## Whether a HALTED CPU is blind to the mode 2 STAT source for the
  ## STAT_M2_LEAD M-cycles it leads the line boundary by. Ships on with
  ## STAT_M2_LEAD; false is the control build.

when STAT_M2_EARLY and M2_LEAD_HALT_BLIND:
  proc halt_m2_lead_blind(gb: GB): bool {.noinline.} =
    ## Is the interrupt line up only because the OAM source is inside its lead
    ## window? Approximate in one direction: a STAT bit raised earlier by
    ## another source and re-masked mid-halt by an IE write is deferred too.
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
    if gb.cgb_enabled and
       gb.cpu.halt_ppu_debt < int32(CGB_HALT_PPU_LEAD_DOTS shr gb.memory.current_speed) and
       (when CGB_HALT_LEAD_SKIP_LYC0 != 0:
          not (gb.ppu.lyc == 0'u8 and (gb.ppu.lcd_status and 0x40'u8) != 0'u8)
        else: true) and
       (when CGB_HALT_LEAD_LYC_ONLY != 0:
          # Experiment: is the lead the LYC comparator's alone, absent for a
          # mode-sourced STAT edge (gambatte halt/m0*_m0stat_scx*)?
          (gb.ppu.lcd_status and 0x38'u8) == 0'u8
        else: true):
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
      else:           mem_tick_extra(gb.memory, gb, 4)
      return
    # The halt ends on IF & IE whether or not IME lets the interrupt be taken;
    # where in the M-cycle that is asked is HALT_IF_SAMPLE_T.
    if cpu_halt_tick(gb):
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
      if gb.ppu.hdma_block_due:
        if gb.ppu.hdma_active and (gb.ppu.lcd_status and 3'u8) == 0'u8 and
           (HDMA_WAKE_M0_MARGIN == 0 or
            gb.ppu.cycle_counter +
              int32(HDMA_WAKE_M0_MARGIN shr int(gb.memory.current_speed)) <
              gb_line_end(gb.ppu)):
          ppu_step_hdma(gb.ppu, gb)
        else:
          gb.ppu.hdma_block_due = false
      when CGB_HALT_PPU_LEAD_ANY:
        # The dots the head of this halt held back, paid with no bus half: a
        # phase, not a charge.
        if gb.cpu.halt_ppu_debt != 0:
          mem_tick_ppu(gb.memory, gb, int(gb.cpu.halt_ppu_debt),
                       ignore_speed = true)
          gb.cpu.halt_ppu_debt = 0
      cpu.halted = false
      if cpu.ime: dispatch_interrupt(cpu, gb)
    return
  when defined(gbfuzz_trace):
    if gbfuzz_trace_hook != nil:
      gbfuzz_trace_hook(cpu.pc, read_byte(gb.memory, gb, int(cpu.pc)))
  let opcode = mem_read(gb.memory, gb, int(cpu.pc))
  when HDMA_GRANT_FETCH_DOTS >= 0:
    # Hand-over point 1: an owed block takes the bus at the end of the opcode
    # fetch, never on the operand or data M-cycles (the gambatte two-M-cycle
    # `LD A,[HL]` vs mealybug three-M-cycle `LDH A,[rHDMA5]` split;
    # HDMA_GRANT_FETCH_DOTS in gb.nim).
    if unlikely(gb.ppu.hdma_block_due): hdma_grant(gb, 0)
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
    if unlikely(gb.ppu.hdma_block_due):
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
