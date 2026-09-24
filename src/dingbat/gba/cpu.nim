# CPU implementation (included by gba.nim)

proc mode_bank*(m: CpuMode): int =
  # `m` is guest-controlled (SPSR mode field, MSR CPSR) and can hold any
  # 5-bit pattern (Prince of Tennis 2004 returns with SPSR mode 0x1E).
  # Dispatch on the raw ordinal: an exhaustive enum case would compile the
  # else into a trap.
  case uint32(m)
  of uint32(modeUSR), uint32(modeSYS): 0
  of uint32(modeFIQ):                  1
  of uint32(modeIRQ):                  2
  of uint32(modeSVC):                  3
  of uint32(modeABT):                  4
  of uint32(modeUND):                  5
  else:                                UNDEF_BANK

proc new_cpu*(gba: GBA): CPU =
  result = CPU(
    gba: gba,
    cpsr: cast[PSR](uint32(modeSYS)),
    spsr: cast[PSR](uint32(modeSYS)),
    pipeline: Pipeline(),
    halted: false,
    attempt_waitloop_detection: true,
    cache_waitloop_results: true,
    branch_dest: 0,
    entered_waitloop: false,
  )
  for i in 0..15: result.r[i] = 0
  for bank in 0..5:
    for reg in 0..6: result.reg_banks[bank][reg] = 0
    result.spsr_banks[bank] = uint32(modeSYS)
  result.waitloop_instr_lut = build_waitloop_lut()
  result.clear_pipeline()

