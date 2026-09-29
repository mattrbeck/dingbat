# Waitloop detection (included by gba.nim)
#
# A waitloop is a short backward Thumb loop that cannot change its own state:
# every instruction is read-only and no register read in the loop was
# written earlier in it (a loop-carried counter like `subs r2, #1` must run
# at real speed). Only Thumb is hooked (thumb_conditional_branch). A verdict
# sets cpu.entered_waitloop; cpu.tick then fast-forwards to the next event
# instead of ticking. docs/research_waitloop_tracer.md surveys the limits.

proc build_waitloop_lut*(): seq[WLInstrKind] =
  result = newSeq[WLInstrKind](256)
  for idx in 0 ..< 256:
    result[idx] =
      if   (idx and 0b11110000) == 0b11110000: wlLongBranchLink
      elif (idx and 0b11111000) == 0b11100000: wlUnconditionalBranch
      elif (idx and 0b11111111) == 0b11011111: wlSoftwareInterrupt
      elif (idx and 0b11110000) == 0b11010000: wlConditionalBranch
      elif (idx and 0b11110000) == 0b11000000: wlMultipleLoadStore
      elif (idx and 0b11110110) == 0b10110100: wlPushPopRegisters
      elif (idx and 0b11111111) == 0b10110000: wlAddOffsetToStackPointer
      elif (idx and 0b11110000) == 0b10100000: wlLoadAddress
      elif (idx and 0b11110000) == 0b10010000: wlSpRelativeLoadStore
      elif (idx and 0b11110000) == 0b10000000: wlLoadStoreHalfword
      elif (idx and 0b11100000) == 0b01100000: wlLoadStoreImmediateOffset
      elif (idx and 0b11110010) == 0b01010010: wlLoadStoreSignExtended
      elif (idx and 0b11110010) == 0b01010000: wlLoadStoreRegisterOffset
      elif (idx and 0b11111000) == 0b01001000: wlPcRelativeLoad
      elif (idx and 0b11111100) == 0b01000100: wlHighRegBranchExchange
      elif (idx and 0b11111100) == 0b01000000: wlAluOperations
      elif (idx and 0b11100000) == 0b00100000: wlMoveCompareAddSubtract
      elif (idx and 0b11111000) == 0b00011000: wlAddSubtract
      elif (idx and 0b11100000) == 0b00000000: wlMoveShiftedRegister
      else: wlUnimplemented

