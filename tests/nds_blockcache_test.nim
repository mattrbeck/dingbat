## Decoded blocks (arm/blockcache.nim, docs/nds/blockcache.md) change
## nothing: two machines run the same programs, one with the blocks and one
## without, and their whole states (the save-state payload) must be equal
## after every frame. The programs (tests/nds/src/blockcache) rewrite their
## own next opcode, have the other CPU rewrite one, run Thumb and ARM,
## conditional loads, multiplies whose time depends on the operands and
## register shifts, so the block's word check, its clock (slice ends fall in
## the middle of blocks all the time) and its fetch shortcuts are all used:
##
##   - ARM9 in ITCM, ARM7 in its WRAM;
##   - ARM9 in main RAM through the instruction cache (stores do not reach
##     cached code: the line is kept), the ARM7 in main RAM too, rewriting
##     an ARM9 opcode;
##   - a state of the plain machine loaded over the one with live blocks.
##
## Run with: nim c -r -d:test_harness -d:release -d:nds_blkstats --path:src tests/nds_blockcache_test.nim

import dingbat/nds/[nds, savestate]
import dingbat/nds/arm/cpu
include nds/blockcache_progs

var failures = 0

proc check(cond: bool; msg: string; detail = "") =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg, (if detail.len > 0: "  (" & detail & ")" else: "")
    failures.inc

