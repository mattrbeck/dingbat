## Translated blocks: the prototype of a block translator (docs/nds/jit.md).
## Included by cpu.nim (it uses the decoder's private procs). Nothing here is
## compiled unless `-d:nds_jit` or `-d:nds_jitprof` is given.
##
## A block is a run of guest opcodes at fixed addresses, translated ahead of
## time from a profile (tools/jitgen.py writes `jit_gen.nim`). Each opcode
## in it is exactly what the run loop's `exec_one` does for it, with the
## opcode a constant instead of a table call:
##
## - the fetch is the bus's own (`fetch32`/`fetch16`): every timing, tag,
##   protection and loop-head effect stays, and the fetched word is compared
##   with the one the block was translated from: code that changed since
##   runs through the table as before (self-modifying code, overlays);
## - the opcode runs as `arm_dispatch(K)` / `thumb_dispatch(K)` with K a
##   literal, so the C compiler folds the condition, the decode and the
##   register numbers -- the same code the table entry would run, minus the
##   index, the indirect call and the operand extraction;
## - the clock and opcode count move after each opcode as in `exec_one`.
##
## The block returns to the run loop after an opcode that was not the one
## translated, and wherever the loop would do something other than run the
## next opcode: the opcode jumped (next_pc is not the
## next address), `attn` is set (an I/O access, a CPSR or CP15 write, a
## SWI: the loop checks halt, the IRQ line and the slice end), or the clock
## reached `until`. So a block runs exactly the opcodes the loop would, in
## the same order, with the same effects: output cannot change.