proc parse_wl_instr*(kind: WLInstrKind; instr: uint16): Option[WLParsed] =
  case kind
  of wlPcRelativeLoad:
    # Literal-pool load: loop-invariant.
    let rd = bits_range(instr, 8, 10)
    some(WLParsed(read_only: true, read_bits: 0, write_bits: 1'u16 shl rd))
  of wlConditionalBranch:
    some(WLParsed(read_only: true,
                  read_bits:  1'u16 shl 15,
                  write_bits: 1'u16 shl 15))
  of wlMultipleLoadStore:
    let load = bit(instr, 11)
    let rb   = bits_range(instr, 8, 10)
    let list = bits_range(instr, 0, 7)
    var read_b: uint16 = 1'u16 shl rb
    var write_b: uint16 = 1'u16 shl rb
    if load:
      if list == 0: write_b = write_b or (1'u16 shl 15)
      else:         write_b = write_b or uint16(list)
    else:
      if list == 0: read_b = read_b or (1'u16 shl 15)
      else:         read_b = read_b or uint16(list)
    some(WLParsed(read_only: load, read_bits: read_b, write_bits: write_b))
  of wlLoadStoreHalfword:
    let load   = bit(instr, 11)
    let rb     = bits_range(instr, 3, 5)
    let rd     = bits_range(instr, 0, 2)
    var read_b: uint16 = 1'u16 shl rb
    if not load: read_b = read_b or (1'u16 shl rd)
    let write_b: uint16 = if load: 1'u16 shl rd else: 0'u16
    some(WLParsed(read_only: load, read_bits: read_b, write_bits: write_b))
  of wlLoadStoreImmediateOffset:
    let load   = bit(instr, 11)
    let rb     = bits_range(instr, 3, 5)
    let rd     = bits_range(instr, 0, 2)
    var read_b: uint16 = 1'u16 shl rb
    if not load: read_b = read_b or (1'u16 shl rd)
    let write_b: uint16 = if load: 1'u16 shl rd else: 0'u16
    some(WLParsed(read_only: load, read_bits: read_b, write_bits: write_b))
  of wlAluOperations:
    let op = bits_range(instr, 6, 9)
    let rs = bits_range(instr, 3, 5)
    let rd = bits_range(instr, 0, 2)
    let write_b: uint16 =
      if op == 0b1000 or op == 0b1010 or op == 0b1011: 0'u16
      else: 1'u16 shl rd
    some(WLParsed(read_only: true,
                  read_bits:  (1'u16 shl rs) or (1'u16 shl rd),
                  write_bits: write_b))
  of wlMoveCompareAddSubtract:
    let op = bits_range(instr, 11, 12)
    let rd = bits_range(instr, 8, 10)
    let read_b: uint16  = if op == 0: 0'u16 else: 1'u16 shl rd
    let write_b: uint16 = if op == 1: 0'u16 else: 1'u16 shl rd
    some(WLParsed(read_only: true, read_bits: read_b, write_bits: write_b))
  of wlAddSubtract:
    let imm_flag  = bit(instr, 10)
    let imm_or_rn = bits_range(instr, 6, 8)
    let rs        = bits_range(instr, 3, 5)
    let rd        = bits_range(instr, 0, 2)
    var read_b: uint16 = 1'u16 shl rs
    if not imm_flag: read_b = read_b or (1'u16 shl imm_or_rn)
    some(WLParsed(read_only: true, read_bits: read_b, write_bits: 1'u16 shl rd))
  of wlMoveShiftedRegister:
    let rs = bits_range(instr, 3, 5)
    let rd = bits_range(instr, 0, 2)
    some(WLParsed(read_only: true, read_bits: 1'u16 shl rs, write_bits: 1'u16 shl rd))
  of wlLoadStoreRegisterOffset, wlLoadStoreSignExtended:
    # ldr / ldrb / ldrh / ldrsb / ldrsh [rb, ro] (Oshare Princess 3's
    # `ldrsh r0, [r0, r2]`); the stores, str / strb / strh, are not reads
    let load = if kind == wlLoadStoreRegisterOffset: bit(instr, 11)
               else: bit(instr, 10) or bit(instr, 11)
    if not load: return none(WLParsed)
    let ro = bits_range(instr, 6, 8)
    let rb = bits_range(instr, 3, 5)
    let rd = bits_range(instr, 0, 2)
    some(WLParsed(read_only: true, read_bits: (1'u16 shl ro) or (1'u16 shl rb),
                  write_bits: 1'u16 shl rd))
  of wlHighRegBranchExchange:
    # ADD / CMP / MOV with a high register (Crash Nitro Kart's `mov r1, sl`
    # ahead of its VCOUNT poll); BX / BLX leave the loop's analysis
    let op = bits_range(instr, 8, 9)
    let rd = bits_range(instr, 0, 2) or (bits_range(instr, 7, 7) shl 3)
    let rs = bits_range(instr, 3, 6)
    if op == 3 or rd == 15: return none(WLParsed)
    # `mov r8, r8` is the Thumb NOP (Horse & Pony: Let's Ride 2 pads its
    # poll with one): no register moves
    if op == 2 and rd == rs:
      return some(WLParsed(read_only: true, read_bits: 0'u16, write_bits: 0'u16))
    # r15 as an operand is this instruction's address + 4: loop-invariant
    let rs_b: uint16 = if rs == 15: 0'u16 else: 1'u16 shl rs
    case op
    of 0: some(WLParsed(read_only: true, read_bits: rs_b or (1'u16 shl rd),
                        write_bits: 1'u16 shl rd))
    of 1: some(WLParsed(read_only: true, read_bits: rs_b or (1'u16 shl rd),
                        write_bits: 0'u16))
    else: some(WLParsed(read_only: true, read_bits: rs_b, write_bits: 1'u16 shl rd))
  else:
    none(WLParsed)

const WL_NO_LOAD = 0xFFFFFFFF'u32

proc scan_thumb_loop(cpu: CPU; start_addr, end_addr: uint32; first_load: var uint32): bool =
  ## Whether the Thumb body [start_addr, end_addr) reads only and carries no
  ## register from one iteration into the next.
  var written_bits: uint16 = 0
  var never_write: uint16  = 0
  var flags_set = false
  var cur_addr = start_addr
  while cur_addr < end_addr:
    let instr = uint16(cpu.gba.bus.read_half_internal(cur_addr))
    let kind  = cpu.waitloop_instr_lut[instr shr 8]
    if kind == wlConditionalBranch:
      # A second way out: a conditional branch that leaves the loop (Salt
      # Lake 2002 polls two flags and leaves on either). An iteration that
      # reached the loop's own branch did not take it. Its condition must
      # come from flags this iteration set, not ones carried in from the last.
      let target = cur_addr + 4 + uint32(cast[int32](cast[int8](uint8(instr and 0xFF))) * 2)
      if not flags_set or (target >= start_addr and target <= end_addr) or
         bits_range(instr, 8, 11) >= 0xE:
        return false
      cur_addr += 2
      continue
    if kind in {wlMoveShiftedRegister, wlAddSubtract, wlMoveCompareAddSubtract,
                wlAluOperations} or
       (kind == wlHighRegBranchExchange and bits_range(instr, 8, 9) == 1):
      flags_set = true
    let parsed = parse_wl_instr(kind, instr)
    if parsed.isNone or not parsed.get.read_only: return false
    let p = parsed.get
    if first_load == WL_NO_LOAD and
       kind in {wlMultipleLoadStore, wlLoadStoreHalfword, wlLoadStoreImmediateOffset,
                wlLoadStoreRegisterOffset, wlLoadStoreSignExtended}:
      first_load = cur_addr
    never_write = never_write or (p.read_bits and not written_bits)
    # Fold in this instruction's writes before checking, so a read-modify-
    # write of one register (subs r2, #1) counts as loop-carried.
    written_bits = written_bits or p.write_bits
    if (written_bits and never_write) > 0: return false
    if (p.write_bits and (1'u16 shl 15)) > 0: return false
    cur_addr += 2
  true

proc scan_arm_loop(cpu: CPU; start_addr, end_addr: uint32; first_load: var uint32): bool =
  ## The ARM counterpart: every instruction unconditional, and either data
  ## processing (no multiply, swap or PSR transfer, not writing r15) or a
  ## load with no writeback (Digimon Battle Spirit's `ldrb r9, [r8]; cmp
  ## r9, #0; beq`). r15 as an operand is the instruction's address + 8.
  var written_bits: uint16 = 0
  var never_write: uint16  = 0
  var flags_set = false
  var cur_addr = start_addr
  while cur_addr < end_addr:
    let i = cpu.gba.bus.read_word_internal(cur_addr)
    if (i and 0x0F000000'u32) == 0x0A000000'u32 and (i shr 28) < 0xE'u32:
      # B<cond> out of the loop, on flags this iteration set (as in Thumb)
      let target = uint32(int(cur_addr) + 8 + (cast[int32](bits_range(i, 0, 23) shl 8) shr 6))
      if not flags_set or (target >= start_addr and target <= end_addr): return false
      cur_addr += 4
      continue
    if (i shr 28) != 0xE'u32: return false
    let rd = bits_range(i, 12, 15)
    let rn = bits_range(i, 16, 19)
    var reads, writes: uint16
    template reg_bit(r: uint32): uint16 = (if r == 15: 0'u16 else: 1'u16 shl r)
    if (i and 0x0C000000'u32) == 0'u32:
      if (i and 0x0E000090'u32) == 0x00000090'u32:
        # Multiplies, swaps, halfword and signed transfers: only a load that
        # indexes before and does not write back
        if (i and 0x60'u32) == 0 or not bit(i, 20) or not bit(i, 24) or bit(i, 21):
          return false
        if rd == 15: return false
        reads = reg_bit(rn)
        if not bit(i, 22): reads = reads or reg_bit(bits_range(i, 0, 3))
        writes = 1'u16 shl rd
        if first_load == WL_NO_LOAD: first_load = cur_addr
      else:
        let op = bits_range(i, 21, 24)
        let s = bit(i, 20)
        let test = op >= 8 and op <= 11
        if test and not s: return false        # MRS / MSR / BX
        if rd == 15 and not test: return false
        if op in [5'u32, 6, 7] and not flags_set: return false   # ADC SBC RSC
        if not (op == 13 or op == 15): reads = reg_bit(rn)
        if not bit(i, 25):
          let rm = bits_range(i, 0, 3)
          if bit(i, 4):
            if bit(i, 7) or rm == 15: return false
            reads = reads or reg_bit(rm) or reg_bit(bits_range(i, 8, 11))
          else:
            reads = reads or reg_bit(rm)
            # RRX reads the carry
            if bits_range(i, 5, 6) == 3 and bits_range(i, 7, 11) == 0 and
               not flags_set: return false
        if not test: writes = 1'u16 shl rd
        if s: flags_set = true
    elif (i and 0x0C000000'u32) == 0x04000000'u32:
      # LDR / LDRB, pre-indexed, no writeback
      if not bit(i, 20) or not bit(i, 24) or bit(i, 21) or rd == 15: return false
      reads = reg_bit(rn)
      if bit(i, 25):
        if bit(i, 4): return false
        reads = reads or reg_bit(bits_range(i, 0, 3))
      writes = 1'u16 shl rd
      if first_load == WL_NO_LOAD: first_load = cur_addr
    else:
      return false
    never_write = never_write or (reads and not written_bits)
    written_bits = written_bits or writes
    if (written_bits and never_write) > 0: return false
    cur_addr += 4
  true

proc wl_key(start_addr, end_addr: uint32; arm: static bool): uint32 {.inline.} =
  ## A loop's identity in the verdict caches: its start, bit 0 for ARM, and
  ## its length in bits 28-31 (addresses there are open bus, never judged).
  ## Two loops can share a start: Rockman Zero 4's inner `bcc` and outer
  ## `bne` both go back to 0x08000906, and only the inner is a waitloop.
  when arm: start_addr or 1 or (((end_addr - start_addr) shr 2) shl 28)
  else: start_addr or (((end_addr - start_addr - 2) shr 1) shl 28)

proc judge_loop[arm: static bool](cpu: CPU; start_addr: uint32; end_addr: uint32) =
  # Analyze only when the same backward-branch target arrives twice in a row
  # (branch_dest; the defer records every call's target). ARM loops are
  # keyed with bit 0 set (their addresses are word-aligned), so the caches
  # never mistake one for Thumb code at the same address.
  let key = wl_key(start_addr, end_addr, arm)
  defer: cpu.branch_dest = key
  if key != cpu.branch_dest:
    cpu.wl_volatile_at = 0
    return
  # This run of the loop just read something volatile (analyze_loop): the
  # next WL_VOLATILE_REST iterations would too, most likely, and are not
  # judged. Only a hint -- a skipped judgement never makes a skip -- so a
  # value that settles (a device finishing) is picked up that much later.
  if key == cpu.wl_volatile_at:
    dec cpu.wl_volatile_rest
    if cpu.wl_volatile_rest > 0: return
    cpu.wl_volatile_at = 0
  when arm:
    if not (start_addr < end_addr and (end_addr - start_addr) <= WL_ARM_BODY_MAX): return
  else:
    if not (start_addr < end_addr and
            (end_addr - start_addr) >= 2 and
            (end_addr - start_addr) <= WL_BODY_MAX):
      return
  # Cache a waitloop verdict only for ROM addresses: RAM code can be
  # overwritten. A rejection is cached anywhere -- it can only ever cost a
  # skip, never make one -- or a hot RAM loop (an IWRAM mixer's ARM code)
  # would be scanned again on every iteration.
  let cacheable = cpu.cache_waitloop_results and
                  bits_range(start_addr, 24, 27) in 0x8'u32 .. 0xD'u32
  if cpu.cache_waitloop_results:
    if key == cpu.last_non_waitloop:
      return
    if key in cpu.identified_non_waitloops:
      cpu.last_non_waitloop = key
      return
  if cacheable:
    if key == cpu.last_waitloop:
      cpu.entered_waitloop = true
      return
    if key in cpu.identified_waitloops:
      cpu.last_waitloop = key
      cpu.last_waitloop_first_load = cpu.waitloop_first_load.getOrDefault(key, WL_NO_LOAD)
      cpu.entered_waitloop = true
      return
  # RAM code under MEMCNT's swap: the loop's own reads below are unswapped
  if not cacheable and start_addr < 0x04000000'u32 and
     (cpu.gba.bus.sync_bits and SB_SWAP) != 0:
    return
  var first_load = WL_NO_LOAD
  let ok = when arm: cpu.scan_arm_loop(start_addr, end_addr, first_load)
           else: cpu.scan_thumb_loop(start_addr, end_addr, first_load)
  if not ok:
    if cpu.cache_waitloop_results:
      cpu.identified_non_waitloops.incl(key)
      cpu.last_non_waitloop = key
    return
  if cacheable:
    cpu.identified_waitloops.incl(key)
    cpu.waitloop_first_load[key] = first_load
    cpu.last_waitloop = key
  cpu.last_waitloop_first_load = first_load
  cpu.entered_waitloop = true

# Transparency. A skip must leave the game exactly where running the loop
# would have: the same instruction at the same cycle, with every event
# dispatched at its own cycle. So cpu.tick advances only whole iterations of
# the loop's measured period, stops short of the next event, and runs the
# iteration that crosses the event for real. That holds only when
#   - the loop has run two consecutive iterations of equal period (a DMA
#     stall or a prefetch warm-up changes it),
#   - no event ran between the loop reading its state and taking the branch
#     (otherwise the branch acts on a value the event has since replaced),
#   - it read nothing that changes with time but not with an event.
# A verdict that fails any of these runs the next iteration at real speed.
proc analyze_loop*(cpu: CPU; start_addr: uint32; end_addr: uint32; arm: static bool = false) =
  ## At a taken backward branch at end_addr to start_addr, in either state
  ## (thumb_conditional_branch, arm_branch).
  if not cpu.attempt_waitloop_detection: return
  # Code outside real memory -- unmapped space, or the gamepak past the end
  # of the ROM -- is open bus: nothing a crashed program runs there is a
  # loop the detector can reason about (Guilty Gear X - Advance Edition (J)
  # [b2], a bad dump, "waits" at 0x08800364 of an 8 MB ROM)
  if start_addr >= 0x10000000'u32 or
     (start_addr >= 0x08000000'u32 and
      (start_addr and 0x01FFFFFF'u32) >= cpu.gba.bus.rom_len):
    return
  cpu.judge_loop[:arm](start_addr, end_addr)
  if not cpu.entered_waitloop: return
  let key = wl_key(start_addr, end_addr, arm)
  const LEAD = when arm: 8'u32 else: 4'u32   # r15's lead on the instruction
  # Consecutive verdicts on one loop are consecutive iterations: the period,
  # the dispatches and the volatile reads below are all since the last one.
  let t = int64(cpu.gba.bus.sched.cycles) + int64(cpu.gba.bus.cycles)  # bus_now
  let same = key == cpu.wl_addr
  let period = if same: t - cpu.wl_time else: -1'i64
  let stable = same and period > 0 and period == cpu.wl_period
  cpu.wl_addr = key
  cpu.wl_time = t
  cpu.wl_period = period
  let dispatched = cpu.gba.dispatch_count != cpu.wl_dispatch_mark
  cpu.wl_dispatch_mark = cpu.gba.dispatch_count
  let volatile = cpu.gba.bus.volatile_read
  cpu.gba.bus.volatile_read = false
  cpu.wl_reads_io = cpu.gba.bus.io_read
  cpu.gba.bus.io_read = 0
  cpu.wl_contended = cpu.gba.bus.contended_access
  cpu.gba.bus.contended_access = false
  var fresh = true
  if dispatched:
    # r15 reads instruction + 4 while an instruction runs (a catch-up at its
    # read) and next instruction + 4 at the tick that ends it, so events
    # that ran at PCs start+4 .. first_load+4 all preceded the first read
    let last = if cpu.last_waitloop_first_load == WL_NO_LOAD: end_addr
               else: cpu.last_waitloop_first_load
    let pc = cpu.gba.last_dispatch_pc
    fresh = pc >= start_addr + LEAD and pc <= last + LEAD
    when WL_QUIET_EVENTS:
      # One that ran after the read is harmless if it could not have changed
      # what was read: FireRed's WaitForVBlank (an IWRAM flag) otherwise ran
      # an extra iteration for real after each line event, or not, by where
      # in the loop the line happened to fall.
      if not fresh and not cpu.gba.wl_unsafe and not cpu.irq_line:
        fresh = true
  when WL_QUIET_EVENTS:
    # For events the branch's own refill dispatches after this (waitloop_skip)
    cpu.wl_quiet = not cpu.gba.wl_unsafe and not cpu.irq_line
    cpu.gba.wl_unsafe = false
  if volatile:
    # Never skipped (an EEPROM ready poll, a running timer), nor judged
    # again until the program branches elsewhere (judge_loop)
    cpu.entered_waitloop = false
    cpu.wl_bound_addr = 0
    # Only when the read is the loop's own (r15 inside it): the flag covers
    # everything since the last verdict, the code before the loop, an
    # interrupt handler, a DMA reading a timer
    if cpu.gba.bus.volatile_pc - start_addr <= end_addr - start_addr + LEAD:
      cpu.wl_volatile_at = key
      cpu.wl_volatile_rest = WL_VOLATILE_REST
    return
  # A judged iteration always reaches waitloop_skip, which records where it
  # ends whether or not it skips
  cpu.wl_skip_ok = stable and fresh