proc tiny_rom(): seq[uint8] =
  ## A header plus two "b ." loops (nds_testroms_test.nim)
  result = newSeq[uint8](0x400)
  proc w32(r: var seq[uint8]; o: int; v: uint32) =
    for i in 0..3: r[o + i] = uint8(v shr (8 * i))
  result.w32(0x20, 0x200); result.w32(0x24, 0x0200_0000); result.w32(0x28, 0x0200_0000)
  result.w32(0x2C, 4)
  result.w32(0x30, 0x300); result.w32(0x34, 0x037F_8000); result.w32(0x38, 0x037F_8000)
  result.w32(0x3C, 4)
  result.w32(0x200, 0xEAFF_FFFE'u32)
  result.w32(0x300, 0xEAFF_FFFE'u32)


proc setup(blocks, icache: bool): NDS =
  let n = new_nds(tiny_rom(), @[], @[], @[])
  n.arm9.blk_on = blocks
  n.arm7.blk_on = blocks
  let b = Arm9Bus(nds: n)
  let b7 = Arm7Bus(nds: n)
  var a9 = 0x0000_0100'u32
  # the ARM7 in its WRAM, or in main RAM (where a fetch after a data access
  # costs more than a sequential one)
  let a7 = if icache: 0x0238_0000'u32 else: 0x0380_0100'u32
  if icache:
    # the protection unit and the instruction cache on, the firmware's
    # regions (main RAM code-cachable), as a game's crt0 leaves them
    a9 = 0x0200_0100'u32
    b.cp15_write(0, 1, 0, 0, n.cp15.control or 1 or 0x1000)
    for i in countup(0, PROG9.len - 1, 4):
      b7.write32(a9 + uint32(i), uint32(PROG9[i]) or (uint32(PROG9[i + 1]) shl 8) or
                 (uint32(PROG9[i + 2]) shl 16) or (uint32(PROG9[i + 3]) shl 24))
  else:
    b.cp15_write(0, 1, 0, 0, n.cp15.control or (1'u32 shl 18))   # ITCM on
    for i in countup(0, PROG9.len - 1, 4):
      b.write32(a9 + uint32(i), uint32(PROG9[i]) or (uint32(PROG9[i + 1]) shl 8) or
                (uint32(PROG9[i + 2]) shl 16) or (uint32(PROG9[i + 3]) shl 24))
  for i in countup(0, PROG7.len - 1, 4):
    b7.write32(a7 + uint32(i), uint32(PROG7[i]) or (uint32(PROG7[i + 1]) shl 8) or
               (uint32(PROG7[i + 2]) shl 16) or (uint32(PROG7[i + 3]) shl 24))
  # the ARM7 rewrites the ARM9's `patch` opcode when it can reach it
  b7.write32(a7 + PROG7_ext, if icache: a9 + PROG9_patch else: 0'u32)
  n.arm9.next_pc = a9
  n.arm7.next_pc = a7
  n

proc compare(name: string; icache: bool; frames: int; load_at = -1) =
  let on = setup(true, icache)
  let off = setup(false, icache)
  var first_diff = -1
  for f in 0 ..< frames:
    if f == load_at:
      # the plain machine's state over the one running blocks
      check on.load_state_bytes(off.state_bytes()), name & ": state loaded over live blocks"
    on.run_frame()
    off.run_frame()
    if first_diff < 0 and on.state_payload() != off.state_payload():
      first_diff = f
      when defined(blkdiag):
        template cmpf(e: untyped) =
          block:
            var n {.inject.} = on
            let va = e
            n = off
            let vb = e
            if va != vb: echo "    differs: ", astToStr(e), " ", va, " vs ", vb
        cmpf(n.arm9.r); cmpf(n.arm9.cpsr); cmpf(n.arm9.cycles); cmpf(n.arm9.next_pc); cmpf(n.arm9.cur_pc)
        cmpf(n.arm9.icycles); cmpf(n.arm9.instr_count); cmpf(n.arm9.spsr); cmpf(n.arm9.exc_count)
        cmpf(n.arm7.r); cmpf(n.arm7.cpsr); cmpf(n.arm7.cycles); cmpf(n.arm7.next_pc); cmpf(n.arm7.cur_pc)
        cmpf(n.arm7.icycles); cmpf(n.arm7.instr_count)
        cmpf(n.last_pc9); cmpf(n.last_fetch9); cmpf(n.last_data9); cmpf(n.wait9)
        cmpf(n.last_fetch7); cmpf(n.last_data7); cmpf(n.wait7); cmpf(n.sched.now)
        for i in 0 ..< on.main_ram.len:
          if on.main_ram[i] != off.main_ram[i]: echo "    main_ram ", i; break
        for i in 0 ..< on.itcm.len:
          if on.itcm[i] != off.itcm[i]: echo "    itcm ", i; break
        for i in 0 ..< on.arm7_wram.len:
          if on.arm7_wram[i] != off.arm7_wram[i]: echo "    arm7_wram ", i; break
        let a = on.state_payload()
        let b = off.state_payload()
        for i in 0 ..< min(a.len, b.len):
          if a[i] != b[i]: echo "    payload offset ", i, " of ", a.len; break
  check first_diff < 0, name & ": whole state equal after each of " & $frames & " frames",
        "first differs after frame " & $first_diff
  check on.arm9.instr_count == off.arm9.instr_count and on.arm7.instr_count == off.arm7.instr_count,
        name & ": opcode counts equal", $on.arm9.instr_count & " / " & $off.arm9.instr_count
  when defined(nds_blkstats):
    let s9 = on.arm9.blk_stats()
    let s7 = on.arm7.blk_stats()
    echo "    arm9: ", s9[0], " of ", on.arm9.instr_count, " opcodes in blocks, ", s9[3],
         " changed; arm7: ", s7[0], " of ", on.arm7.instr_count, ", ", s7[3], " changed", (when defined(blkdiag): " " & $s7 else: "")
    # (the programs rewrite their code so often that their blocks are often
    # dropped: the share in blocks is low, not the point)
    check s9[0] > on.arm9.instr_count div 4 and s7[0] > on.arm7.instr_count div 10,
          name & ": blocks ran"
    # with the instruction cache on, the ARM9 runs the cached line, not the
    # rewritten memory: only the ARM7 sees its code change there
    check (icache or s9[3] > 0) and s7[3] > 0, name & ": opcodes changed under decoded blocks"

echo "decoded blocks: ITCM and ARM7 WRAM, self-modifying"
compare("itcm", false, 60)
echo "decoded blocks: main RAM through the instruction cache, rewritten by the ARM7"
compare("icache", true, 60)
echo "decoded blocks: a state loaded over live blocks"
compare("load", false, 40, load_at = 20)

if failures > 0:
  echo failures, " failure(s)"
  quit(1)
echo "all passed"
