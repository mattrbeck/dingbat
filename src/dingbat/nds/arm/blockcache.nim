## Decoded blocks: a block-threaded interpreter for both DS CPUs, included
## by cpu.nim (docs/nds/blockcache.md). Portable: no code is generated, a
## block is an array of dispatch-table entries and their opcodes.
##
## A block is decoded at run time from where an opcode jumped (or a block
## ended): up to BLK_MAX opcodes, through conditional branches and loads and
## stores, to the first unconditional jump, or before the first opcode the
## run loop must see (MSR, SWI, coprocessor, undefined, LDM^ ...). Each
## opcode is one of
##
##   BK_P  pure: registers and flags only (ALU, multiply, MRS, CLZ, Q ops,
##         Thumb BL prefix); no bus access, no jump, no exception, `attn`
##         never set, and a cost the decoder can bound
##   BK_C  as BK_P, but it may jump (branches, ALU or MOV to r15, BX)
##   BK_M  a load or store (it may jump: LDR pc, LDM/POP with pc)
##
## and runs exactly as the run loop would run it -- the same handler on the
## same opcode, the same bus calls in the same order with the same clock --
## while the bookkeeping nothing can see in between is done once:
##
## - Fetch. The first opcode, and the first of each new 32-byte line (ARM9)
##   or 4 KB page (ARM7), is fetched through the bus as exec_one does. When
##   the bus then says the line's sequential fetches are free of effects but
##   the trackers (bus9 `fline9`, bus7 `fpage7`), the opcodes after it in
##   the line are read from the bus's own pointer and only compared with
##   the decoded ones; the trackers are written once, before the next thing
##   that reads them (a data access, a bus fetch, the block's end). A word
##   that differs from the decoded one (self-modifying code, overlays,
##   another program loaded there) ends the block before that opcode, and
##   the run loop fetches and runs it: no invalidation is needed. After a
##   data access the ARM7's next fetch is through the bus again (its data
##   access breaks the sequence, bus7 `break_fetch7`); the ARM9's only when
##   the access turned the line's fast path off.
## - Clock. A pure opcode's cost is the CPU's base cycles, the fixed
##   sequential fetch cost (none on the ARM9) and its internal cycles, which
##   its handler counts in `icycles` as before; they are summed and added to
##   `cycles` (with the bus's `wait`) only before a data access or a bus
##   fetch, which read the clock, and after them. That is exactly the run
##   loop's sum.
## - Slice end. The run loop runs an opcode only while `cycles < until`.
##   After every opcode whose cost the decoder cannot know (a bus fetch, a
##   data access) the clock is exact, and the block goes on only if the
##   pure opcodes up to the next such opcode cannot reach `until` (a bound
##   from the decoder: `ahead_n`, `ahead_ic`); otherwise it ends there and
##   the run loop takes over, opcode by opcode.
## - The opcode count is added when the block ends; cur_pc, r15 and next_pc
##   are written before an opcode that reads them (BF_PC, BK_C, BK_M) and
##   when the block ends. `attn` (I/O, CPSR writes) and an abort end the
##   block after the opcode, as the run loop would look at them next.

const
  BK_P = 0'u8
  BK_C = 1'u8
  BK_M = 2'u8
  BF_PC = 1'u8      ## set cur_pc and r15 before it (it reads them)
  BF_COND = 2'u8    ## an ARM opcode with a condition to test
  BF_REAL = 4'u8    ## fetched through the bus: the block's first opcode or
                    ## the first in a new line (ARM9) or page (ARM7)
  BLK_MAX = (when defined(blkmax1): 1 else: 32)      ## opcodes in a block at most
  BLK_TABLE = 1 shl 14
  BLK_POOL = 1 shl 18
  BLK_EMPTY = 0xFFFF_FFFF'u32
  BLK_IC_MAX = 6        ## internal cycles of a pure opcode at most (ARM7 UMLAL)
  BLK_RETRY = 64'i16    ## lookups before a pc where no block could start is
                        ## decoded again (or a block that changed)