when defined(nds_jitprof):
  import std/tables
  type JitProfEntry* = object
    count*: int64      ## times executed
    entries*: int64    ## times reached other than from the opcode before
  var jit_prof9*, jit_prof7*: Table[uint64, JitProfEntry]
  var jit_prof_last9, jit_prof_last7: uint32

  proc jit_prof_note[B](cpu: ArmCpu[B]; a, instr: uint32) {.inline.} =
    mixin armv5
    let t = if cpu.thumb: 1'u32 else: 0'u32
    let size = if t == 1: 2'u32 else: 4'u32
    let key = (uint64(instr) shl 32) or uint64(a or t)
    template note(tab, last: untyped) =
      let e = addr tab.mgetOrPut(key, JitProfEntry())
      inc e.count
      if a != last + size: inc e.entries
      last = a
    when armv5(B): note(jit_prof9, jit_prof_last9)
    else: note(jit_prof7, jit_prof_last7)

  proc jit_prof_dump*(path: string) =
    var f = open(path, fmWrite)
    for cpu in 0..1:
      let tab = if cpu == 0: jit_prof9 else: jit_prof7
      for k, e in tab:
        f.writeLine($(if cpu == 0: 9 else: 7) & " " & toHex(uint32(k and 0xFFFF_FFFF'u64), 8) & " " &
                    toHex(uint32(k shr 32), 8) & " " & $e.count & " " & $e.entries)
    f.close()

when defined(nds_jit):
  type
    JitFn*[B] = proc (cpu: ArmCpu[B]; until: int64) {.nimcall.}
    JitEntry*[B] = object
      key*: uint32         ## pc, bit 0 = Thumb; 0xFFFFFFFF = empty
      fn*: JitFn[B]

  const JIT_BITS* = 16
  const JIT_MASK* = (1'u32 shl JIT_BITS) - 1

  var jit_in_block9*, jit_in_block7*: uint64   ## opcodes run inside blocks (statistics)
  var jit_entries9*, jit_entries7*: uint64     ## block entries
  var jit_mismatch*: uint64                    ## opcodes that differed from the translation
  var jit_depth*: int   ## blocks called from blocks (--chain), bounded by JIT_CHAIN
  const JIT_CHAIN* = 64

  proc jit_key*(pc: uint32; thumb: bool): uint32 {.inline.} =
    pc or (if thumb: 1'u32 else: 0'u32)

  proc jit_slot*(key: uint32): int {.inline.} =
    int(((key shr 1) xor (key shr 17)) and JIT_MASK)

  proc jit_fill*[B](tab: var seq[JitEntry[B]]; blocks: openArray[(uint32, JitFn[B])]): int =
    ## The lookup table: direct mapped, a block whose slot is taken is left
    ## out (its opcodes then run through the interpreter). Returns how many.
    tab = newSeq[JitEntry[B]](1 shl JIT_BITS)
    for e in tab.mitems: e.key = 0xFFFF_FFFF'u32
    for (k, fn) in blocks:
      let s = jit_slot(k)
      if tab[s].key == 0xFFFF_FFFF'u32:
        tab[s] = JitEntry[B](key: k, fn: fn)
      else: inc result

  proc exec_arm_const[B](cpu: ArmCpu[B]; k: uint32) {.inline, codegenDecl: "static inline __attribute__((always_inline)) $# $#$#".} =
    ## execute_arm with the opcode known: the table entry's own code.
    mixin armv5
    let cond = k shr 28
    if cond != 0xE and not cpu.cond_passed(cond):
      if cond == 0xF:
        when armv5(B):
          if (k and 0x0E00_0000'u32) == 0x0A00_0000'u32: cpu.arm_blx_imm(k)
          elif (k and 0x0D70_F000'u32) == 0x0550_F000'u32: discard
          else: cpu.undefined_instr()
        else:
          cpu.undefined_instr()
      return
    cpu.arm_dispatch(k)

  proc jit_arm[B](cpu: ArmCpu[B]; until: int64; a, k: uint32; tc = false): bool {.inline, codegenDecl: "static inline __attribute__((always_inline)) $# $#$#".} =
    ## One ARM opcode at `a`, translated from `k`: exec_one's ARM path.
    ## True when the run loop would go straight on to the next opcode.
    ## `tc`: the opcode may switch to Thumb without jumping (a BX or a load
    ## to r15 whose target is the next word), so the state is checked too.
    mixin jit_fetch32, access_cycles, armv5
    cpu.cur_pc = a
    let instr = jit_fetch32(cpu.bus, a)
    cpu.next_pc = a + 4
    cpu.r[15] = a + 8
    let same = instr == k
    if (when armv5(B): likely(cpu.abort == 0) else: true):
      if likely(same): cpu.exec_arm_const(k)
      else:
        when defined(nds_jitstats): inc jit_mismatch
        cpu.execute_arm(instr)
    when armv5(B):
      if unlikely(cpu.abort != 0): cpu.take_abort(a)
    inc cpu.instr_count
    when defined(nds_jitstats):
      when armv5(B): inc jit_in_block9
      else: inc jit_in_block7
    let ic = when armv5(B): cpu.icycles else: cpu.icycles * 2
    cpu.icycles = 0
    cpu.cycles += cpu.base_cycles + access_cycles(cpu.bus) + ic
    same and cpu.next_pc == a + 4 and not cpu.attn and cpu.cycles < until and
      (not tc or (cpu.cpsr and FLAG_T) == 0)

  proc jit_thumb[B](cpu: ArmCpu[B]; until: int64; a, k: uint32; tc = false): bool {.inline, codegenDecl: "static inline __attribute__((always_inline)) $# $#$#".} =
    ## One Thumb opcode at `a`, translated from `k`: exec_one's Thumb path.
    mixin jit_fetch16, access_cycles, armv5
    cpu.cur_pc = a
    let instr = jit_fetch16(cpu.bus, a)
    cpu.next_pc = a + 2
    cpu.r[15] = a + 4
    let same = instr == k
    if (when armv5(B): likely(cpu.abort == 0) else: true):
      if likely(same): cpu.thumb_dispatch(k)
      else:
        when defined(nds_jitstats): inc jit_mismatch
        cpu.execute_thumb(instr)
    when armv5(B):
      if unlikely(cpu.abort != 0): cpu.take_abort(a)
    inc cpu.instr_count
    when defined(nds_jitstats):
      when armv5(B): inc jit_in_block9
      else: inc jit_in_block7
    let ic = when armv5(B): cpu.icycles else: cpu.icycles * 2
    cpu.icycles = 0
    cpu.cycles += cpu.base_cycles + access_cycles(cpu.bus) + ic
    same and cpu.next_pc == a + 2 and not cpu.attn and cpu.cycles < until and
      (not tc or (cpu.cpsr and FLAG_T) != 0)

  # -------------------------------------------------------------------------
  # Second form (tools/jitgen.py --v2): what the translator knows about each
  # opcode is used. A *pure* opcode -- ALU or multiply, no data access, no
  # write to r15 or the CPSR's mode/T bits, no exception -- whose fetch is
  # the next one in the line (ARM9) or page (ARM7) after an opcode of the
  # same block that left the bus's sequential fast path standing, needs:
  #
  # - no fetch checks: the bus's fast path conditions hold (the previous
  #   opcode's fetch was at a - size; nothing but a data access, a CP15
  #   write or WRAMCNT turns the path off, and a pure opcode makes none),
  #   so only its tracker stores and the opcode load remain
  #   (`fetch_seq32/16`); the opcode is still compared with the translated one;
  # - no abort, attn or next_pc checks (it cannot abort, touch I/O or jump);
  # - the clock and opcode count in locals: nothing a pure opcode runs reads
  #   them, so they are written back before every other opcode (whose bus
  #   accesses read the clock and may move it: a DMA's hold) and on leaving.
  #
  # Every other opcode runs as in the first form (`jit_full_*`).

  proc jit_full_arm[B](cpu: ArmCpu[B]; until: int64; a, k: uint32; tc: bool;
                       cyc: var int64; cnt: var uint64; lineok: var bool): bool {.inline, codegenDecl: "static inline __attribute__((always_inline)) $# $#$#".} =
    mixin fetch_seq_ok
    cpu.cycles = cyc
    cpu.instr_count = cnt
    result = cpu.jit_arm(until, a, k, tc)
    cyc = cpu.cycles
    cnt = cpu.instr_count
    lineok = fetch_seq_ok(cpu.bus, a + 4, 4)

  proc jit_full_thumb[B](cpu: ArmCpu[B]; until: int64; a, k: uint32; tc: bool;
                         cyc: var int64; cnt: var uint64; lineok: var bool): bool {.inline, codegenDecl: "static inline __attribute__((always_inline)) $# $#$#".} =
    mixin fetch_seq_ok
    cpu.cycles = cyc
    cpu.instr_count = cnt
    result = cpu.jit_thumb(until, a, k, tc)
    cyc = cpu.cycles
    cnt = cpu.instr_count
    lineok = fetch_seq_ok(cpu.bus, a + 2, 2)

  proc jit_changed[B](cpu: ArmCpu[B]; instr: uint32; thumb: static bool; cost: int64;
                      cyc: var int64; cnt: var uint64) {.noinline.} =
    ## A pure opcode's word changed since translation: exec_one's rest for
    ## the word fetched (the block then leaves).
    mixin access_cycles, armv5
    cpu.cycles = cyc
    cpu.instr_count = cnt
    when defined(nds_jitstats): inc jit_mismatch
    when thumb: cpu.execute_thumb(instr)
    else: cpu.execute_arm(instr)
    when armv5(B):
      if unlikely(cpu.abort != 0): cpu.take_abort(cpu.cur_pc)
    inc cpu.instr_count
    let ic = when armv5(B): cpu.icycles else: cpu.icycles * 2
    cpu.icycles = 0
    cpu.cycles += cpu.base_cycles + cost + access_cycles(cpu.bus) + ic
    cyc = cpu.cycles
    cnt = cpu.instr_count

  proc jit_pure_arm[B](cpu: ArmCpu[B]; until: int64; a, k: uint32;
                       cyc: var int64; cnt: var uint64; lineok: var bool): bool {.inline, codegenDecl: "static inline __attribute__((always_inline)) $# $#$#".} =
    mixin fetch_seq32, armv5
    if unlikely(not lineok):
      return cpu.jit_full_arm(until, a, k, false, cyc, cnt, lineok)
    cpu.cur_pc = a
    var cost = 0'i64
    let instr = fetch_seq32(cpu.bus, a, cost)
    cpu.r[15] = a + 8
    if unlikely(instr != k):
      cpu.next_pc = a + 4
      cpu.jit_changed(instr, false, cost, cyc, cnt)
      return false
    cpu.exec_arm_const(k)
    inc cnt
    when defined(nds_jitstats):
      when armv5(B): inc jit_in_block9
      else: inc jit_in_block7
    let ic = when armv5(B): cpu.icycles else: cpu.icycles * 2
    cpu.icycles = 0
    cyc += cpu.base_cycles + cost + ic
    if unlikely(cyc >= until):
      cpu.next_pc = a + 4
      return false
    true

  proc jit_pure_thumb[B](cpu: ArmCpu[B]; until: int64; a, k: uint32;
                         cyc: var int64; cnt: var uint64; lineok: var bool): bool {.inline, codegenDecl: "static inline __attribute__((always_inline)) $# $#$#".} =
    mixin fetch_seq16, armv5
    if unlikely(not lineok):
      return cpu.jit_full_thumb(until, a, k, false, cyc, cnt, lineok)
    cpu.cur_pc = a
    var cost = 0'i64
    let instr = fetch_seq16(cpu.bus, a, cost)
    cpu.r[15] = a + 4
    if unlikely(instr != k):
      cpu.next_pc = a + 2
      cpu.jit_changed(instr, true, cost, cyc, cnt)
      return false
    cpu.thumb_dispatch(k)
    inc cnt
    when defined(nds_jitstats):
      when armv5(B): inc jit_in_block9
      else: inc jit_in_block7
    let ic = when armv5(B): cpu.icycles else: cpu.icycles * 2
    cpu.icycles = 0
    cyc += cpu.base_cycles + cost + ic
    if unlikely(cyc >= until):
      cpu.next_pc = a + 2
      return false
    true

  # -------------------------------------------------------------------------
  # Third form (tools/jitgen.py --v3): a run of two or more pure opcodes in
  # one line (page) executes as a transaction on a shadow of the registers
  # and the CPSR -- a stack copy of the CPU object that the C compiler keeps
  # in host registers, the handlers being the interpreter's own, inlined with
  # the opcodes as constants. The run is committed (registers it writes, the
  # CPSR, the fetch trackers of its last opcode, the clock and count) only
  # when every opcode read from memory is the translated one and the clock
  # stays below `until` after the last (it rises with each opcode, so then it
  # did after every one: the run loop would have run them all). Otherwise
  # nothing has changed and the run goes opcode by opcode (second form).

  template jit_shadow*(cpu: untyped): untyped =
    ## Storage for a shadow CPU object on the stack (no destructor runs).
    array[(sizeof(typeof(cpu[])) + 7) div 8, uint64]

  proc jit_run_cost*[B](cpu, sc: ArmCpu[B]; n: int64; size: static uint32): int64 {.inline.} =
    ## The clock cost of a run of n pure opcodes: base cycles, their internal
    ## cycles, their sequential fetches.
    mixin fetch_seq_cost, armv5
    let ic = when armv5(B): sc.icycles else: sc.icycles * 2
    n * cpu.base_cycles + ic + n * fetch_seq_cost(cpu.bus, size)

  proc jit_run_commit*[B](cpu: ArmCpu[B]; last: uint32; size: static uint32) {.inline.} =
    mixin fetch_seq_commit
    cpu.cur_pc = last
    cpu.next_pc = last + size
    cpu.r[15] = last + size * 2
    fetch_seq_commit(cpu.bus, last, size)

  # the translated blocks: arm/jit_gen.nim, or the file -d:nds_jit_gen=PATH names
  const nds_jit_gen {.strdefine.} = ""
  when nds_jit_gen == "":
    include jit_gen
  else:
    macro include_jit_gen(): untyped = newTree(nnkIncludeStmt, newLit(nds_jit_gen))
    include_jit_gen()

  template jit_tables*(B: typedesc; blocks: untyped) =
    ## The lookup table of bus type B's blocks, expanded at the end of the
    ## bus module (where every mixin the blocks use is declared), as
    ## `dispatch_tables` is.
    var jtab: seq[JitEntry[B]]
    discard jit_fill(jtab, blocks)
    template jit_table(_: typedesc[B]): untyped {.inject, used.} = jtab
