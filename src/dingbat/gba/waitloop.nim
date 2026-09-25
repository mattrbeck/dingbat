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
  else:
    none(WLParsed)

const WL_NO_LOAD = 0xFFFFFFFF'u32

proc judge_loop(cpu: CPU; start_addr: uint32; end_addr: uint32) =
  # Analyze only when the same conditional-branch target arrives twice in a
  # row (branch_dest; the defer records every call's target).
  defer: cpu.branch_dest = start_addr
  if start_addr != cpu.branch_dest: return
  if not (start_addr < end_addr and
          (end_addr - start_addr) >= 2 and
          (end_addr - start_addr) <= 12):
    return
  # Cache verdicts only for ROM addresses; RAM code can be overwritten.
  let cacheable = cpu.cache_waitloop_results and
                  bits_range(start_addr, 24, 27) in 0x8'u32 .. 0xD'u32
  if cacheable:
    if start_addr == cpu.last_waitloop:
      cpu.entered_waitloop = true
      return
    if start_addr == cpu.last_non_waitloop:
      return
    if start_addr in cpu.identified_waitloops:
      cpu.last_waitloop = start_addr
      cpu.last_waitloop_first_load = cpu.waitloop_first_load.getOrDefault(start_addr, WL_NO_LOAD)
      cpu.entered_waitloop = true
      return
    if start_addr in cpu.identified_non_waitloops:
      cpu.last_non_waitloop = start_addr
      return
  var written_bits: uint16 = 0
  var never_write: uint16  = 0
  var first_load = WL_NO_LOAD
  var cur_addr = start_addr
  while cur_addr < end_addr:
    let instr = uint16(cpu.gba.bus.read_half_internal(cur_addr))
    let kind  = cpu.waitloop_instr_lut[instr shr 8]
    let parsed = parse_wl_instr(kind, instr)
    if parsed.isNone or not parsed.get.read_only:
      if cacheable:
        cpu.identified_non_waitloops.incl(start_addr)
        cpu.last_non_waitloop = start_addr
      return
    let p = parsed.get
    if first_load == WL_NO_LOAD and
       kind in {wlMultipleLoadStore, wlLoadStoreHalfword, wlLoadStoreImmediateOffset}:
      first_load = cur_addr
    never_write = never_write or (p.read_bits and not written_bits)
    # Fold in this instruction's writes before checking, so a read-modify-
    # write of one register (subs r2, #1) counts as loop-carried.
    written_bits = written_bits or p.write_bits
    if (written_bits and never_write) > 0:
      if cacheable:
        cpu.identified_non_waitloops.incl(start_addr)
        cpu.last_non_waitloop = start_addr
      return
    if (p.write_bits and (1'u16 shl 15)) > 0:
      if cacheable:
        cpu.identified_non_waitloops.incl(start_addr)
        cpu.last_non_waitloop = start_addr
      return
    cur_addr += 2
  if cacheable:
    cpu.identified_waitloops.incl(start_addr)
    cpu.waitloop_first_load[start_addr] = first_load
    cpu.last_waitloop = start_addr
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
proc analyze_loop*(cpu: CPU; start_addr: uint32; end_addr: uint32) =
  if not cpu.attempt_waitloop_detection: return
  cpu.judge_loop(start_addr, end_addr)
  if not cpu.entered_waitloop: return
  # Consecutive verdicts on one loop are consecutive iterations: the period,
  # the dispatches and the volatile reads below are all since the last one.
  let t = int64(cpu.gba.bus.sched.cycles) + int64(cpu.gba.bus.cycles)  # bus_now
  let same = start_addr == cpu.wl_addr
  let period = if same: t - cpu.wl_time else: -1'i64
  let stable = same and period > 0 and period == cpu.wl_period
  cpu.wl_addr = start_addr
  cpu.wl_time = t
  cpu.wl_period = period
  let dispatched = cpu.gba.dispatch_count != cpu.wl_dispatch_mark
  cpu.wl_dispatch_mark = cpu.gba.dispatch_count
  let volatile = cpu.gba.bus.volatile_read
  cpu.gba.bus.volatile_read = false
  var fresh = true
  if dispatched:
    # r15 reads instruction + 4 while an instruction runs (a catch-up at its
    # read) and next instruction + 4 at the tick that ends it, so events
    # that ran at PCs start+4 .. first_load+4 all preceded the first read
    let last = if cpu.last_waitloop_first_load == WL_NO_LOAD: end_addr
               else: cpu.last_waitloop_first_load
    let pc = cpu.gba.last_dispatch_pc
    fresh = pc >= start_addr + 4 and pc <= last + 4
    when WL_QUIET_EVENTS:
      # One that ran after the read is harmless if it could not have changed
      # what was read: FireRed's WaitForVBlank (an IWRAM flag) otherwise ran
      # an extra iteration for real after each line event, or not, by where
      # in the loop the line happened to fall.
      if not fresh and not cpu.gba.wl_unsafe and not cpu.irq_line:
        fresh = true
  when WL_QUIET_EVENTS: cpu.gba.wl_unsafe = false
  if not (stable and fresh and not volatile):
    cpu.entered_waitloop = false
