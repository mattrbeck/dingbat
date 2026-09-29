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
    let ro = bits_range(instr, 6, 8)
    let rb = bits_range(instr, 3, 5)
    let rd = bits_range(instr, 0, 2)
    if load:
      some(WLParsed(read_only: true, read_bits: (1'u16 shl ro) or (1'u16 shl rb),
                    write_bits: 1'u16 shl rd))
    else:
      some(WLParsed(read_only: false,
                    read_bits: (1'u16 shl ro) or (1'u16 shl rb) or (1'u16 shl rd),
                    write_bits: 0'u16))
  of wlSpRelativeLoadStore:
    let rd = bits_range(instr, 8, 10)
    if bit(instr, 11):
      some(WLParsed(read_only: true, read_bits: 1'u16 shl 13, write_bits: 1'u16 shl rd))
    else:
      some(WLParsed(read_only: false, read_bits: (1'u16 shl 13) or (1'u16 shl rd),
                    write_bits: 0'u16))
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

template kind_bit(k: EventType): uint64 = 1'u64 shl ord(k)
# Events that change neither memory, a cartridge's storage or clock, nor a
# CPU register: all a loop that reads no IO could ever see of them is a DMA
# they start, counted apart (GBA.dma_bursts)
const WL_MEMORY_QUIET_KINDS =
  kind_bit(etAPUSample) or kind_bit(etAPUFrameSeq) or kind_bit(etPPUStartLine) or
  kind_bit(etPPUStartHBlank) or kind_bit(etPPUSetHBlankFlag) or
  kind_bit(etPPUEndHBlank) or kind_bit(etTimer0) or kind_bit(etTimer1) or
  kind_bit(etTimer2) or kind_bit(etTimer3) or kind_bit(etInterrupts) or
  kind_bit(etIrqWindowOpen) or kind_bit(etIrqWindowClose) or
  kind_bit(etFifoWindow) or kind_bit(etHDMARequest) or kind_bit(etVDMARequest) or
  kind_bit(etFifoARequest) or kind_bit(etFifoBRequest) or kind_bit(etDMA)

const
  WL_ACCEPT = 0   # a waitloop by the scan
  WL_DYN = 1      # not by the scan, but it might be by what it does (dyn_loop)
  WL_NEVER = 2    # carries a register from one iteration to the next: never

proc scan_thumb_loop(cpu: CPU; start_addr, end_addr: uint32; first_load: var uint32): int =
  ## Whether the Thumb body [start_addr, end_addr) reads only and carries no
  ## register from one iteration into the next (WL_ACCEPT); if not, whether
  ## the reason rules the loop out for good (a carried register, WL_NEVER) or
  ## only defeats the scan (a store, a call, a branch inside, WL_DYN).
  var written_bits: uint16 = 0
  var never_write: uint16  = 0
  var flags_set = false
  var stores = false   # stores something: WL_DYN at best
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
        return WL_DYN
      cur_addr += 2
      continue
    if kind in {wlMoveShiftedRegister, wlAddSubtract, wlMoveCompareAddSubtract,
                wlAluOperations} or
       (kind == wlHighRegBranchExchange and bits_range(instr, 8, 9) == 1):
      flags_set = true
    let parsed = parse_wl_instr(kind, instr)
    # Something the scan cannot follow (a call, bx, push/pop): what it does
    # to the registers after here is unknown
    if parsed.isNone: return WL_DYN
    let p = parsed.get
    if not p.read_only: stores = true
    if first_load == WL_NO_LOAD and
       kind in {wlMultipleLoadStore, wlLoadStoreHalfword, wlLoadStoreImmediateOffset,
                wlLoadStoreRegisterOffset, wlLoadStoreSignExtended}:
      first_load = cur_addr
    never_write = never_write or (p.read_bits and not written_bits)
    # Fold in this instruction's writes before checking, so a read-modify-
    # write of one register (subs r2, #1) counts as loop-carried.
    written_bits = written_bits or p.write_bits
    if (written_bits and never_write) > 0: return WL_NEVER
    if (p.write_bits and (1'u16 shl 15)) > 0: return WL_NEVER
    cur_addr += 2
  if stores: WL_DYN else: WL_ACCEPT

proc scan_arm_loop(cpu: CPU; start_addr, end_addr: uint32; first_load: var uint32): int =
  ## The ARM counterpart: every instruction unconditional, and either data
  ## processing (no multiply, swap or PSR transfer, not writing r15) or a
  ## load with no writeback (Digimon Battle Spirit's `ldrb r9, [r8]; cmp
  ## r9, #0; beq`). r15 as an operand is the instruction's address + 8.
  var written_bits: uint16 = 0
  var never_write: uint16  = 0
  var flags_set = false
  var stores = false
  var cur_addr = start_addr
  while cur_addr < end_addr:
    let i = cpu.gba.bus.read_word_internal(cur_addr)
    if (i and 0x0F000000'u32) == 0x0A000000'u32 and (i shr 28) < 0xE'u32:
      # B<cond> out of the loop, on flags this iteration set (as in Thumb)
      let target = uint32(int(cur_addr) + 8 + (cast[int32](bits_range(i, 0, 23) shl 8) shr 6))
      if not flags_set or (target >= start_addr and target <= end_addr): return WL_DYN
      cur_addr += 4
      continue
    if (i shr 28) != 0xE'u32: return WL_DYN
    let rd = bits_range(i, 12, 15)
    let rn = bits_range(i, 16, 19)
    var reads, writes: uint16
    template reg_bit(r: uint32): uint16 = (if r == 15: 0'u16 else: 1'u16 shl r)
    if (i and 0x0C000000'u32) == 0'u32:
      if (i and 0x0FC000F0'u32) == 0x00000090'u32:
        # MUL / MLA (rd is bits 16-19 here)
        let mrd = bits_range(i, 16, 19)
        if mrd == 15: return WL_DYN
        reads = reg_bit(bits_range(i, 0, 3)) or reg_bit(bits_range(i, 8, 11))
        if bit(i, 21): reads = reads or reg_bit(bits_range(i, 12, 15))
        writes = 1'u16 shl mrd
        if bit(i, 20): flags_set = true
      elif (i and 0x0E000090'u32) == 0x00000090'u32:
        # Halfword and signed transfers (long multiplies and swaps: DYN)
        if (i and 0x60'u32) == 0: return WL_DYN
        let load = bit(i, 20)
        if rd == 15 and load: return WL_DYN
        reads = reg_bit(rn)
        if not bit(i, 22): reads = reads or reg_bit(bits_range(i, 0, 3))
        if load: writes = 1'u16 shl rd
        else:
          reads = reads or reg_bit(rd)
          stores = true
        if not bit(i, 24) or bit(i, 21):
          if rn == 15: return WL_DYN
          writes = writes or (1'u16 shl rn)
        if load and first_load == WL_NO_LOAD: first_load = cur_addr
      else:
        let op = bits_range(i, 21, 24)
        let s = bit(i, 20)
        let test = op >= 8 and op <= 11
        if test and not s: return WL_DYN        # MRS / MSR / BX
        if rd == 15 and not test: return WL_DYN
        if op in [5'u32, 6, 7] and not flags_set: return WL_DYN   # ADC SBC RSC
        if not (op == 13 or op == 15): reads = reg_bit(rn)
        if not bit(i, 25):
          let rm = bits_range(i, 0, 3)
          if bit(i, 4):
            if bit(i, 7) or rm == 15: return WL_DYN
            reads = reads or reg_bit(rm) or reg_bit(bits_range(i, 8, 11))
          else:
            reads = reads or reg_bit(rm)
            # RRX reads the carry
            if bits_range(i, 5, 6) == 3 and bits_range(i, 7, 11) == 0 and
               not flags_set: return WL_DYN
        if not test: writes = 1'u16 shl rd
        if s: flags_set = true
    elif (i and 0x0C000000'u32) == 0x04000000'u32:
      # LDR / LDRB / STR / STRB
      let load = bit(i, 20)
      if rd == 15 and load: return WL_DYN
      reads = reg_bit(rn)
      if bit(i, 25):
        if bit(i, 4): return WL_DYN
        reads = reads or reg_bit(bits_range(i, 0, 3))
      if load: writes = 1'u16 shl rd
      else:
        reads = reads or reg_bit(rd)
        stores = true
      if not bit(i, 24) or bit(i, 21):
        if rn == 15: return WL_DYN
        writes = writes or (1'u16 shl rn)
      if load and first_load == WL_NO_LOAD: first_load = cur_addr
    elif (i and 0x0E000000'u32) == 0x08000000'u32:
      # LDM / STM
      let list = uint16(i and 0xFFFF'u32)
      if bit(i, 22) or rn == 15: return WL_DYN
      reads = reg_bit(rn)
      if bit(i, 20):
        if (list and 0x8000'u16) != 0: return WL_DYN
        writes = list
      else:
        reads = reads or (list and 0x7FFF'u16)
        stores = true
      if bit(i, 21): writes = writes or (1'u16 shl rn)
    else:
      return WL_DYN
    never_write = never_write or (reads and not written_bits)
    written_bits = written_bits or writes
    if (written_bits and never_write) > 0: return WL_NEVER
    cur_addr += 4
  if stores: WL_DYN else: WL_ACCEPT

proc wl_key(start_addr, end_addr: uint32; arm: static bool): uint32 {.inline.} =
  ## A loop's identity in the verdict caches: its start, bit 0 for ARM, and
  ## its length in bits 28-31 (addresses there are open bus, never judged).
  ## Two loops can share a start: Rockman Zero 4's inner `bcc` and outer
  ## `bne` both go back to 0x08000906, and only the inner is a waitloop.
  ## Code 15 stands for any loop longer than the scan accepts (WL_BODY_MAX,
  ## WL_ARM_BODY_MAX): only ever WL_DYN or WL_NEVER, never a waitloop by scan.
  when arm:
    let n = (end_addr - start_addr) shr 2
    start_addr or 1 or ((if n > 8: 15'u32 else: n) shl 28)
  else:
    let n = (end_addr - start_addr - 2) shr 1
    start_addr or ((if n > 14: 15'u32 else: n) shl 28)

proc note_never(cpu: CPU; key: uint32) {.inline.} =
  ## The branch sites skip analyze_loop for the last four loops judged never
  ## (loop_worth): a work loop's every iteration then costs a compare
  if key != cpu.never_keys[0] and key != cpu.never_keys[1] and
     key != cpu.never_keys[2] and key != cpu.never_keys[3]:
    cpu.never_keys[3] = cpu.never_keys[2]
    cpu.never_keys[2] = cpu.never_keys[1]
    cpu.never_keys[1] = cpu.never_keys[0]
    cpu.never_keys[0] = key

proc loop_worth*(cpu: CPU; start_addr, end_addr: uint32; arm: static bool): bool {.inline.} =
  ## Whether a taken backward branch is worth analyze_loop's time
  let key = wl_key(start_addr, end_addr, arm)
  key != cpu.never_keys[0] and key != cpu.never_keys[1] and
    key != cpu.never_keys[2] and key != cpu.never_keys[3]

proc ram_body_ptr(cpu: CPU; start_addr, end_addr: uint32): ptr uint8 =
  ## The work-RAM bytes of [start_addr, end_addr) in one piece, or nil
  let bus = cpu.gba.bus
  let n = end_addr - start_addr
  case start_addr shr 24
  of 2:
    let o = start_addr and bus.ew_mask
    if o + n - 1 <= bus.ew_mask: addr bus.ew_ptr[o] else: nil
  of 3:
    let o = start_addr and 0x7FFF'u32
    if o + n <= 0x8000'u32: addr bus.wram_chip[o] else: nil
  else: nil

proc ram_body_same(cpu: CPU; slot: int; start_addr, end_addr: uint32): bool =
  ## Whether RAM code judged a waitloop is still byte for byte what was
  ## judged (the verdict's key fixes its length: at most WL_BODY_MAX)
  let n = int(end_addr - start_addr)
  let p = cpu.ram_body_ptr(start_addr, end_addr)
  if p != nil: return equalMem(p, addr cpu.wlt.verdict_body[slot][0], n)
  for i in 0 ..< n:
    if cpu.gba.bus.read_byte_internal(start_addr + uint32(i)) != cpu.wlt.verdict_body[slot][i]:
      return false
  true

proc judge_loop[arm: static bool](cpu: CPU; start_addr: uint32; end_addr: uint32) =
  # Analyze only when the same backward-branch target arrives twice in a row
  # (branch_dest; the defer records every call's target). ARM loops are
  # keyed with bit 0 set (their addresses are word-aligned), so the caches
  # never mistake one for Thumb code at the same address.
  let key = wl_key(start_addr, end_addr, arm)
  if key != cpu.branch_dest:
    # A loop that calls a function comes back after the callee's own branch:
    # the last two distinct targets both count as "again"
    let again = key == cpu.branch_dest2
    cpu.branch_dest2 = cpu.branch_dest
    cpu.branch_dest = key
    if not again:
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
  if not (start_addr < end_addr and (end_addr - start_addr) <= DYN_BODY_MAX): return
  let scan_len = when arm: WL_ARM_BODY_MAX else: WL_BODY_MAX
  # Cache a waitloop verdict only for ROM addresses: RAM code can be
  # overwritten. A rejection is cached anywhere -- it can only ever cost a
  # skip, never make one -- or a hot RAM loop (an IWRAM mixer's ARM code)
  # would be scanned again on every iteration.
  let cacheable = cpu.cache_waitloop_results and
                  bits_range(start_addr, 24, 27) in 0x8'u32 .. 0xD'u32
  if cacheable and key == cpu.last_waitloop:
    # The loop running now, most likely: before any lookup
    cpu.entered_waitloop = true
    return
  let vslot = int((key xor (key shr 13)) and (WL_VERDICT_SLOTS - 1))
  if cpu.cache_waitloop_results:
    if key == cpu.last_non_waitloop:
      cpu.note_never(key)
      return
    if key == cpu.last_dyn_loop:
      cpu.wl_dyn = true
      return
    # Direct-mapped memory of the sets below (0 empty): loops that take
    # turns miss the one-entry caches, and a hash lookup each time showed.
    # It also holds waitloop verdicts on RAM code, with the body's bytes:
    # honoured only while the code is still exactly what was judged.
    if cpu.wlt.verdict_key[vslot] == key:
      if cpu.wlt.verdict[vslot] == WL_ACCEPT:
        # (RAM code under MEMCNT's swap is not judged at all: below)
        if (cpu.gba.bus.sync_bits and SB_SWAP) == 0 and
           cpu.ram_body_same(vslot, start_addr, end_addr):
          cpu.last_waitloop_first_load = cpu.wlt.verdict_load[vslot]
          cpu.entered_waitloop = true
          return
      elif cpu.wlt.verdict[vslot] == WL_NEVER:
        cpu.last_non_waitloop = key
        cpu.note_never(key)
      else:
        cpu.last_dyn_loop = key
        cpu.wl_dyn = true
      return
    if key in cpu.identified_non_waitloops:
      cpu.last_non_waitloop = key
      cpu.note_never(key)
      cpu.wlt.verdict_key[vslot] = key
      cpu.wlt.verdict[vslot] = WL_NEVER
      return
    if key in cpu.identified_dyn_loops:
      cpu.last_dyn_loop = key
      cpu.wl_dyn = true
      cpu.wlt.verdict_key[vslot] = key
      cpu.wlt.verdict[vslot] = WL_DYN
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
  var verdict = when arm: cpu.scan_arm_loop(start_addr, end_addr, first_load)
                else: cpu.scan_thumb_loop(start_addr, end_addr, first_load)
  if verdict == WL_ACCEPT and
     ((end_addr - start_addr) > uint32(scan_len) or
      (not arm and end_addr - start_addr < 2)):
    verdict = WL_DYN
  if verdict == WL_NEVER:
    if cpu.cache_waitloop_results:
      cpu.identified_non_waitloops.incl(key)
      cpu.last_non_waitloop = key
      cpu.note_never(key)
      cpu.wlt.verdict_key[vslot] = key
      cpu.wlt.verdict[vslot] = WL_NEVER
    return
  if verdict == WL_DYN:
    if cpu.cache_waitloop_results:
      cpu.identified_dyn_loops.incl(key)
      cpu.last_dyn_loop = key
      cpu.wlt.verdict_key[vslot] = key
      cpu.wlt.verdict[vslot] = WL_DYN
    cpu.wl_dyn = true
    return
  if cacheable:
    cpu.identified_waitloops.incl(key)
    cpu.waitloop_first_load[key] = first_load
    cpu.last_waitloop = key
  elif cpu.cache_waitloop_results:
    cpu.wlt.verdict_key[vslot] = key
    cpu.wlt.verdict[vslot] = WL_ACCEPT
    cpu.wlt.verdict_load[vslot] = first_load
    for i in 0'u32 ..< (end_addr - start_addr):
      cpu.wlt.verdict_body[vslot][i] = cpu.gba.bus.read_byte_internal(start_addr + i)
    # (read the same way ram_body_same compares: the bytes as stored)
  cpu.last_waitloop_first_load = first_load
  cpu.entered_waitloop = true

# The dynamic check. A loop the scan above cannot follow -- it calls a
# function, closes with an unconditional branch, runs longer than the scan
# looks, stores the values already there -- is judged by what it did: an
# iteration that began with every register (and CPSR) the previous one began
# with, changed no memory, took no SWI or interrupt, saw no DMA, read nothing
# volatile, and read no IO an event since could have changed, is that
# iteration again. waitloop_skip then asks the same of it that it asks of any
# loop (the prefetcher's state and the period repeated) before skipping.
# Only one loop is armed at a time; one that fails rests DYN_REST arrivals
# in a direct-mapped table, so a work loop costs a snapshot every 64 times
# round, not every time.
const PPU_STATUS_CHANGERS = (1'u64 shl ord(etPPUSetHBlankFlag)) or
                            (1'u64 shl ord(etPPUEndHBlank))

proc dyn_arm(cpu: CPU; key: uint32; t: int64) =
  let g = cpu.gba
  let bus = g.bus
  cpu.dyn_key = key
  cpu.dyn_time = t
  bus.dyn_deadline = t + DYN_FIRST
  for i in 0 .. 14: cpu.dyn_regs[i] = cpu.r[i]
  cpu.dyn_regs[15] = uint32(cpu.cpsr)
  cpu.dyn_mark_changes = bus.dyn_changes
  cpu.dyn_mark_swi = cpu.swi_count
  cpu.dyn_mark_irq = cpu.irq_count
  cpu.dyn_mark_dma = g.dma_bursts
  cpu.dyn_mark_dispatch = g.dispatch_count
  bus.dyn_io = 0
  bus.dyn_vol = false
  bus.dyn_cont = false
  g.dyn_kinds = 0
  bus.track_changes = true

proc dyn_loop*(cpu: CPU; start_addr, end_addr: uint32; arm: bool) =
  if not cpu.attempt_waitloop_detection or start_addr >= end_addr or
     end_addr - start_addr > DYN_BODY_MAX:
    return
  if start_addr >= 0x10000000'u32 or
     (start_addr >= 0x08000000'u32 and
      (start_addr and 0x01FFFFFF'u32) >= cpu.gba.bus.rom_len):
    return
  let key = start_addr or 1'u32 or (if arm: 0xF0000000'u32 else: 0xE0000000'u32)
  let slot = int((key xor (key shr 11)) and (DYN_REST_SLOTS - 1))
  if cpu.wlt.rest_key[slot] == key and cpu.wlt.rest[slot] > 0:
    dec cpu.wlt.rest[slot]
    return
  let g = cpu.gba
  let bus = g.bus
  let t = int64(bus.sched.cycles) + int64(bus.cycles)
  let live = cpu.dyn_key != 0 and t >= cpu.dyn_time and t <= bus.dyn_deadline
  if cpu.dyn_key != key:
    # Another loop armed and still coming round: leave it
    if live: return
    cpu.dyn_arm(key, t)
    # Let waitloop_skip record where this iteration ends
    cpu.wl_addr = key
    cpu.wl_time = t
    cpu.wl_period = -1
    cpu.wl_skip_ok = false
    cpu.entered_waitloop = true
    return
  var same = live and
             bus.dyn_changes == cpu.dyn_mark_changes and
             cpu.swi_count == cpu.dyn_mark_swi and
             cpu.irq_count == cpu.dyn_mark_irq and
             g.dma_bursts == cpu.dyn_mark_dma and not bus.dyn_vol and
             uint32(cpu.cpsr) == cpu.dyn_regs[15]
  if same:
    for i in 0 .. 14:
      if cpu.r[i] != cpu.dyn_regs[i]:
        same = false
        break
  let io = bus.dyn_io
  if same and (io and IO_OTHER) != 0 and g.dispatch_count != cpu.dyn_mark_dispatch:
    same = false
  if same and (io and IO_PPU_STATUS) != 0 and (g.dyn_kinds and PPU_STATUS_CHANGERS) != 0:
    same = false
  if same and (g.dyn_kinds and not WL_MEMORY_QUIET_KINDS) != 0:
    same = false
  if not same:
    cpu.wlt.rest_key[slot] = key
    cpu.wlt.rest[slot] = DYN_REST
    cpu.dyn_key = 0
    bus.track_changes = false
    return
  # This iteration was the last one again
  let period = t - cpu.dyn_time
  cpu.wl_addr = key
  cpu.wl_time = t
  cpu.wl_period = period
  cpu.wl_dispatch_mark = g.dispatch_count
  cpu.wl_reads_io = io
  cpu.wl_contended = bus.dyn_cont
  cpu.wl_quiet = io == 0 and not cpu.irq_line
  when WL_QUIET_EVENTS: g.wl_unsafe = false
  # An interrupt recognised during the branch is taken at the next
  # instruction, not iterations later: Franklin the Turtle (E) [f_4] took an
  # H-blank interrupt 180 cycles late, three periods of its ARM loop.
  cpu.wl_skip_ok = not cpu.irq_line
  cpu.entered_waitloop = true
  cpu.dyn_arm(key, t)
  # Back within twice the period, or it has left the loop
  bus.dyn_deadline = t + 2 * period + 64

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
  cpu.wl_dyn = false
  cpu.judge_loop[:arm](start_addr, end_addr)
  if not cpu.entered_waitloop:
    if cpu.wl_dyn: cpu.dyn_loop(start_addr, end_addr, arm)
    return
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
  let no_dma = cpu.gba.dma_bursts == cpu.wl_verdict_dma and
               (cpu.gba.verdict_kinds and not WL_MEMORY_QUIET_KINDS) == 0
  cpu.wl_verdict_dma = cpu.gba.dma_bursts
  cpu.gba.verdict_kinds = 0
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
    # Nor can any event have changed what a loop that read no IO read, bar
    # a DMA: the PPU, the timers and the interrupt controller write no
    # memory. Tekken Advance's loop lost a verdict to the IF bit and the
    # interrupt window of an H-blank interrupt IE never lets through, every
    # line.
    if not fresh and cpu.wl_reads_io == 0 and no_dma and not cpu.irq_line:
      fresh = true
  when WL_QUIET_EVENTS:
    # For events the branch's own refill dispatches after this (waitloop_skip)
    cpu.wl_quiet = (not cpu.gba.wl_unsafe or cpu.wl_reads_io == 0) and not cpu.irq_line
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