proc blk_class_alu(instr: uint32; kind, flags: var uint8; ic: var int; stop: var bool): bool =
  ## ARM data processing (bits 27-26 = 0, not the miscellaneous space)
  let opc = (instr shr 21) and 0xF
  let rd = (instr shr 12) and 0xF
  let rn = (instr shr 16) and 0xF
  if (instr and (1'u32 shl 25)) == 0:
    if (instr and 0x10) != 0:
      ic = 1
      if ((instr shr 8) and 0xF) == 15: flags = flags or BF_PC
    if (instr and 0xF) == 15: flags = flags or BF_PC
  if rn == 15: flags = flags or BF_PC
  if rd == 15:
    if opc >= 8 and opc <= 11: return false   # TSTP/TEQP/CMPP/CMNP: restore the PSR
    kind = BK_C
    flags = flags or BF_PC
    stop = (instr shr 28) == 0xE
  else:
    kind = BK_P
  true

proc blk_class_arm(instr: uint32; v5: static bool; kind, flags: var uint8; ic: var int;
                   stop: var bool): bool =
  ## What a block may do with ARM opcode `instr` (false: end the block
  ## before it). Mirrors arm_dispatch's decode.
  let cond = instr shr 28
  if cond == 0xF: return false              # BLX imm, PLD, undefined
  kind = BK_P
  flags = if cond != 0xE: BF_COND else: 0'u8
  let rd = (instr shr 12) and 0xF
  let rn = (instr shr 16) and 0xF
  let any15 = rn == 15 or rd == 15 or ((instr shr 8) and 0xF) == 15 or (instr and 0xF) == 15
  case (instr shr 25) and 7
  of 0:
    if (instr and 0x0FFF_FFD0'u32) == 0x012F_FF10'u32:   # BX / BLX reg
      when not v5:
        if (instr and 0x20) != 0: return false
      kind = BK_C
      flags = flags or BF_PC
      stop = cond == 0xE
      return true
    if (instr and 0x90) == 0x90:
      let sh = (instr shr 5) and 3
      if sh == 0:
        if (instr and 0x0100_0000'u32) != 0:          # SWP
          if any15: return false
          kind = BK_M
          return true
        let op = (instr shr 21) and 7
        if op == 2 or op == 3 or any15: return false   # undefined; r15 written
        ic = 6
        return true
      let load = (instr and (1'u32 shl 20)) != 0
      let wb = (instr and (1'u32 shl 24)) == 0 or (instr and (1'u32 shl 21)) != 0
      if wb and rn == 15: return false
      if load:
        if rd == 15: return false
      elif sh >= 2:                               # LDRD / STRD
        when v5:
          if (rd and 1) != 0 or rd >= 14: return false
      kind = BK_M
      flags = flags or BF_PC
      return true
    if (instr and 0x0190_0000'u32) == 0x0100_0000'u32:  # miscellaneous
      if (instr and 0xF0) == 0:
        if (instr and 0x0020_0000'u32) != 0: return false   # MSR
        if rd == 15: return false
        return true                                         # MRS
      when v5:
        # the same tests in the same order as arm_dispatch; r15 written
        # or read is left to the run loop
        if (instr and 0x0FFF_0FF0'u32) == 0x016F_0F10'u32:       # CLZ
          return rd != 15 and (instr and 0xF) != 15
        if (instr and 0x0F90_00F0'u32) == 0x0100_0050'u32:       # QADD ...
          return rd != 15 and rn != 15 and (instr and 0xF) != 15
        if (instr and 0x0FF0_00F0'u32) == 0x0120_0070'u32: return false   # BKPT
        if (instr and 0x0F90_0090'u32) == 0x0100_0080'u32:       # SMLAxy ...
          return not any15
        return false                                        # undefined
      else:
        if (instr and 0x10) != 0: return false
        return true                                         # executes as nothing
    blk_class_alu(instr, kind, flags, ic, stop)
  of 1:
    if (instr and 0x0190_0000'u32) == 0x0100_0000'u32: return false   # MSR imm, undefined
    blk_class_alu(instr, kind, flags, ic, stop)
  of 2, 3:
    if ((instr shr 25) and 7) == 3 and (instr and 0x10) != 0: return false
    let wb = (instr and (1'u32 shl 24)) == 0 or (instr and (1'u32 shl 21)) != 0
    if wb and rn == 15: return false
    kind = BK_M
    flags = flags or BF_PC
    if (instr and (1'u32 shl 20)) != 0 and rd == 15: stop = cond == 0xE   # LDR pc
    true
  of 4:
    if (instr and (1'u32 shl 22)) != 0: return false   # LDM^/STM^: user bank, SPSR
    if rn == 15 or (instr and 0xFFFF) == 0: return false
    kind = BK_M
    flags = flags or BF_PC
    if (instr and (1'u32 shl 20)) != 0 and (instr and 0x8000) != 0: stop = cond == 0xE
    true
  of 5:
    kind = BK_C
    flags = flags or BF_PC
    stop = cond == 0xE
    true
  else: false                                 # LDC/STC, SWI, MCR/MRC, undefined

proc blk_class_thumb(instr: uint32; v5: static bool; kind, flags: var uint8; ic: var int;
                     stop: var bool): bool =
  ## As blk_class_arm, for Thumb (mirrors thumb_dispatch).
  kind = BK_P
  flags = 0
  case instr shr 11
  of 0 .. 7: true
  of 8:
    if (instr and 0x400) == 0:
      let op = (instr shr 6) and 0xF
      if op == 2 or op == 3 or op == 4 or op == 7: ic = 1
      elif op == 0xD: ic = 4
      return true
    flags = BF_PC
    let rd = (instr and 7) or ((instr shr 4) and 8)
    case (instr shr 8) and 3
    of 0, 2:
      if rd == 15:
        kind = BK_C
        stop = true
    of 1: discard
    else:
      when not v5:
        if (instr and 0x80) != 0: return false
      kind = BK_C
      stop = true
    true
  of 9 .. 19:
    kind = BK_M
    flags = BF_PC
    true
  of 20, 21:
    flags = BF_PC
    true
  of 22, 23:
    if (instr and 0x0F00) == 0: return true                 # ADD sp
    if (instr and 0x0600) != 0x0400: return false           # BKPT, undefined
    kind = BK_M                                             # PUSH / POP
    flags = BF_PC
    if (instr and 0x0900) == 0x0900: stop = true            # POP {.., pc}
    true
  of 24, 25:
    if (instr and 0xFF) == 0: return false
    kind = BK_M
    flags = BF_PC
    true
  of 26, 27:
    if ((instr shr 8) and 0xF) >= 0xE: return false         # SWI, undefined
    kind = BK_C
    flags = BF_PC
    true
  of 29:
    when not v5: return false
    else:
      if (instr and 1) != 0: return false
      kind = BK_C
      flags = BF_PC
      stop = true
      true
  of 30:
    flags = BF_PC
    true
  else:                                                     # B, BL suffix
    kind = BK_C
    flags = BF_PC
    stop = true
    true

const
  OC_P = 0'u8       ## pure
  OC_PPC = 1'u8     ## pure, reads cur_pc / r15
  OC_PCOND = 2'u8   ## pure, with an ARM condition
  OC_C = 3'u8       ## may jump
  OC_CCOND = 4'u8
  OC_M = 5'u8       ## data access (may jump)
  OC_MCOND = 6'u8
  OC_END = 7'u8     ## after the last opcode
  OC_LINE = 8'u8    ## the first opcode of the next ARM9 line: step the line,
                    ## then it is `sub`
  BR_LOOP = 0       ## blk_run: the run loop goes on from here
  BR_CHAIN = 1      ## jumped or ran to its end with nothing for the run loop
                    ## to look at: the next block may follow at once
  BR_STALE = 2      ## an opcode had changed since decoding

proc blk_slot(key: uint32): int {.inline.} =
  int(((key shr 1) xor (key shr 15)) and uint32(BLK_TABLE - 1))

proc blk_new[B](): BlockCache[B] {.noinline.} =
  result = BlockCache[B](table: newSeq[BlkEntry](BLK_TABLE), ops: newSeq[BlkOp[B]](BLK_POOL))
  for e in result.table.mitems: e.key = BLK_EMPTY

proc blk_build[B](cpu: ArmCpu[B]; e: ptr BlkEntry; key: uint32) {.noinline.} =
  ## Decode the block at `key` into entry `e` (0 opcodes: none can start there).
  mixin blk_peek, arm_table, thumb_table, armv5, blk_mask, blk_lines
  let bc {.cursor.} = cpu.blk
  if bc.used + BLK_MAX + 1 > bc.ops.len:
    for x in bc.table.mitems: x.key = BLK_EMPTY
    bc.used = 0
    inc bc.stats[5]
  let thumb = (key and 1) != 0
  let size = if thumb: 2'u32 else: 4'u32
  var a = key and not 1'u32
  e.key = key
  e.start = int32(bc.used)
  e.n = 0
  e.retry = BLK_RETRY
  var n = 0
  while n < BLK_MAX:
    let line_start = (a and blk_mask(B)) == 0
    if n > 0 and line_start and not blk_lines(B): break    # ARM7: one page
    var ok = true
    let w = blk_peek(cpu.bus, a, thumb, ok)
    if not ok: break
    var kind, flags: uint8
    var ic = 0
    var stop = false
    let good =
      if thumb: blk_class_thumb(w, armv5(B), kind, flags, ic, stop)
      else: blk_class_arm(w, armv5(B), kind, flags, ic, stop)
    if not good: break
    let cond = (flags and BF_COND) != 0
    let code =
      case kind
      of BK_P: (if cond: OC_PCOND elif (flags and BF_PC) != 0: OC_PPC else: OC_P)
      of BK_C: (if cond: OC_CCOND else: OC_C)
      else: (if cond: OC_MCOND else: OC_M)
    let op = addr bc.ops[bc.used + n]
    op.fn = if thumb: thumb_table(B)[w shr 6]
            else: arm_table(B)[((w shr 16) and 0xFF0) or ((w shr 4) and 0xF)]
    op.instr = w
    op.code = if n > 0 and line_start: OC_LINE else: code
    op.sub = code
    op.ahead_ic = uint8(ic)           # its own, until the pass below
    inc n
    a += size
    if stop: break
  let fin = addr bc.ops[bc.used + n]
  fin.fn = nil
  fin.instr = 0
  fin.code = OC_END
  fin.sub = OC_END
  # ahead_n / ahead_ic: the opcodes after each one up to the next memory
  # one or the end (exclusive): what may run before the clock is exact again
  var run_n = 0
  var run_ic = 0
  for i in countdown(n - 1, 0):
    let op = addr bc.ops[bc.used + i]
    let own = int(op.ahead_ic)
    op.ahead_n = uint8(run_n)
    op.ahead_ic = uint8(run_ic)
    if op.sub == OC_M or op.sub == OC_MCOND:
      run_n = 0
      run_ic = 0
    else:
      inc run_n
      run_ic += own
  e.n = int16(n)
  if n > 0: bc.used += n + 1
  inc bc.stats[4]

proc blk_run[B; T: static bool](cpu: ArmCpu[B]; start: int; until: int64): int {.inline, codegenDecl: "static inline __attribute__((always_inline)) $# $#$#".} =
  ## Run the block whose opcodes start at `ops[start]`, at next_pc, in Thumb
  ## state T: BR_LOOP, BR_CHAIN or BR_STALE.
  mixin fetch16, fetch32, access_cycles, armv5, blk_ptr, blk_mask, blk_fast_ok,
        blk_after_data, blk_seq_cost, blk_bound, blk_commit, blk_next_line, blk_breaks
  const size = when T: 2'u32 else: 4'u32
  const pcoff = size * 2
  const icm = when armv5(B): 1'i64 else: 2'i64
  let ops = cast[ptr UncheckedArray[BlkOp[B]]](addr cpu.blk.ops[start])
  var a = cpu.next_pc
  var i = 0
  var op = addr ops[0]
  var w: uint32
  var fetched = 0'i64       # what the last fetch through the bus cost
  template bus_fetch() =
    ## opcode `i` through the bus, as exec_one (clock and trackers exact
    ## here: the block's first, or the ARM7's after a data access). A
    ## changed opcode, a prefetch abort, or code whose next fetches are not
    ## the fast ones (uncached, a line apart): finished as exec_one, the
    ## block ends.
    cpu.cur_pc = a
    w = when T: fetch16(cpu.bus, a) else: fetch32(cpu.bus, a)
    var bad = w != op.instr
    when armv5(B): bad = bad or cpu.abort != 0
    if unlikely(bad or not blk_fast_ok(cpu.bus, a)):
      cpu.instr_count += uint64(i)
      cpu.exec_fetched(a, w, T)
      cpu.blk_seek = cpu.next_pc - a > 4'u32
      when defined(nds_blkstats):
        if w != op.instr: inc cpu.blk.stats[3]
      return (if w == op.instr: BR_LOOP else: BR_STALE)
    # its cost out of the bus's wait: the opcode's own, added after it, so
    # the wait holds nothing between opcodes (a data access sees the clock
    # at its opcode's start)
    fetched = access_cycles(cpu.bus)
  bus_fetch()
  var p = blk_ptr(cpu.bus)
  let base = cpu.base_cycles
  let seqc = blk_seq_cost(cpu.bus, size)
  let per = base + blk_bound(cpu.bus, size)   # a bound on a pure opcode's cost
  var pend = 0'i64          # cycles of opcodes run, not yet in `cycles`
  var fast = false          # trackers waiting for the fetch at `fa`
  var fa = 0'u32
  var refetch = false       # the next fetch through the bus (ARM7, after data)
  var stop = BLK_MAX + 1    # the first opcode that may start at the slice end
  template flush() =
    ## the clock exact (the bus's wait included)
    let ic = when armv5(B): cpu.icycles else: cpu.icycles * 2
    cpu.icycles = 0
    cpu.cycles += pend + access_cycles(cpu.bus) + ic
    pend = 0
  template commit() =
    if fast:
      blk_commit(cpu.bus, fa, size)
      fast = false
  template leave(k: int; jumped: static bool; res: int) =
    ## opcodes 0 ..< k ran, the last at `a`
    commit()
    flush()
    cpu.instr_count += uint64(k)
    cpu.cur_pc = a
    cpu.r[15] = a + pcoff
    when not jumped: cpu.next_pc = a + size
    return res
  template precheck() =
    ## The clock is exact: the pure opcodes up to the next memory one run
    ## when they cannot reach the slice end; else those that surely start
    ## before it (at most `per` + BLK_IC_MAX internal cycles each) and the
    ## run loop takes over from there.
    let room = until - cpu.cycles
    if room > int64(op.ahead_n) * per + int64(op.ahead_ic) * icm:
      stop = BLK_MAX + 1
    else:
      stop = i + 1 + int((room + per + BLK_IC_MAX * icm - 1) div (per + BLK_IC_MAX * icm))
      if stop <= i + 1:
        cpu.blk_seek = false
        leave(i + 1, false, BR_LOOP)
  template jumped_out(own: int64) =
    pend += base + own
    cpu.blk_seek = true
    if cpu.attn: leave(i + 1, true, BR_LOOP)
    leave(i + 1, true, BR_CHAIN)
  template exec_op(oc: uint8; own: int64) =
    ## opcode `op` (word `w`, at `a`); `own`: its fetch's cost not yet counted
    case oc
    of OC_P:
      op.fn(cpu, w)
      pend += base + own
    of OC_PPC:
      cpu.cur_pc = a
      cpu.r[15] = a + pcoff
      op.fn(cpu, w)
      pend += base + own
    of OC_PCOND:
      cpu.cur_pc = a
      cpu.r[15] = a + pcoff
      if cpu.cond_passed(w shr 28): op.fn(cpu, w)
      pend += base + own
    of OC_C, OC_CCOND:
      cpu.cur_pc = a
      cpu.r[15] = a + pcoff
      cpu.next_pc = a + size
      if oc == OC_C or cpu.cond_passed(w shr 28): op.fn(cpu, w)
      if cpu.next_pc != a + size or cpu.thumb != T or cpu.attn: jumped_out(own)
      pend += base + own
    else:
      # a data access: the clock and trackers exact first (only pure
      # opcodes and bus fetches, whose cost is in `pend`, ran since the last
      # flush: the bus's wait holds nothing)
      commit()
      cpu.cycles += pend + (when armv5(B): cpu.icycles else: cpu.icycles * 2)
      cpu.icycles = 0
      pend = 0
      cpu.cur_pc = a
      cpu.r[15] = a + pcoff
      cpu.next_pc = a + size
      if oc == OC_M or cpu.cond_passed(w shr 28): op.fn(cpu, w)
      when armv5(B):
        if unlikely(cpu.abort != 0):
          cpu.take_abort(a)
          jumped_out(own)
      if cpu.next_pc != a + size or cpu.thumb != T or cpu.attn: jumped_out(own)
      pend += base + own
      flush()
      precheck()
      # the next fetch: the ARM7's after a data access goes through the bus
      # (it broke the sequence: bus7 break_fetch7); the ARM9's is still the
      # fast one unless the access turned the line's fast path off
      when blk_breaks(B): refetch = true
      else:
        if not blk_after_data(cpu.bus, a):
          cpu.blk_seek = false
          leave(i + 1, false, BR_LOOP)
  # the first opcode, fetched above
  exec_op(op.code, fetched)
  if op.code < OC_M:
    flush()
    precheck()
  while true:
    inc i
    a += size
    op = addr ops[i]
    if i >= stop:
      when defined(nds_blkstats): inc cpu.blk.stats[2]
      a -= size
      cpu.blk_seek = false
      leave(i, false, BR_LOOP)
    var code = op.code
    if code >= OC_END:
      if code == OC_END:
        a -= size
        cpu.blk_seek = true
        leave(i, false, BR_CHAIN)
      # into the next line: the fetch there is a fast one too (ARM9)
      if not blk_next_line(cpu.bus, a):
        a -= size
        cpu.blk_seek = false
        leave(i, false, BR_LOOP)
      p = blk_ptr(cpu.bus)
      code = op.sub
    when blk_breaks(B):
      if refetch:
        refetch = false
        bus_fetch()
        p = blk_ptr(cpu.bus)
        exec_op(code, fetched)
        continue
    w = when T: uint32(cast[ptr uint16](addr p[a and blk_mask(B)])[])
        else: cast[ptr uint32](addr p[a and blk_mask(B)])[]
    if unlikely(w != op.instr):
      # changed: the run loop fetches it as usual
      a -= size
      cpu.blk_seek = false
      when defined(nds_blkstats): inc cpu.blk.stats[3]
      leave(i, false, BR_STALE)
    fast = true
    fa = a
    exec_op(code, seqc)

proc blk_try[B](cpu: ArmCpu[B]; until: int64): bool {.noinline.} =
  ## Run the blocks from next_pc while one follows another; false when none
  ## starts there (the run loop runs the opcode).
  if cpu.blk == nil: cpu.blk = blk_new[B]()
  let bc {.cursor.} = cpu.blk
  when defined(nds_blkstats): inc bc.stats[7]
  while true:
    let thumb = cpu.thumb
    let key = cpu.next_pc or (if thumb: 1'u32 else: 0'u32)
    let e = addr bc.table[blk_slot(key)]
    if e.key != key or e.n == 0:
      if e.key == key and e.retry > 0:
        when defined(nds_blkstats): inc bc.stats[6]
        dec e.retry
        cpu.blk_seek = false
        return
      cpu.blk_build(e, key)
      if e.n == 0:
        cpu.blk_seek = false
        return
    result = true
    when defined(nds_blkstats):
      inc bc.stats[1]
      let n0 = cpu.instr_count
    let r = if thumb: blk_run[B, true](cpu, int(e.start), until)
            else: blk_run[B, false](cpu, int(e.start), until)
    when defined(nds_blkstats):
      bc.stats[0] += cpu.instr_count - n0
      if r == BR_LOOP: inc bc.stats[2]
    if r == BR_STALE:
      e.n = 0
      e.retry = BLK_RETRY
      return
    if r != BR_CHAIN or cpu.cycles >= until: return

proc blk_stats*[B](cpu: ArmCpu[B]): array[8, uint64] =
  ## -d:nds_blkstats: opcodes run in blocks, block entries, returns to the
  ## run loop (slice end, attn, ...), changed opcodes, blocks decoded, pool
  ## flushes
  if cpu.blk != nil: cpu.blk.stats else: default(array[8, uint64])
