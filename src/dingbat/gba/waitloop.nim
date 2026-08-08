# Waitloop detection (included by gba.nim)
#
# A waitloop is a short backward Thumb loop that cannot change its own state:
# every instruction is read-only (no stores, no PC writes, no calls) and no
# register read inside the loop was written earlier in it — a loop-carried
# counter like `subs r2, #1` disqualifies, since such loops terminate by
# themselves and must run at real speed. analyze_loop runs from
# thumb_conditional_branch on every conditional branch (only Thumb is hooked;
# ARM idle loops have only been observed in flash-save polling), gated by the
# branch_dest handshake below so a body is inspected only once its target
# repeats. A positive verdict sets cpu.entered_waitloop, which cpu.tick
# consumes at the end of the instruction: instead of scheduler.tick it calls
# fast_forward_bounded — bound = the APU channels' soonest deadline; that
# contract is documented at common/scheduler.nim's fast_forward_bounded — so
# each loop iteration skips ahead one event's worth of idle time.
# docs/research_waitloop_tracer.md surveys what this static scheme can and
# cannot catch.

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
    # ldr rd, [pc, #imm] loads a literal-pool constant, which is loop-invariant
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

proc analyze_loop*(cpu: CPU; start_addr: uint32; end_addr: uint32) =
  # Two-sighting gate: branch_dest holds the target of the previous
  # conditional branch executed (the defer records this one's target
  # unconditionally, early returns included), so analysis proceeds only when
  # the same target arrives twice in a row — the signature of a loop
  # actually spinning. One-off branches cost a single compare, and a body
  # containing a second conditional branch (alternating targets) is never
  # analyzed at all.
  defer: cpu.branch_dest = start_addr
  if not cpu.attempt_waitloop_detection: return
  if start_addr != cpu.branch_dest: return
  if not (start_addr < end_addr and
          (end_addr - start_addr) >= 2 and
          (end_addr - start_addr) <= 12):
    return
  # Only cache classifications for ROM addresses: RAM-resident code can be
  # overwritten (overlays, copied drivers), so re-analyze it every time and a
  # stale verdict is impossible. The analysis is only a few halfword reads.
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
      cpu.entered_waitloop = true
      return
    if start_addr in cpu.identified_non_waitloops:
      cpu.last_non_waitloop = start_addr
      return
  var written_bits: uint16 = 0
  var never_write: uint16  = 0
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
    never_write = never_write or (p.read_bits and not written_bits)
    # Fold in this instruction's writes before checking: an instruction that
    # reads and writes the same register (e.g. subs r2, #1) is a loop-carried
    # dependency — the loop terminates by itself and must not be treated as a
    # waitloop, or countdown delay loops get fast-forwarded
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
    cpu.last_waitloop = start_addr
  cpu.entered_waitloop = true