proc skip_bios*(cpu: CPU) =
  cpu.reg_banks[mode_bank(modeUSR)][5] = 0x03007F00'u32
  cpu.r[13] = 0x03007F00'u32
  cpu.reg_banks[mode_bank(modeIRQ)][5] = 0x03007FA0'u32
  cpu.reg_banks[mode_bank(modeSVC)][5] = 0x03007FE0'u32
  cpu.r[15] = 0x08000000'u32
  # The BIOS branches to the entry point, leaving it in LR
  cpu.r[14] = 0x08000000'u32
  # At ROM entry the BIOS leaves DISPCNT force-blanked and POSTFLG set
  # (hardware: gbaedge IDENT on AGB SP, docs/hwprobe.md).
  cpu.gba.ppu.dispcnt = cast[DISPCNT](0x0080'u16)
  cpu.gba.mmio.postflg = 1
  # BIOS open-bus value after boot (GBATEK, "BIOS Memory": 0xE129F000).
  cpu.gba.bus.bios_latch = 0xE129F000'u32
  cpu.clear_pipeline()

proc switch_mode*(cpu: CPU; new_mode: CpuMode) =
  # The LDM^ glitch's OR'd values belong to the registers as the instruction
  # after the LDM^ reads them, never to a bank.
  if cpu.ldm_glitch != 0: cpu.ldm_glitch_restore()
  let old_mode  = cast[CpuMode](cpu.cpsr.mode)
  if new_mode == old_mode: return
  let new_bank  = mode_bank(new_mode)
  let old_bank  = mode_bank(old_mode)
  # r8-r12 and the SPSR of the empty bank are the user bank's (UNDEF_BANK)
  let new_high  = if new_bank == UNDEF_BANK: 0 else: new_bank
  let old_high  = if old_bank == UNDEF_BANK: 0 else: old_bank
  if new_mode == modeFIQ or old_mode == modeFIQ:
    for idx in 0..4:
      cpu.reg_banks[old_high][idx] = cpu.r[8 + idx]
      cpu.r[8 + idx] = cpu.reg_banks[new_high][idx]
  cpu.reg_banks[old_bank][5] = cpu.r[13]
  cpu.reg_banks[old_bank][6] = cpu.r[14]
  cpu.spsr_banks[old_high]   = uint32(cpu.spsr)
  if new_bank == UNDEF_BANK:
    cpu.reg_banks[UNDEF_BANK][5] = 0
    cpu.reg_banks[UNDEF_BANK][6] = 0
  cpu.r[13]         = cpu.reg_banks[new_bank][5]
  cpu.r[14]         = cpu.reg_banks[new_bank][6]
  # Load the destination mode's banked SPSR and nothing else: an msr mode
  # switch back into IRQ mode must leave SPSR_irq intact for the pending
  # exception return (exception entry overwrites it afterwards itself).
  cpu.spsr          = cast[PSR](cpu.spsr_banks[new_high])
  cpu.cpsr.mode     = uint32(new_mode)

proc irq*(cpu: CPU) =
  if not cpu.cpsr.irq_disable: cpu.irq_enter()

proc irq_enter*(cpu: CPU) =
  ## The IRQ exception, whatever CPSR.I holds (irq checks it; an S-bit
  ## CPSR restore that sets it does not, arm.exception_return_restore).
  block:
    when defined(irqlog):
      # -d:irqlog: the cycle every IRQ is taken at, to IRQLOG (a file: the
      # playtest driver's stdout is its protocol pipe).
      block:
        var f: File
        if f.open(getEnv("IRQLOG", "/tmp/irqlog.txt"), fmAppend):
          f.writeLine("irq now=" & $(cpu.gba.bus.sched.cycles + CycleCount(cpu.gba.bus.cycles)) &
            " pc=" & toHex(cpu.r[15], 8) & " wake=" & $cpu.halt_wake &
            " vcount=" & $cpu.gba.ppu.vcount & " if=" & toHex(uint16(cpu.gba.interrupts.reg_if), 4))
          f.close()
    # Taken between an LDM^ and its next instruction: the entry is that
    # instruction, and it reads none of the glitched registers.
    if cpu.ldm_glitch != 0: cpu.ldm_glitch_restore(ran = false)
    let lr = cpu.r[15] - (if cpu.cpsr.thumb: 0'u32 else: 4'u32)
    # Interrupting code that executes from the gamepak also pays for the
    # in-flight opcode fetch: +2*S16 (hardware: gbaedge IRQLAT2 and IRQWIN2
    # on AGB SP, docs/hwprobe.md; the mGBA suite Timer IRQ rows run from
    # IWRAM and pin the no-stall case). A halt-wake entry fetches nothing, so
    # it is exempt. With the prefetcher on and the interrupted stream going
    # on at the next instruction (lr - 4), that fetch is the prefetcher's
    # (IRQ_FETCH_VIA_PREFETCH): a halfword (Thumb) or word (ARM) it already
    # holds costs the entry nothing, one still in flight its wait less the
    # cycle the entry overlaps. alyosha irq/BL_IRQ, _3 (a timer interrupting
    # Thumb code around a `bl`, the buffer full or just flushed by the
    # branch) and IRQ_sub, _slow (both waitstates); each alternative in the
    # commit that added this fails some of them.
    var inflight = 0
    if not cpu.halt_wake:
      let page = int(bits_range(lr, 24, 27))
      if page in 8..13:
        let bus = cpu.gba.bus
        if IRQ_FETCH_VIA_PREFETCH and bus.prefetch_on and not bus.pf_paused and
           bus.rom_next_addr == lr - 4:
          let now = bus.sched.cycles + CycleCount(bus.cycles)
          inflight = max(0, bus.pf_serve(now, page, if cpu.cpsr.thumb: 1 else: 2) - 1)
        else:
          inflight = 2 * int(bus.wait16_s[page])
    let old_cpsr = cpu.cpsr
    cpu.switch_mode(modeIRQ)
    cpu.spsr = old_cpsr
    cpu.cpsr.thumb = false
    cpu.cpsr.irq_disable = true
    discard cpu.set_reg(14, lr)
    discard cpu.set_reg(15, 0x18'u32)
    # Entry/return overhead: the ARM7TDMI data sheet costs exception entry
    # and the S-bit return at 2S+1N each. Entry is the refill set_reg(15)
    # charges plus IRQ_ENTRY_EXTRA = 1. It was 2, with the return a cycle
    # short to match: tests/roms/payloads/wakeirq.s on an AGB SP interrupts a
    # sled of one-cycle NOPs (V-count and timer sources alike) and the
    # console interrupts the same NOP, returns on the same cycle, and reads a
    # clock in the handler one cycle sooner. The mGBA suite's timer rows had
    # pinned the old split only because they stop a timer inside the handler,
    # and a stop lands a cycle later than we had it (TIMER_STOP_DELAY): two
    # errors that cancelled everywhere except in a handler that reads.
    cpu.gba.bus.add_cycles(IRQ_ENTRY_EXTRA)
    if inflight != 0: cpu.gba.bus.add_cycles(inflight)

proc und*(cpu: CPU) =
  # Undefined Instruction trap; LR_und = the instruction after the faulting one.
  let lr = cpu.r[15] - (if cpu.cpsr.thumb: 2'u32 else: 4'u32)
  let old_cpsr = cpu.cpsr
  cpu.switch_mode(modeUND)
  cpu.spsr = old_cpsr
  cpu.cpsr.thumb = false
  cpu.cpsr.irq_disable = true
  discard cpu.set_reg(14, lr)
  discard cpu.set_reg(15, 0x04'u32)

proc fill_pipeline*(cpu: CPU) {.inline.} =
  if cpu.cpsr.thumb:
    let pc = cpu.r[15] and not 1'u32
    if cpu.pipeline.size == 0:
      let v = uint32(cpu.gba.bus.fetch_half(pc - 2))
      if bits_range(pc - 2, 24, 27) == 0:
        cpu.gba.bus.bios_latch = v or (v shl 16)
      cpu.pipeline.push(v)
    if cpu.pipeline.size == 1:
      let v = uint32(cpu.gba.bus.fetch_half(pc))
      if bits_range(pc, 24, 27) == 0:
        cpu.gba.bus.bios_latch = v or (v shl 16)
      cpu.pipeline.push(v)
  else:
    let pc = cpu.r[15] and not 3'u32
    if cpu.pipeline.size == 0:
      let v = cpu.gba.bus.fetch_word(pc - 4)
      if bits_range(pc - 4, 24, 27) == 0:
        cpu.gba.bus.bios_latch = v
      cpu.pipeline.push(v)
    if cpu.pipeline.size == 1:
      let v = cpu.gba.bus.fetch_word(pc)
      if bits_range(pc, 24, 27) == 0:
        cpu.gba.bus.bios_latch = v
      cpu.pipeline.push(v)

proc clear_pipeline*(cpu: CPU) =
  cpu.pipeline.clear()
  cpu.refill_pending = true
  # Refill = two sequential fetches at the destination.
  let page = int(bits_range(cpu.r[15], 24, 27))
  # The console's fetch address runs two instructions ahead of the executing
  # one, where dingbat fetches; the refill's prefetch check needs the lead
  # the branch itself ran at.
  let old_ahead = cpu.gba.bus.rom_ahead
  cpu.gba.bus.rom_ahead = (if cpu.cpsr.thumb: 4'i8 else: 8'i8)
  if page < 0x8 or page > 0xD:
    # The prefetcher only runs while executing from ROM; leaving the gamepak
    # abandons the buffered stream (mGBA suite BIOS timing, prefetch columns).
    cpu.gba.bus.rom_next_addr = 1
    cpu.gba.bus.rom_hot = false
  when ROM_REFILL_ORDERED:
    if page >= 0x8 and page <= 0xD and (ROM_REFILL_ORDERED_PF or not cpu.gba.bus.prefetch_on):
      # The refill in the order the console makes it: a nonsequential fetch
      # at the target, a sequential one after it, and then each instruction's
      # own fetch continues the burst. The sum is what it always was (2S here
      # and N on the target's own fetch), but the ORDER is observable: a DMA
      # breaks the burst, and the first gamepak access after it is
      # nonsequential (tests/roms/payloads/slotdma.s on an AGB SP reads that
      # straight off an empty slot). With the N charged last, a DMA landing in
      # the refill cost nothing where the console pays two cycles, and one
      # landing in the branch's own fetch cost two where the console pays
      # nothing, because the N that follows absorbs it. Events due by now run
      # first for the same reason: a DMA requested before the refill starts
      # has to cool the burst before the N is charged, not after.
      let bus = cpu.gba.bus
      bus.catch_up()
      bus.rom_cool()
      let (n, s) = if cpu.cpsr.thumb: (int(bus.wait16_n[page]), int(bus.wait16_s[page]))
                   else: (int(bus.wait32_n[page]), int(bus.wait32_s[page]))
      var both = n + s
      var broken = false
      var credit = 0
      var streamed = false  # the refill came through the prefetcher
      var windowed = false
      when DMA_ACCESS_WINDOW:
        windowed = (bus.sync_bits and 2) != 0
      if not windowed and bus.prefetch_on:
        let now = bus.sched.cycles + CycleCount(bus.cycles)
        let target = cpu.r[15] and (if cpu.cpsr.thumb: not 1'u32 else: not 3'u32)
        let from_rom = bus.fetch_page - 0x8 <= 5
        if from_rom and bus.rom_next_addr + uint32(old_ahead) == target and
           (bus.pf_paused or now > bus.rom_free_since or
            (bus.pf_running and old_ahead == 4)):
          # A branch to the halfword the prefetcher reads next keeps the
          # buffer: the target comes out of it, or out of the halfword in
          # flight, like any sequential fetch (alyosha prefetcher_full_arm
          # t001c, prefetcher_branch_thumb). With nothing buffered or in
          # flight, a Thumb branch still meets the prefetcher starting on the
          # target at S if it has been running since the CPU's own last
          # access (prefetcher_branch_thumb_4), and fetches nonsequentially
          # if it has not (prefetcher_branch_thumb_2). An ARM branch there
          # fetches nonsequentially either way (ppu/start_up_vbl's startup
          # `bx` after eight back-to-back ARM fetches). Bracketed: counting
          # the running prefetcher for ARM too fails ppu/start_up_vbl and
          # prefetcher_branch_thumb_arm_3's first check; for neither mode,
          # prefetcher_branch_thumb_3 and _4.
          let halves = if cpu.cpsr.thumb: 1 else: 2
          let first = bus.pf_serve(now, page, halves)
          both = first + bus.pf_serve(now + CycleCount(first), page, halves)
          streamed = true
        elif from_rom and not bus.pf_paused and now > bus.rom_free_since:
          # Any other target flushes the buffer. A halfword in its final
          # cycle has committed and the fetch waits it out, as a data access
          # does (rom_access_cycles' prefetch hand-off). Without the cycle
          # alyosha prefetcher_full_arm, prefetcher_branch_thumb, _thumb_3,
          # prefetcher_boundary_1 and _3 fail.
          let elapsed = int(now - bus.rom_free_since)
          let commit =
            if elapsed < 64: ((bus.pf_commit[page] shr elapsed) and 1'u64) != 0
            else:
              let sp = int(bus.wait16_s[page])
              elapsed < 8 * sp and elapsed mod sp == sp - 1
          if commit: both += 1
      if not streamed:
        # The CPU's own fetches: the prefetcher starts behind them
        bus.pf_paused = false
        bus.pf_running = false
      when DMA_ACCESS_WINDOW:
        if windowed:
          # Two accesses, each with an end a DMA grant can wait for; and a
          # burst between them breaks the second, which is then nonsequential
          # (tests/roms/payloads/slotdma.s).
          # With the prefetcher on, a burst that never touches the gamepak
          # breaks nothing: the prefetcher works through it, and the cycles
          # it held the bus are fetch time the CPU does not pay again.
          bus.cycles += n
          bus.catch_up_access(n)
          both = s
          let after_first = bus.dma_end_at == bus.sched.cycles + CycleCount(bus.cycles)
          if after_first:
            if DMA_KEEPS_PREFETCH and bus.prefetch_on and bus.dma_first_rom:
              # Taking a halfword the prefetcher fetched during the burst is
              # a buffer read, one cycle (bus.pf_serve). alyosha Interactions/
              # Internal_Cycle_DMA_IRQ_Br_pre_tim, whose H-blank DMA lands
              # here: 0 cycles reads a cycle short, 2 a cycle long.
              both = max(1, s - bus.dma_held)
              credit = bus.dma_held - (s - both)
            else:
              both = n
          bus.cycles += both
          bus.catch_up_access(both)
          both = 0
          # One granted at the end of the second leaves the burst broken for
          # the target's own fetch, as the burst itself left it.
          if not after_first and bus.dma_end_at == bus.sched.cycles + CycleCount(bus.cycles):
            if DMA_KEEPS_PREFETCH and bus.prefetch_on and bus.dma_first_rom:
              credit = bus.dma_held
            else:
              broken = true
      bus.cycles += both
      if cpu.cpsr.thumb:
        bus.rom_next_addr = cpu.r[15] and not 1'u32
        cpu.r[15] += 4
      else:
        bus.rom_next_addr = cpu.r[15] and not 3'u32
        cpu.r[15] += 8
      if broken:
        bus.rom_next_addr = 1
        return
      if streamed:
        bus.rom_hot = bus.rom_free_since == bus.sched.cycles + CycleCount(bus.cycles)
        return
      bus.rom_free_since = bus.sched.cycles + CycleCount(bus.cycles) - CycleCount(credit)
      bus.rom_hot = credit == 0
      return
  if cpu.cpsr.thumb:
    cpu.r[15] += 4
    cpu.gba.bus.add_cycles(2 * int(cpu.gba.bus.wait16_s[page]))
  else:
    cpu.r[15] += 8
    cpu.gba.bus.add_cycles(2 * int(cpu.gba.bus.wait32_s[page]))

when defined(obuslatch):
  proc obus_drive_pipeline*(cpu: CPU) {.inline.} =
    ## What drives the bus is the newest PIPELINE fetch, two instructions
    ## ahead of the one executing -- r15, exactly. dingbat fetches lazily,
    ## one per instruction at the executing address, so the fetch itself is
    ## the wrong place to drive the latch from; the BIOS latch in read_instr
    ## below already compensates the same way for the same reason (gbaedge
    ## IDENT on an AGB SP). Without this every out-of-bounds row reads one
    ## instruction short.
    let pc = cpu.r[15]
    let region = bits_range(pc, 24, 27)
    if region == 0x1 or region == 0x4 or region > 0xD or
       bits_range(pc, 28, 31) > 0:
      return                       # unmapped pc would recurse into open bus
    when defined(obusahead):
      let now = cpu.gba.bus.sched.cycles + CycleCount(cpu.gba.bus.cycles)
    if cpu.cpsr.thumb:
      let a = pc and not 1'u32
      cpu.gba.bus.obus_drive_half(a, cpu.gba.bus.read_half_internal(a))
    else:
      let a = pc and not 3'u32
      cpu.gba.bus.obus_drive_word(cpu.gba.bus.read_word_internal(a))
    when defined(obusahead):
      cpu.gba.bus.obus_prev_at = now

proc read_instr*(cpu: CPU): uint32 {.inline.} =
  cpu.refill_pending = false
  when defined(obuslatch): cpu.obus_drive_pipeline()
  if cpu.pipeline.size == 0:
    if cpu.cpsr.thumb:
      cpu.r[15] = cpu.r[15] and not 1'u32
      let fetch_addr = cpu.r[15] - 4
      let v = uint32(cpu.gba.bus.fetch_half(fetch_addr))
      if bits_range(fetch_addr, 24, 27) == 0:
        # The BIOS latch is the newest pipeline fetch, two instructions ahead
        # of execution (hardware: gbaedge IDENT on AGB SP, docs/hwprobe.md).
        let ahead = uint32(cpu.gba.bus.read_half_internal((fetch_addr + 4) and 0x3FFF'u32))
        cpu.gba.bus.bios_latch = ahead or (ahead shl 16)
      v
    else:
      cpu.r[15] = cpu.r[15] and not 3'u32
      let fetch_addr = cpu.r[15] - 8
      let v = cpu.gba.bus.fetch_word(fetch_addr)
      if bits_range(fetch_addr, 24, 27) == 0:
        cpu.gba.bus.bios_latch = cpu.gba.bus.read_word_internal((fetch_addr + 8) and 0x3FFF'u32)
      v
  else:
    cpu.pipeline.shift()

proc idle_synced(cpu: CPU; n: int) {.noinline.} =
  ## idle's out-of-line half: a DMA is armed or close (sync_bits != 0).
  let bus = cpu.gba.bus
  when DMA_ACCESS_WINDOW:
    if (bus.sync_bits and 2) != 0:
      bus.idle_window(n)
      return
  when IMM_IDLE_GRANT:
    let now = bus.sched.cycles + CycleCount(bus.cycles)
    bus.imm_idle_from = now
    bus.imm_idle_until = now + CycleCount(n)
    if (bus.sync_bits and 4) != 0 and now == bus.imm_at and not bus.dma_active:
      # The request found the CPU going idle: granted now, and these
      # internal cycles run under the burst.
      bus.catch_up()
      bus.sched.clear(etDMA)
      bus.sync_bits = bus.sync_bits and not 4'u8
      cpu.gba.dma.request_immediate()
      cpu.gba.dma.run_pending()
  bus.add_cycles(n)

proc idle*(cpu: CPU; n: int) {.inline.} =
  ## Internal (I) cycles: no bus access.
  if cpu.gba.bus.sync_bits != 0:
    cpu.idle_synced(n)
    return
  cpu.gba.bus.add_cycles(n)

proc mul_i_cycles*(rs: uint32; signed_early_term: bool): int {.inline.} =
  ## 1-4 I cycles by multiplier magnitude (ARM7TDMI data sheet); signed
  ## multiplies also terminate early on all-ones prefixes.
  if rs < 0x100'u32 or (signed_early_term and rs >= 0xFFFFFF00'u32): 1
  elif rs < 0x10000'u32 or (signed_early_term and rs >= 0xFFFF0000'u32): 2
  elif rs < 0x1000000'u32 or (signed_early_term and rs >= 0xFF000000'u32): 3
  else: 4

proc set_reg*(cpu: CPU; reg: int; value: uint32): uint32 {.discardable, inline.} =
  cpu.r[reg] = value
  if reg == 15: cpu.clear_pipeline()
  value

proc set_neg_and_zero_flags*(cpu: CPU; value: uint32) {.inline.} =
  cpu.cpsr.negative = bit(value, 31)
  cpu.cpsr.zero     = (value == 0)

proc step_arm*(cpu: CPU) {.inline.} =
  cpu.r[15] += 4

proc step_thumb*(cpu: CPU) {.inline.} =
  cpu.r[15] += 2

proc check_cond*(cpu: CPU; cond: uint32): bool {.inline.} =
  case cond
  of 0x0: cpu.cpsr.zero
  of 0x1: not cpu.cpsr.zero
  of 0x2: cpu.cpsr.carry
  of 0x3: not cpu.cpsr.carry
  of 0x4: cpu.cpsr.negative
  of 0x5: not cpu.cpsr.negative
  of 0x6: cpu.cpsr.overflow
  of 0x7: not cpu.cpsr.overflow
  of 0x8: cpu.cpsr.carry and not cpu.cpsr.zero
  of 0x9: not cpu.cpsr.carry or cpu.cpsr.zero
  of 0xA: cpu.cpsr.negative == cpu.cpsr.overflow
  of 0xB: cpu.cpsr.negative != cpu.cpsr.overflow
  of 0xC: not cpu.cpsr.zero and cpu.cpsr.negative == cpu.cpsr.overflow
  of 0xD: cpu.cpsr.zero or cpu.cpsr.negative != cpu.cpsr.overflow
  of 0xE: true
  else: false  # NV: reserved on ARMv4T, executes as no-op

proc lsl*(cpu: CPU; word: uint32; bits: uint32; carry_out: ptr bool): uint32 {.inline.} =
  log("lsl - word:" & hex_str(word) & ", bits:" & $bits)
  if bits == 0: return word
  if bits < 32:
    carry_out[] = bit(word, int(32 - bits))
    word shl bits
  elif bits == 32:
    carry_out[] = bit(word, 0)
    0'u32
  else:
    carry_out[] = false
    0'u32

proc lsr*(cpu: CPU; word: uint32; bits: uint32; immediate: bool; carry_out: ptr bool): uint32 {.inline.} =
  log("lsr - word:" & hex_str(word) & ", bits:" & $bits)
  var b = bits
  if b == 0:
    if not immediate: return word
    b = 32
  if b < 32:
    carry_out[] = bit(word, int(b - 1))
    word shr b
  elif b == 32:
    carry_out[] = bit(word, 31)
    0'u32
  else:
    carry_out[] = false
    0'u32

proc asr*(cpu: CPU; word: uint32; bits: uint32; immediate: bool; carry_out: ptr bool): uint32 {.inline.} =
  log("asr - word:" & hex_str(word) & ", bits:" & $bits)
  var b = bits
  if b == 0:
    if not immediate: return word
    b = 32
  if b <= 31:
    carry_out[] = bit(word, int(b - 1))
    (word shr b) or (0xFFFFFFFF'u32 * (word shr 31)) shl (32 - b)
  else:
    carry_out[] = bit(word, 31)
    0xFFFFFFFF'u32 * (word shr 31)

proc ror*(cpu: CPU; word: uint32; bits: uint32; immediate: bool; carry_out: ptr bool): uint32 {.inline.} =
  log("ror - word:" & hex_str(word) & ", bits:" & $bits)
  if bits == 0:
    if not immediate: return word
    # RRX
    let res = (word shr 1) or (uint32(cpu.cpsr.carry) shl 31)
    carry_out[] = bit(word, 0)
    return res
  var b = bits and 31
  if b == 0: b = 32  # ROR by 32
  carry_out[] = bit(word, int(b - 1))
  (word shr b) or (word shl (32 - b))

proc sub*(cpu: CPU; operand_1, operand_2: uint32; set_conditions: bool): uint32 {.inline.} =
  log("sub - operand_1:" & hex_str(operand_1) & ", operand_2:" & hex_str(operand_2))
  let res = operand_1 - operand_2
  if set_conditions:
    cpu.set_neg_and_zero_flags(res)
    cpu.cpsr.carry    = operand_1 >= operand_2
    cpu.cpsr.overflow = bit((operand_1 xor operand_2) and (operand_1 xor res), 31)
  res

proc sbc*(cpu: CPU; operand_1, operand_2: uint32; set_conditions: bool): uint32 {.inline.} =
  log("sbc - operand_1:" & hex_str(operand_1) & ", operand_2:" & hex_str(operand_2))
  let c   = uint32(cpu.cpsr.carry)
  let res = operand_1 - operand_2 - 1 + c
  if set_conditions:
    cpu.set_neg_and_zero_flags(res)
    cpu.cpsr.carry    = uint64(operand_1) >= uint64(operand_2) + 1 - uint64(c)
    cpu.cpsr.overflow = bit((operand_1 xor operand_2) and (operand_1 xor res), 31)
  res

proc add*(cpu: CPU; operand_1, operand_2: uint32; set_conditions: bool): uint32 {.inline.} =
  log("add - operand_1:" & hex_str(operand_1) & ", operand_2:" & hex_str(operand_2))
  let res = operand_1 + operand_2
  if set_conditions:
    cpu.set_neg_and_zero_flags(res)
    cpu.cpsr.carry    = res < operand_1
    cpu.cpsr.overflow = bit(not (operand_1 xor operand_2) and (operand_2 xor res), 31)
  res

proc adc*(cpu: CPU; operand_1, operand_2: uint32; set_conditions: bool): uint32 {.inline.} =
  log("adc - operand_1:" & hex_str(operand_1) & ", operand_2:" & hex_str(operand_2))
  let c   = uint32(cpu.cpsr.carry)
  let res = operand_1 + operand_2 + c
  if set_conditions:
    cpu.set_neg_and_zero_flags(res)
    cpu.cpsr.carry    = uint64(res) < uint64(operand_1) + uint64(c)
    cpu.cpsr.overflow = bit(not (operand_1 xor operand_2) and (operand_2 xor res), 31)
  res

when defined(pcprofile):
  var prof_cycles*: array[16, uint64]
  var prof_iwram*: array[32, uint64]   # per-1KB bucket of IWRAM 0x03000000..0x03007FFF

when defined(gsprobe):
  var gsProbePc*: array[0x800, uint32]   # halfword-granular PC hit counts, 0x03000000..0xFFF
  var gsProbeLog*: seq[(uint32, uint32, uint32, uint32, uint32, uint32)] = @[]
  var gsProbeIn*: bool

proc waitloop_skip(cpu: CPU; remaining: int) {.noinline.} =
  ## Skip whole iterations of the loop's period, stopping at or before the
  ## next event (waitloop.nim "Transparency"). The loop is back at its first
  ## instruction at `boundary`; after k more iterations it is there again at
  ## boundary + k*period with nothing else changed, so time and the
  ## time-anchored bus state move by that much. An event exactly on the
  ## landing cycle dispatches there, as a real tick would. Out of line: the
  ## per-instruction path in tick sits on the inlining threshold.
  cpu.entered_waitloop = false
  let s = cpu.gba.scheduler
  let boundary = s.cycles + CycleCount(remaining)
  if boundary >= s.next_event:
    s.tick(remaining)
    return
  s.cycles = boundary
  let period = CycleCount(cpu.wl_period)
  let k = (s.next_event - boundary) div period
  if k > 0:
    let adv = k * period
    s.cycles = boundary + adv
    cpu.gba.bus.rom_free_since += adv
    cpu.wl_time += int64(adv)
    if s.cycles == s.next_event: s.call_current()

proc hle_halt_return*(cpu: CPU) =
  ## The stub BIOS's trap at 0x170 (an ARM `swi 0`), where a Halt parked by
  ## hle_halt goes on after its `bx lr`, woken directly or back from the
  ## interrupt it woke for: the dispatcher's return, from the frames hle_halt
  ## pushed (so nested halts and anything parked meanwhile keep their own).
  ## Cycles: HALT_BIOS_RETURN from reaching 0x170 to the return's refill, of
  ## which the trap's own fetch is one.
  let bus = cpu.gba.bus
  cpu.idle(HALT_BIOS_RETURN - 1)
  # System stack: the dispatcher's {r2, lr}
  cpu.r[2] = bus.read_word_internal(cpu.r[13])
  cpu.r[14] = bus.read_word_internal(cpu.r[13] + 4)
  cpu.r[13] += 8
  # SVC stack: {caller CPSR, r12, return address}, then `movs pc, lr`
  cpu.switch_mode(modeSVC)
  cpu.cpsr = cast[PSR](uint32(modeSVC) or 0xC0'u32)
  let sp = cpu.r[13]
  cpu.spsr = cast[PSR](bus.read_word_internal(sp))
  cpu.r[12] = bus.read_word_internal(sp + 4)
  cpu.r[14] = bus.read_word_internal(sp + 8)
  cpu.r[13] = sp + 12
  discard cpu.set_reg(15, cpu.r[14])     # refills in the caller's region
  cpu.exception_return_restore()
  cpu.r[15] -= 4                         # arm_software_interrupt steps past the swi
  bus.bios_latch = 0xE3A02004'u32        # as every HLE return leaves it

proc tick*(cpu: CPU) =
  # IRQ before the IntrWait re-halt check: the handler must run (and set the
  # BIOS mirror flags) or IntrWait re-halts forever.
  if not cpu.halted and cpu.irq_line and not cpu.cpsr.irq_disable:
    # A halted CPU's interrupt input is synchronised on a clock that was
    # stopped: the wake comes first and the exception an instruction later.
    # tests/roms/payloads/wakeirq.s on an AGB SP: the handler finds the
    # BIOS's `bx lr` after its HALTCNT write already executed, where a plain
    # wake (IME clear) resumes on the same cycle as here.
    # The HLE's Halt is parked in the stub BIOS and runs its `bx lr` too.
    if HALT_WAKE_RUNS_ONE and cpu.halt_wake and
       (not cpu.gba.bus.stub_bios or cpu.r[15] < 0x4000'u32):
      discard
    else:
      if HALT_WAKE_RUNS_ONE and cpu.halt_wake:
        # The HLE's stand-in for that instruction (a `bx lr` after Halt's
        # HALTCNT write, a `bl` after IntrWait's: three cycles either way),
        # taken out of what the return path charges later.
        if cpu.intr_wait_active:
          cpu.gba.bus.add_cycles(HALT_WAKE_INSTR_COST)
        elif cpu.halt_resume_charge >= HALT_WAKE_INSTR_COST:
          cpu.gba.bus.add_cycles(HALT_WAKE_INSTR_COST)
          cpu.halt_resume_charge -= HALT_WAKE_INSTR_COST
      cpu.irq()
  # The halt-wake entry exemption covers only the first boundary after the wake.
  cpu.halt_wake = false
  if cpu.intr_wait_active and not cpu.halted:
    # Back at the instruction after an IntrWait SWI: re-halt unless satisfied.
    let cur = cpu.r[15] - (if cpu.cpsr.thumb: 4'u32 else: 8'u32)
    if cur == cpu.intr_wait_resume_addr:
      # The cycles charged here stand in for BIOS code that ran BEFORE the
      # return's refill, which the handler's exception return has already
      # paid for in the console's order (clear_pipeline). Charging them must
      # not cool the burst, or the caller's first fetch pays for a second
      # nonsequential access the real BIOS never makes.
      let hot = cpu.gba.bus.rom_hot
      cpu.check_intr_wait()
      when ROM_REFILL_ORDERED:
        if hot and not cpu.halted: cpu.gba.bus.rom_hot = true
  if cpu.halt_resume_charge != 0 and not cpu.halted:
    # Back at the instruction after an HLE Halt/Stop SWI: charge the BIOS
    # return path the real BIOS runs after the wake.
    let cur = cpu.r[15] - (if cpu.cpsr.thumb: 4'u32 else: 8'u32)
    if cur == cpu.halt_resume_addr:
      # Paid in interruptible chunks: the real BIOS body runs under the
      # caller's IRQ mask, so further IRQs must preempt the residue. One
      # atomic lump (~240k cycles for a large LZ77UnComp) starves the Gen-3
      # link master's per-frame transfer cadence and FireRed/LeafGreen abort
      # the trade with LAG_MASTER. A remainder stays parked for the next return.
      let hot = cpu.gba.bus.rom_hot   # as for IntrWait above
      var owed = int(cpu.halt_resume_charge)
      if not cpu.halt_resume_pop:
        # A decompression/copy park: the IRQ that preempted the routine
        # returned here, refilling the pipeline in the caller's region, where
        # the real routine's handler returns into BIOS code (two 1-cycle
        # fetches). Take the difference back out of the remainder
        # (tools/biosdrv/lz77i.c: LZ77UnCompWram under a Timer 1 IRQ every
        # 1000/3000/12000 cycles, Thumb caller in the cartridge at WAITCNT
        # 0x4317: 4.3, 4.0 and 4.1 cycles long per IRQ without this, exact
        # with it; an ARM caller in IWRAM was exact either way).
        let bus = cpu.gba.bus
        let page = int(bits_range(cur, 24, 27))
        let refill = if cpu.cpsr.thumb: int(bus.wait16_n[page]) + int(bus.wait16_s[page])
                     else: int(bus.wait32_n[page]) + int(bus.wait32_s[page])
        let extra = refill - (int(bus.wait32_n[0]) + int(bus.wait32_s[0]))
        if extra > 0: owed -= min(extra, owed)
      let remain = cpu.hle_charge_units_interruptible(owed)
      when ROM_REFILL_ORDERED:
        if hot: cpu.gba.bus.rom_hot = true
      cpu.halt_resume_charge = int32(remain)
      if remain != 0: return
      # Dispatcher exit path: pop the caller's r12 from its SVC-stack slot.
      cpu.r[12] = cpu.gba.bus.read_word_internal(cpu.svc_sp() - 8)
      if cpu.halt_resume_pop:
        # Halt/Stop kept the dispatcher's {r2, lr} frame live on the System
        # stack; decompression parks never shifted sp and skip this.
        cpu.halt_resume_pop = false
        let usp = cpu.sys_sp() + 8
        cpu.r[2] = cpu.gba.bus.read_word_internal(usp - 8)
        cpu.set_sys_lr(cpu.gba.bus.read_word_internal(usp - 4))
        cpu.set_sys_sp(usp)
  if not cpu.halted:
    when defined(gsbon):
      # Camelot "Bon" (Golden Sun) hook, parked behind -d:gsbon: a PC compare
      # per instruction, shadow-only, never alters control flow. (The MP2K
      # HLE needs no PC hook: the driver's own writes mark its passes, see
      # mp2k.nim "Runtime detection".)
      let g = cpu.gba.gs_bon
      if g != nil and g.engaged and cpu.gba.mp2k_hle:
        let cur = cpu.r[15] - (if cpu.cpsr.thumb: 4'u32 else: 8'u32)
        if cur == g.hook_addr: g.gs_mixer_hook()
    when defined(gsprobe):
      # Golden Sun "Bon" mixer probe: IWRAM PC histogram + entry events.
      block:
        let cur = cpu.r[15] - (if cpu.cpsr.thumb: 4'u32 else: 8'u32)
        let inIw = (cur shr 24) == 0x03'u32 and (cur and 0x7FFF'u32) < 0x1000'u32
        if inIw:
          gsProbePc[int((cur and 0xFFF'u32) shr 1)].inc
          if not gsProbeIn and gsProbeLog.len < 4000:
            gsProbeLog.add (cur, cpu.r[14], cpu.r[0], cpu.r[1], cpu.r[2],
                            uint32(cpu.gba.ppu.vcount))
            if cur == 0x3000380'u32 or cur == 0x3000659'u32:
              let sip = cpu.gba.bus.read_word_internal(0x03007FF0'u32)
              var packed = 0'u32
              for c in 0 ..< 4:
                let st = cpu.gba.bus.read_byte_internal(sip + 0x50 + uint32(c)*64)
                packed = packed or (uint32(st) shl (c*8))
              var envs = 0'u32
              for c in 0 ..< 4:
                let ev = cpu.gba.bus.read_byte_internal(sip + 0x50 + uint32(c)*64 + 9)
                envs = envs or (uint32(ev) shl (c*8))
              gsProbeLog.add (0xFFFF'u32, packed, envs, 0'u32, 0'u32,
                              uint32(cpu.gba.ppu.vcount))
        gsProbeIn = inIw
    when defined(pcprofile):
      let prof_region = bits_range(cpu.r[15], 24, 27)
    when defined(biosdrvtrace):
      if bdPcHook != nil:
        bdPcHook(cpu.r[15] - (if cpu.cpsr.thumb: 4'u32 else: 8'u32))
    when defined(pftrace):
      pft("INSTR pc=" & toHex(cpu.r[15], 8) & " t=" & $cpu.cpsr.thumb &
          " sched=" & $cpu.gba.scheduler.cycles & " busc=" & $cpu.gba.bus.cycles)
    let instr = cpu.read_instr()
    if cpu.cpsr.thumb:
      cpu.thumb_execute(instr)
    else:
      cpu.arm_execute(instr)
    var remaining = cpu.gba.bus.cycles
    let total = remaining + cpu.gba.bus.synced
    when defined(pcprofile):
      prof_cycles[prof_region] += uint64(max(1, total))
      if prof_region == 3:
        prof_iwram[(cpu.r[15] shr 10) and 31] += uint64(max(1, total))
    if total == 0: remaining = 1  # forward-progress guarantee
    cpu.gba.bus.cycles = 0
    cpu.gba.bus.synced = 0
    if cpu.entered_waitloop:
      cpu.waitloop_skip(remaining)
    else:
      cpu.gba.scheduler.tick(remaining)
  else:
    # Halted: drain events until something wakes the CPU or the frame ends.
    while cpu.halted and cpu.gba.ppu.frame == 0:
      cpu.gba.scheduler.fast_forward()
      # A DMA dispatched from a handler bills its cycles to bus.cycles, which
      # a running CPU closes out with scheduler.tick after each instruction.
      # A halted one never does, so the debt rides until the wake and delays
      # it by everything the DMAs did while the CPU was asleep. Commit it
      # here: the time passed, and it belongs to nobody.
      # If the wake comes while a DMA still has the bus, the CPU resumes on
      # the DMA's LAST cycle, not after it: tests/roms/payloads/halthb.s on an
      # AGB SP wakes on the H-blank interrupt at 1003 with no DMA armed and at
      # 1004 / 1006 / 1010 under an H-blank DMA of one, two and four words,
      # where waiting the burst out reads 1005 / 1007 / 1011. (The same cycle
      # a running CPU gets back when its internal cycle meets a DMA,
      # docs/playtest-bugs.md section 22.)
      let pending = cpu.gba.bus.cycles
      if pending > 0:
        cpu.gba.bus.cycles = 0
        cpu.gba.scheduler.tick(pending - 1)
        if cpu.halted:
          cpu.gba.scheduler.tick(1)
