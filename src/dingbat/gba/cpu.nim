# CPU implementation (included by gba.nim)

when defined(gbaskipcap):
  const gbaskipcap* {.intdefine.}: int = 4
    ## Cycles an idle-loop skip may advance at once (see the waitloop path).

proc mode_bank*(m: CpuMode): int =
  # `m` comes from guest-controlled bits (SPSR mode field on exception return,
  # MSR CPSR writes), so it can hold any 5-bit pattern, not just the defined
  # modes: Prince of Tennis 2004 runs into the weeds and executes a data word
  # as `subs pc, lr` with SPSR mode bits 0x1E. Hardware copies the raw bits
  # into the CPSR and register banking degrades gracefully; like mGBA's
  # _ARMSelectBank, map unrecognized patterns to the user bank instead of
  # trapping on the (previously exhaustive) case.
  # (Dispatch on the raw ordinal: an exhaustive enum case would treat the
  # else as unreachable and compile invalid values into a trap.)
  case uint32(m)
  of uint32(modeUSR), uint32(modeSYS): 0
  of uint32(modeFIQ):                  1
  of uint32(modeIRQ):                  2
  of uint32(modeSVC):                  3
  of uint32(modeABT):                  4
  of uint32(modeUND):                  5
  else:                                0  # invalid pattern: no banked registers

