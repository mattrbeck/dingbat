# CPU implementation (included by gba.nim)

when defined(gbaskipcap):
  const gbaskipcap* {.intdefine.}: int = 4
    ## Cycles an idle-loop skip may advance at once (see the waitloop path).

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
  # At ROM entry the BIOS leaves DISPCNT force-blanked and POSTFLG set
  # (hardware: gbaedge IDENT on AGB SP, docs/hwprobe.md).
  cpu.gba.ppu.dispcnt = cast[DISPCNT](0x0080'u16)
  cpu.gba.mmio.postflg = 1
  # BIOS open-bus value after boot (GBATEK, "BIOS Memory": 0xE129F000).
  cpu.gba.bus.bios_latch = 0xE129F000'u32
  cpu.clear_pipeline()

proc switch_mode*(cpu: CPU; new_mode: CpuMode) =
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
  if not cpu.cpsr.irq_disable:
    let lr = cpu.r[15] - (if cpu.cpsr.thumb: 0'u32 else: 4'u32)
    let old_cpsr = cpu.cpsr
    cpu.switch_mode(modeIRQ)
    cpu.spsr = old_cpsr
    cpu.cpsr.thumb = false
    cpu.cpsr.irq_disable = true
    discard cpu.set_reg(14, lr)
    discard cpu.set_reg(15, 0x18'u32)
    # Entry/return overhead: the ARM7TDMI data sheet costs exception entry
    # and the S-bit return at 2S+1N each, six cycles beyond the two pipeline
    # refills set_reg(15) charges. The split is uneven: entry +2 here (the
    # handler's first instruction runs 4 cycles after the interrupted
    # boundary; mGBA suite Timer IRQ rows), return +1 minus one given back in
    # exception_return_restore.
    cpu.gba.bus.add_cycles(2)
    # Interrupting code that executes from the gamepak also pays for the
    # in-flight 32-bit ROM fetch: +2*S16 (hardware: gbaedge IRQLAT2 and
    # IRQWIN2 on AGB SP, docs/hwprobe.md; the mGBA suite Timer IRQ rows run
    # from IWRAM and pin the no-stall case). A halt-wake entry fetches
    # nothing, so it is exempt.
    if not cpu.halt_wake:
      let page = int(bits_range(lr, 24, 27))
      if page in 8..13:
        cpu.gba.bus.add_cycles(2 * int(cpu.gba.bus.wait16_s[page]))

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
  if page < 0x8 or page > 0xD:
    # The prefetcher only runs while executing from ROM; leaving the gamepak
    # abandons the buffered stream (mGBA suite BIOS timing, prefetch columns).
    cpu.gba.bus.rom_next_addr = 1
    cpu.gba.bus.rom_hot = false
  if cpu.cpsr.thumb:
    cpu.r[15] += 4
    cpu.gba.bus.add_cycles(2 * int(cpu.gba.bus.wait16_s[page]))
  else:
    cpu.r[15] += 8
    cpu.gba.bus.add_cycles(2 * int(cpu.gba.bus.wait32_s[page]))

proc read_instr*(cpu: CPU): uint32 {.inline.} =
  cpu.refill_pending = false
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

proc idle*(cpu: CPU; n: int) {.inline.} =
  ## Internal (I) cycles: no bus access.
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

const NO_HLE_HOOK* = 0xFFFFFFFF'u32
  ## hle_gate value for "MP2K learning probe running, no hook armed"; a real
  ## hook PC can never be 0xFFFFFFFF.

proc refresh_hle_hook*(gba: GBA) =
  ## Recompute cpu.hle_gate; called once per frame and whenever MP2K learns
  ## its mixer entry. One slot serves both drivers: gs_frame_poll does not
  ## engage once MP2K has a hook, and MP2K only probes its own SoundInfo.
  var pc = NO_HLE_HOOK
  var probing = false
  if gba.mp2k_hle:
    if gba.mp2k != nil:
      if gba.mp2k.hook_addr != 0xFFFFFFFF'u32: pc = gba.mp2k.hook_addr
      elif gba.mp2k.probing: probing = true
    if pc == NO_HLE_HOOK and gba.gs_bon != nil and gba.gs_bon.engaged:
      pc = gba.gs_bon.hook_addr
  gba.cpu.hle_gate = if pc != NO_HLE_HOOK: pc
                     elif probing: NO_HLE_HOOK
                     else: 0'u32

proc fire_hle_hook(cpu: CPU; cur: uint32): bool {.noinline.} =
  ## Run the audio-HLE hook armed at `cur`; true when PC was rewritten.
  let gba = cpu.gba
  let m = gba.mp2k
  if m != nil and cur == m.hook_addr:
    m.dbg_hook_fires.inc
    m.mixer_hook()
    if m.skip:
      m.dbg_skip_fires.inc
      # Perf-ceiling probe only, not correct: BX LR past the mixer body (the
      # hook sits before any stack push, so r14/sp are intact) skips the
      # engine's per-frame envelope ramp.
      let lr = cpu.r[14]
      cpu.cpsr.thumb = (lr and 1) != 0
      cpu.r[15] = if cpu.cpsr.thumb: lr and not 1'u32 else: lr and not 3'u32
      cpu.clear_pipeline()
      return true
    return false
  # Camelot "Bon" (Golden Sun) hook: shadow-only, never alters control flow.
  let g = gba.gs_bon
  if g != nil and g.engaged and cur == g.hook_addr:
    g.gs_mixer_hook()
  false

proc tick*(cpu: CPU) =
  # IRQ before the IntrWait re-halt check: the handler must run (and set the
  # BIOS mirror flags) or IntrWait re-halts forever.
  if not cpu.halted and cpu.irq_line and not cpu.cpsr.irq_disable:
    cpu.irq()
  # The halt-wake entry exemption covers only the first boundary after the wake.
  cpu.halt_wake = false
  if cpu.intr_wait_active and not cpu.halted:
    # Back at the instruction after an IntrWait SWI: re-halt unless satisfied.
    let cur = cpu.r[15] - (if cpu.cpsr.thumb: 4'u32 else: 8'u32)
    if cur == cpu.intr_wait_resume_addr:
      cpu.check_intr_wait()
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
      let remain = cpu.hle_charge_units_interruptible(int(cpu.halt_resume_charge))
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
    # Audio-HLE hooks share one sentinel compare on the per-instruction path
    # (refresh_hle_hook); the work is out of line in fire_hle_hook.
    let gate = cpu.hle_gate
    if gate != 0:
      let cur = cpu.r[15] - (if cpu.cpsr.thumb: 4'u32 else: 8'u32)
      if cur == gate:
        if cpu.fire_hle_hook(cur): return
      elif gate == NO_HLE_HOOK:
        # MP2K learning probe; inline prefilter is RAM PC and r0 == &SoundInfo.
        let m = cpu.gba.mp2k
        let region = cur shr 24
        if (region == 0x02'u32 or region == 0x03'u32) and
           cpu.r[0] == m.probe_sound_info:
          m.probe_pc(cur)
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
    when defined(pftrace):
      pft("INSTR pc=" & toHex(cpu.r[15], 8) & " t=" & $cpu.cpsr.thumb &
          " sched=" & $cpu.gba.scheduler.cycles & " busc=" & $cpu.gba.bus.cycles)
    let instr = cpu.read_instr()
    if cpu.cpsr.thumb:
      cpu.thumb_execute(instr)
    else:
      cpu.arm_execute(instr)
    # The DMA open-bus latch lasts one CPU instruction. Cleared before
    # scheduler.tick so a DMA at this boundary arms it for the next one.
    cpu.gba.bus.dma_open_bus_armed = false
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
      # The skip length is the idle loop's polling resolution. The PSG
      # waveform deadlines are not in evbuf (gba/apu.nim) but must still
      # bound the skip, or DISPSTAT-polling timing rows drift (mGBA suite
      # "H-blank bit start"). Catching the channels up first keeps every
      # deadline strictly ahead of scheduler.cycles, which
      # fast_forward_bounded needs to make progress.
      when defined(gbaskipcap):
        # Bound the skip by a constant instead (a Thumb spin loop resolves
        # ~15 cycles); no catch-up needed since the bound is already ahead.
        cpu.gba.scheduler.fast_forward_bounded(
          cpu.gba.scheduler.cycles + CycleCount(gbaskipcap))
      else:
        cpu.gba.apu.apu_catchup_all()
        cpu.gba.scheduler.fast_forward_bounded(cpu.gba.apu.apu_next_step())
      cpu.entered_waitloop = false
    else:
      cpu.gba.scheduler.tick(remaining)
  else:
    # Halted: drain events until something wakes the CPU or the frame ends.
    while cpu.halted and cpu.gba.ppu.frame == 0:
      cpu.gba.scheduler.fast_forward()