proc new_cpu*(gba: GBA): CPU =
  result = CPU(
    gba: gba,
    cpsr: cast[PSR](uint32(modeSYS)),
    spsr: cast[PSR](uint32(modeSYS)),
    pipeline: Pipeline(),
    halted: false,
    count_cycles: 0,
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
  # BIOS open-bus latch after boot (GBATEK: 0xE129F000, the msr at the end
  # of the boot sequence)
  cpu.gba.bus.bios_latch = 0xE129F000'u32
  cpu.clear_pipeline()

proc switch_mode*(cpu: CPU; new_mode: CpuMode) =
  let old_mode  = cast[CpuMode](cpu.cpsr.mode)
  if new_mode == old_mode: return
  let new_bank  = mode_bank(new_mode)
  let old_bank  = mode_bank(old_mode)
  if new_mode == modeFIQ or old_mode == modeFIQ:
    for idx in 0..4:
      cpu.reg_banks[old_bank][idx] = cpu.r[8 + idx]
      cpu.r[8 + idx] = cpu.reg_banks[new_bank][idx]
  cpu.reg_banks[old_bank][5] = cpu.r[13]
  cpu.reg_banks[old_bank][6] = cpu.r[14]
  cpu.spsr_banks[old_bank]   = uint32(cpu.spsr)
  cpu.r[13]         = cpu.reg_banks[new_bank][5]
  cpu.r[14]         = cpu.reg_banks[new_bank][6]
  # Restore the destination mode's banked SPSR. Exception entry (IRQ/UND/SWI)
  # overwrites it with the interrupted CPSR afterwards; an msr-initiated mode
  # switch must NOT touch it, or a nested-interrupt handler switching back to
  # IRQ mode destroys SPSR_irq and the exception return restores garbage
  cpu.spsr          = cast[PSR](cpu.spsr_banks[new_bank])
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
    # Exception-entry overhead beyond the pipeline refill. The ARM7TDMI data
    # sheet costs an exception entry at 2S+1N and the matching return (a
    # data-processing write to r15 with the S bit) at 2S+1N, so the pair costs
    # six cycles on top of the handler body; the two refills the pipeline model
    # already charges account for four of them. How the remaining two split
    # between entry and return is what the mGBA suite pins, and it is not even:
    # the handler's first instruction runs FOUR cycles after the interrupted
    # instruction's boundary (Timer IRQ tests; three fails 21 of the 90 rows),
    # which leaves one cycle - not two - for the return (see
    # exception_return_restore). Unconditional: this is the vector sequence
    # itself, so it does not vary with what the CPU was doing beforehand.
    cpu.gba.bus.add_cycles(2)

proc und*(cpu: CPU) =
  # ARM7TDMI Undefined Instruction trap: LR_und holds the address of the
  # instruction after the undefined one (PC - 4 in ARM, PC - 2 in THUMB)
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
  # Pipeline refill: two sequential fetches at the branch destination
  # (1 cycle each in IWRAM/BIOS, waitstate-dependent in EWRAM/ROM)
  let page = int(bits_range(cpu.r[15], 24, 27))
  if page < 0x8 or page > 0xD:
    # Execution left the gamepak: the prefetcher only runs while the CPU
    # executes from ROM, so the buffered stream is abandoned. Without this
    # a SWI into the BIOS banks the whole handler's runtime as prefetch
    # credit and the return fetches come out too cheap (mGBA suite BIOS
    # timing tests, prefetch columns, under the official BIOS).
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
        # The latch holds the newest pipeline fetch, which runs two
        # instructions ahead of execution (hardware-verified: after a SWI
        # the latch is the opcode 8 bytes past the BIOS's `movs pc, lr`)
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
  ## Internal (I) cycles: CPU busy, no bus access
  cpu.gba.bus.add_cycles(n)

proc mul_i_cycles*(rs: uint32; signed_early_term: bool): int {.inline.} =
  ## Booth's algorithm early termination: 1-4 internal cycles depending on
  ## the magnitude of the multiplier. Signed multiplies also terminate early
  ## on all-ones (negative) prefixes.
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
  else: false  # NV (never) - ARMv4T reserved, treated as no-op

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
  # Throwaway Golden Sun probe state (see the gsprobe block in tick).
  var gsProbePc*: array[0x800, uint32]   # halfword-granular PC hit counts, 0x03000000..0xFFF
  var gsProbeLog*: seq[(uint32, uint32, uint32, uint32, uint32, uint32)] = @[]
  var gsProbeIn*: bool

const NO_HLE_HOOK* = 0xFFFFFFFF'u32
  ## hle_hook_pc sentinel: no audio-HLE hook armed. A real hook PC is a
  ## RAM-resident instruction address, so this can never collide.

proc refresh_hle_hook*(gba: GBA) =
  ## Recompute the CPU's collapsed audio-HLE hook sentinel. Called once per
  ## frame (after the driver frame polls) and again whenever MP2K learns its
  ## mixer entry mid-frame, so every arm/disarm/re-point is picked up.
  ##
  ## One slot serves both drivers because they are mutually exclusive by
  ## construction: gs_frame_poll refuses to engage once MP2K has learned a
  ## hook, and MP2K only ever probes on its own SoundInfo ident, which the
  ## Camelot work area never presents.
  var pc = NO_HLE_HOOK
  var probing = false
  if gba.mp2k_hle:
    if gba.mp2k != nil:
      if gba.mp2k.hook_addr != 0xFFFFFFFF'u32: pc = gba.mp2k.hook_addr
      elif gba.mp2k.probing: probing = true
    if pc == NO_HLE_HOOK and gba.gs_bon != nil and gba.gs_bon.engaged:
      pc = gba.gs_bon.hook_addr
  gba.cpu.hle_hook_pc = pc
  gba.cpu.hle_probing = probing

proc fire_hle_hook(cpu: CPU; cur: uint32): bool {.noinline.} =
  ## Run whichever audio-HLE hook is armed at `cur`. Returns true when the
  ## caller must leave tick immediately because PC was rewritten.
  let gba = cpu.gba
  let m = gba.mp2k
  if m != nil and cur == m.hook_addr:
    m.dbg_hook_fires.inc
    m.mixer_hook()
    if m.skip:
      m.dbg_skip_fires.inc
      # EXPERIMENTAL perf probe: BX LR to skip the real mixer body and
      # reclaim its CPU cycles. The hook sits at the mixer's entry, BEFORE
      # any stack push, so r14 still holds the return address and sp is
      # untouched. NOT correct (the engine's per-frame envelope ramp normally
      # happens inside this function) — this measures the performance ceiling
      # of an aggressive HLE only, not a shippable path.
      let lr = cpu.r[14]
      cpu.cpsr.thumb = (lr and 1) != 0
      cpu.r[15] = if cpu.cpsr.thumb: lr and not 1'u32 else: lr and not 3'u32
      cpu.clear_pipeline()
      return true
    return false
  # Camelot "Bon" HLE (Golden Sun) mixer-entry hook — fires once per frame at
  # the driver's per-channel processing entry. Shadow-only: reads state,
  # never alters control flow.
  let g = gba.gs_bon
  if g != nil and g.engaged and cur == g.hook_addr:
    g.gs_mixer_hook()
  false

proc tick*(cpu: CPU) =
  # Take a pending IRQ before the IntrWait re-halt check: the handler must
  # run (and set the BIOS mirror flags) or IntrWait would re-halt forever
  if not cpu.halted and cpu.irq_line and not cpu.cpsr.irq_disable:
    cpu.irq()
  # The halt-wake entry discount only applies to an IRQ taken at the first
  # boundary after the wake (a wake with the I flag set resumes execution;
  # any later IRQ is a normal running-state entry)
  cpu.halt_wake = false
  if cpu.intr_wait_active and not cpu.halted:
    # Execution is back at the instruction after an IntrWait SWI, meaning the
    # user IRQ handler (if any) has returned. Re-halt unless satisfied.
    let cur = cpu.r[15] - (if cpu.cpsr.thumb: 4'u32 else: 8'u32)
    if cur == cpu.intr_wait_resume_addr:
      cpu.check_intr_wait()
  if cpu.halt_resume_charge != 0 and not cpu.halted:
    # Execution is back at the instruction after an HLE Halt/Stop SWI; charge
    # the BIOS return path that the real BIOS executes after the wake
    let cur = cpu.r[15] - (if cpu.cpsr.thumb: 4'u32 else: 8'u32)
    if cur == cpu.halt_resume_addr:
      cpu.gba.bus.add_cycles(int(cpu.halt_resume_charge))
      cpu.halt_resume_charge = 0
      # The dispatcher's exit path pops the caller's r12 back (staged in its
      # SVC-stack slot by Halt/Stop and the interruptible decompression
      # parks alike)
      cpu.r[12] = cpu.gba.bus.read_word_internal(cpu.svc_sp() - 8)
      if cpu.halt_resume_pop:
        # Halt/Stop held the dispatcher's {r2, lr} frame live (System sp
        # shifted down 8; r2 = HALTCNT value, lr = 0x170 while halted) —
        # pop it back. Decompression parks never shifted sp, so they skip
        # this (their r2/lr were never touched).
        cpu.halt_resume_pop = false
        let usp = cpu.sys_sp() + 8
        cpu.r[2] = cpu.gba.bus.read_word_internal(usp - 8)
        cpu.set_sys_lr(cpu.gba.bus.read_word_internal(usp - 4))
        cpu.set_sys_sp(usp)
  if not cpu.halted:
    # EXPLORATORY: audio-HLE mixer hooks (MP2K's runtime-learned SoundMainRAM
    # entry, its bounded learning probe, and the Camelot "Bon" entry). All
    # three fire at most once per frame but sat on the per-instruction path,
    # each re-testing its own enable flag + driver pointer + address — more
    # host time than the mixing itself. They now share one sentinel compare
    # (see refresh_hle_hook); the work moves out of line into fire_hle_hook.
    # With HLE off this is a single load and a perfectly-predicted branch.
    if cpu.hle_hook_pc != NO_HLE_HOOK or cpu.hle_probing:
      let cur = cpu.r[15] - (if cpu.cpsr.thumb: 4'u32 else: 8'u32)
      if cur == cpu.hle_hook_pc:
        if cpu.fire_hle_hook(cur): return
      elif cpu.hle_probing:
        # Learning probe (bounded: engine-init to first mixer pass). Inline
        # prefilter: RAM-region PC and r0 == &SoundInfo; the out-of-line probe
        # does the lock check and the learn.
        let m = cpu.gba.mp2k
        let region = cur shr 24
        if (region == 0x02'u32 or region == 0x03'u32) and
           cpu.r[0] == m.probe_sound_info:
          m.probe_pc(cur)
    when defined(gsprobe):
      # Throwaway Golden Sun "Bon" mixer probe: histogram of executed IWRAM
      # PCs + entry events (outside IWRAM -> inside), with caller LR/r0-r3.
      block:
        let cur = cpu.r[15] - (if cpu.cpsr.thumb: 4'u32 else: 8'u32)
        let inIw = (cur shr 24) == 0x03'u32 and (cur and 0x7FFF'u32) < 0x1000'u32
        if inIw:
          gsProbePc[int((cur and 0xFFF'u32) shr 1)].inc
          if not gsProbeIn and gsProbeLog.len < 4000:
            gsProbeLog.add (cur, cpu.r[14], cpu.r[0], cpu.r[1], cpu.r[2],
                            uint32(cpu.gba.ppu.vcount))
            # At interesting entries, also snapshot ch0/ch1 status+env+START
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
    let instr = cpu.read_instr()
    if cpu.cpsr.thumb:
      cpu.thumb_execute(instr)
    else:
      cpu.arm_execute(instr)
    # The DMA open-bus latch is visible only until the CPU completes an
    # instruction (its own fetches/reads then own the bus). Cleared BEFORE
    # scheduler.tick so a DMA fired at this instruction's boundary arms the
    # latch for the NEXT instruction.
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
    cpu.count_cycles += max(1, total)
    if cpu.entered_waitloop:
      # An idle loop only re-reads what it polls once per skip, so the skip
      # length IS that loop's sampling resolution, and the loop body's own
      # fetches move absolute-cycle bus state (rom_free_since) whether it polls
      # a register or RAM. The PSG's waveform deadlines used to be scheduler
      # events and were holding that resolution at ~32 cycles; moving them out
      # of evbuf (gba/apu.nim) let a skip run to the next PPU or sample event
      # instead, and the mGBA suite's "H-blank bit start" flips — which spin on
      # DISPSTAT and time the gaps with TM0 — went from 3-48 cycles out to
      # 124-394. They are events in every sense except which array they live in,
      # so they bound the skip here exactly as they did when they were queued.
      #
      # Catching the channels up first is what makes every deadline strictly
      # ahead of scheduler.cycles, which fast_forward_bounded needs to keep this
      # loop making progress.
      when defined(gbaskipcap):
        # -d:gbaskipcap=N bounds the skip by a stated constant instead of by
        # whatever the PSG's soonest deadline happens to be. A real Thumb spin
        # loop resolves ~15 cycles, so a small constant is the physically
        # defensible resolution; the PSG deadline is an inherited accident that
        # merely happens to be fine-grained. No catch-up is needed first: the
        # bound is trivially ahead of `cycles`, and the channels catch up in
        # closed form at their own observation points regardless.
        cpu.gba.scheduler.fast_forward_bounded(
          cpu.gba.scheduler.cycles + CycleCount(gbaskipcap))
      else:
        cpu.gba.apu.apu_catchup_all()
        cpu.gba.scheduler.fast_forward_bounded(cpu.gba.apu.apu_next_step())
      cpu.entered_waitloop = false
    else:
      cpu.gba.scheduler.tick(remaining)
  else:
    # Sleep tight: drain event batches until something wakes the CPU or the
    # frame ends, without bouncing through step_frame/tick for every event
    while cpu.halted and cpu.gba.ppu.frame == 0:
      cpu.gba.scheduler.fast_forward()
