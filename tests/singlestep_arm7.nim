## SingleStepTests/ARM7TDMI against dingbat's GBA CPU (tests/singlestep_test.nim
## drives it). Each vector is one ARM or Thumb instruction from a full
## register state (every bank and SPSR), with the final state and the bus
## transactions it made, in order: kind (opcode fetch, load, store), size,
## address, data and the access type (nonsequential/sequential, lock).
##
## The CPU is the real one in a GBA built from a blank cart; dingbat's own
## read_instr and arm_execute / thumb_execute run the instruction. Built with
## -d:cpu_testbus, every bus accessor hands its access to this driver instead
## of the memory map (gba.nim, gba_testbus_read), as the vectors' flat 32-bit
## space needs. Loads are served from the vector's transaction list, opcode
## fetches return the opcode at the instruction's address and the address
## itself elsewhere, as the vectors were made.
##
## Scored per case:
## - state: r0-r15 and every bank (the vectors' R is the User bank, R_fiq
##   etc. the banked registers), CPSR and the five SPSRs. The pipeline words
##   are not compared: dingbat's pipeline is lazy (below).
## - bus: the transactions in order, each kind, size, address (to its
##   size's alignment: the bus ignores the low address bits of a word or
##   halfword access) and, for loads and stores, data (to its size).
##   Then the access type (N/S) of each access but the instruction's own
##   fetch, whose type the vectors set from the case's initial state: the
##   refill is N then S (clear_pipeline's n + s), and a load or store is S
##   when it continues the address of the load or store before it in the
##   same instruction, an LDM/STM burst, N otherwise -- the address
##   continuity dingbat's gamepak bus prices accesses by
##   (bus.rom_access_cycles). And the lock flag: dingbat holds the bus for
##   both of SWP's accesses (bus.swp_lock), the vectors mark the write that
##   ends the locked pair, so an access marked locked must be one dingbat
##   holds the bus for.
##
## Mapping dingbat's fetch model onto the vectors' bus: the console's fetch
## during an instruction's first cycle is two instructions ahead, at r15.
## dingbat fetches lazily at the executing address (cpu.read_instr), one
## fetch per instruction either way, so that fetch is scored at r15. After a
## branch, clear_pipeline charges the refill's two accesses without making
## them (the next instructions fetch their own words); the driver scores
## them as the refill the console makes: the destination and the word or
## halfword after it, in the state the instruction leaves the CPU in. Internal
## cycles are not scored: the vectors do not list them, and their `cycle`
## numbers are documented as unreliable.

import std/[os, strutils, strformat]
import dingbat/gba/gba
import dingbat/common/[scheduler, test_output]

type
  Ev = object
    kind: int      # 0 fetch, 1 load, 2 store, 4 refill
    size: int
    address: uint32
    data: uint32
    lock: bool
    thumb: bool    # refill: the state it refilled in
    role: int      # materialized: 0 the instruction's fetch, 1/2 refill
                   # first/second, 3 load or store, 4 another fetch

  Txn* = object
    kind*, size*: int
    address*, data*: uint32
    access*: uint32

  ArmState* = object
    r*: array[16, uint32]
    fiq*: array[7, uint32]
    svc*, abt*, irq*, und*: array[2, uint32]
    cpsr*: uint32
    spsr*: array[5, uint32]   # fiq svc abt irq und

  ArmCase* = object
    initial*, final*: ArmState
    init_access*: uint32
    txns*: seq[Txn]
    opcode*, base*: uint32

  CaseResult* = object
    state_ok*, bus_ok*, access_ok*: bool
    why*: string
    sig*: string     # what differed, without values (for bucketing)
    psr_xor*: uint32 # CPSR/SPSR bits that differ, all PSRs together
    regs_differ*: bool

var gbaref: GBA
var evs: seq[Ev]
var cur: ptr ArmCase
var used: seq[bool]
var fetches = 0

proc code_value(address: uint32): uint32 =
  if cur != nil and address == cur.base: cur.opcode else: address

proc find_load(size: int; address: uint32): int =
  if cur == nil: return -1
  let mask = not uint32(size - 1)
  for i, t in cur.txns:
    if t.kind == 1 and not used[i] and t.size == size and t.address == address:
      return i
  for i, t in cur.txns:
    if t.kind == 1 and not used[i] and (t.address and mask) == (address and mask):
      return i
  -1

proc lane(t: Txn; size: int; address: uint32): uint32 =
  ## A load of `size` at `address` out of a transaction's data, taken as
  ## the aligned unit of the transaction's size (byte lanes by address).
  result = t.data
  if size < t.size:
    result = result shr ((address and uint32(t.size - 1)) * 8)
  result = result and (if size == 1: 0xFF'u32 elif size == 2: 0xFFFF'u32
                       else: 0xFFFFFFFF'u32)

proc tb_read(kind, size: int; address: uint32): uint32 {.nimcall.} =
  # A misaligned LDRSH loads its byte over a halfword access (bus.nim,
  # read_half_signed): scored as the halfword access it is.
  let bus_size = if kind == 1 and size == 1 and gbaref != nil and
                    gbaref.bus.ldrsh_odd: 2 else: size
  evs.add Ev(kind: kind, size: bus_size, address: address,
             lock: gbaref != nil and gbaref.bus.swp_lock)
  if kind == 0:
    inc fetches
    result = if fetches == 1: cur.opcode else: code_value(address)
    if size == 2: result = result and 0xFFFF'u32
  else:
    let i = find_load(bus_size, address)
    if i >= 0:
      used[i] = true
      result = lane(cur.txns[i], size, address)
      evs[^1].data = lane(cur.txns[i], bus_size, address)
    else:
      result = 0
    return
  evs[^1].data = result

proc tb_peek(size: int; address: uint32): uint32 {.nimcall.} =
  ## An untimed read (MRC from the debug unit, the LDM^ glitch's look at the
  ## next opcode, MSR T's pipeline): the code the vector put there.
  let mask = not uint32(size - 1)
  if cur != nil:
    for t in cur.txns:
      if t.kind == 1 and (t.address and mask) == (address and mask):
        return lane(t, size, address)
  result = code_value(address)
  if size == 2: result = result and 0xFFFF'u32
  elif size == 1: result = result and 0xFF'u32

proc tb_write(size: int; address, value: uint32) {.nimcall.} =
  evs.add Ev(kind: 2, size: size, address: address, data: value,
             lock: gbaref != nil and gbaref.bus.swp_lock)

proc tb_idle(n: int) {.nimcall.} = discard

proc tb_refill() {.nimcall.} =
  if gbaref == nil: return
  let cpu = gbaref.cpu
  evs.add Ev(kind: 4, address: cpu.r[15], thumb: cpu.cpsr.thumb)

proc blank_rom(dir: string): string =
  result = dir / "singlestep-blank.gba"
  if not fileExists(result):
    writeFile(result, newString(0x200))

proc new_test_gba*(scratch: string): GBA =
  gba_testbus_read = tb_read
  gba_testbus_write = tb_write
  gba_testbus_peek = tb_peek
  gba_testbus_idle = tb_idle
  gba_testbus_refill = tb_refill
  result = new_gba("", blank_rom(scratch), run_bios = false, use_hle = false)
  result.test_output = new_test_output()
  result.post_init()
  result.cpu.attempt_waitloop_detection = false
  gbaref = result

# ---- the vectors' binary format (v1/*.json.bin; transcode_json.py there) ----

proc u32(buf: string; p: int): uint32 {.inline.} =
  uint32(buf[p].uint8) or (uint32(buf[p+1].uint8) shl 8) or
    (uint32(buf[p+2].uint8) shl 16) or (uint32(buf[p+3].uint8) shl 24)

proc read_state(buf: string; p: int; s: var ArmState; access: var uint32): int =
  result = int(cast[int32](u32(buf, p)))
  var q = p + 8
  template nxt(): uint32 =
    let v = u32(buf, q)
    q += 4
    v
  for i in 0 .. 15: s.r[i] = nxt()
  for i in 0 .. 6: s.fiq[i] = nxt()
  for i in 0 .. 1: s.svc[i] = nxt()
  for i in 0 .. 1: s.abt[i] = nxt()
  for i in 0 .. 1: s.irq[i] = nxt()
  for i in 0 .. 1: s.und[i] = nxt()
  s.cpsr = nxt()
  for i in 0 .. 4: s.spsr[i] = nxt()
  discard nxt(); discard nxt()       # pipeline
  access = nxt()

proc load_cases*(path: string): seq[ArmCase] =
  let buf = readFile(path)
  if u32(buf, 0) != 0xD33DBAE0'u32:
    raise newException(ValueError, path & ": not a vector file")
  # The runner fetches a prefix of each file (dingbat_test_runner,
  # Arm7tdmiPrefixBytes): the cases are read up to the last whole one.
  let n = int(u32(buf, 4))
  var p = 8
  result = newSeqOfCap[ArmCase](n)
  for i in 0 ..< n:
    if p + 4 > buf.len: break
    let full = int(cast[int32](u32(buf, p)))
    if full <= 0 or p + full > buf.len: break
    var q = p + 4
    var c: ArmCase
    var fa: uint32
    q += read_state(buf, q, c.initial, c.init_access)
    q += read_state(buf, q, c.final, fa)
    let tsz = int(cast[int32](u32(buf, q)))
    let nt = int(u32(buf, q + 8))
    for k in 0 ..< nt:
      let b = q + 12 + 24 * k
      c.txns.add Txn(kind: int(u32(buf, b)), size: int(u32(buf, b + 4)),
                     address: u32(buf, b + 8), data: u32(buf, b + 12),
                     access: u32(buf, b + 20))
    q += tsz
    c.opcode = u32(buf, q + 8)
    c.base = u32(buf, q + 12)
    result.add c
    p += full

# ---- running a case ----

proc bank_of(mode: uint32): int = mode_bank(cast[CpuMode](mode and 0x1F))

proc load_state(cpu: CPU; s: ArmState) =
  # Every bank first, then the current mode's registers into r[].
  for i in 0 .. 4: cpu.reg_banks[0][i] = s.r[8 + i]
  cpu.reg_banks[0][5] = s.r[13]; cpu.reg_banks[0][6] = s.r[14]
  for i in 0 .. 6: cpu.reg_banks[1][i] = s.fiq[i]
  for (b, pair) in [(3, s.svc), (4, s.abt), (2, s.irq), (5, s.und)]:
    cpu.reg_banks[b][5] = pair[0]; cpu.reg_banks[b][6] = pair[1]
  for (b, k) in [(1, 0), (3, 1), (4, 2), (2, 3), (5, 4)]:
    cpu.spsr_banks[b] = s.spsr[k]
  for i in 0 .. 15: cpu.r[i] = s.r[i]
  let b = bank_of(s.cpsr)
  if b == 1:
    for i in 8 .. 14: cpu.r[i] = s.fiq[i - 8]
  elif b in 2 .. 5:
    cpu.r[13] = cpu.reg_banks[b][5]; cpu.r[14] = cpu.reg_banks[b][6]
  cpu.cpsr = cast[PSR](s.cpsr)
  cpu.spsr = cast[PSR](if b in 1 .. 5: cpu.spsr_banks[b] else: s.cpsr)

proc save_state(cpu: CPU): ArmState =
  ## dingbat's register file in the vectors' layout.
  let b = bank_of(uint32(cpu.cpsr))
  for i in 0 .. 15: result.r[i] = cpu.r[i]
  if b == 1:
    for i in 8 .. 12: result.r[i] = cpu.reg_banks[0][i - 8]
  if b != 0:
    result.r[13] = cpu.reg_banks[0][5]; result.r[14] = cpu.reg_banks[0][6]
  for i in 0 .. 6:
    result.fiq[i] = if b == 1: cpu.r[8 + i] else: cpu.reg_banks[1][i]
  template pair(bank: int): array[2, uint32] =
    if b == bank: [cpu.r[13], cpu.r[14]]
    else: [cpu.reg_banks[bank][5], cpu.reg_banks[bank][6]]
  result.svc = pair(3); result.abt = pair(4)
  result.irq = pair(2); result.und = pair(5)
  result.cpsr = uint32(cpu.cpsr)
  for (bank, k) in [(1, 0), (3, 1), (4, 2), (2, 3), (5, 4)]:
    result.spsr[k] = if b == bank: uint32(cpu.spsr) else: cpu.spsr_banks[bank]

proc reset_cpu(gba: GBA) =
  let cpu = gba.cpu
  cpu.pipeline.clear()
  cpu.refill_pending = false
  cpu.ret_refilled_thumb = false
  cpu.halted = false
  gba.bus.cycles = 0
  gba.bus.synced = 0
  gba.scheduler.clear(etLdmGlitch)
  gba.scheduler.clear(etUndefMode)
  gba.scheduler.clear(etInterrupts)

proc materialize(c: ArmCase; final_r15: uint32; final_thumb: bool): seq[Ev] =
  ## dingbat's events as the console's bus transactions (see the header).
  var refills = 0
  for e in evs:
    if e.kind == 4: inc refills
  var seen_refills = 0
  var first = true
  for e in evs:
    case e.kind
    of 0:
      if first:
        first = false
        let lead = if e.size == 2: 4'u32 else: 8'u32
        result.add Ev(kind: 0, size: e.size, address: e.address + lead, role: 0)
      else:
        var f = e
        f.role = 4
        result.add f
    of 4:
      inc seen_refills
      var thumb = e.thumb
      var target = e.address
      if seen_refills == refills:
        # The last refill is the one the CPU leaves with: an exception
        # return's restore can still move r15 and T after clear_pipeline.
        thumb = final_thumb
        target = final_r15 - (if thumb: 4'u32 else: 8'u32)
      let step = if thumb: 2'u32 else: 4'u32
      let a = target and not (step - 1)
      result.add Ev(kind: 0, size: int(step), address: a, role: 1)
      result.add Ev(kind: 0, size: int(step), address: a + step, role: 2)
    else:
      var d = e
      d.role = 3
      result.add d

proc size_mask(size: int): uint32 =
  case size
  of 1: 0xFF'u32
  of 2: 0xFFFF'u32
  else: 0xFFFFFFFF'u32

proc run_case*(gba: GBA; c: var ArmCase): CaseResult =
  let cpu = gba.cpu
  reset_cpu(gba)
  cpu.load_state(c.initial)
  cur = addr c
  used = newSeq[bool](c.txns.len)
  evs.setLen(0)
  fetches = 0
  cpu.testbus_step()
  # The LDM^ glitch belongs to the instruction after; put the registers back.
  if cpu.ldm_glitch != 0: cpu.ldm_glitch_restore(ran = false)

  # ---- state ----
  var got = cpu.save_state()
  let thumb = (got.cpsr and 0x20'u32) != 0
  # A branch into Thumb leaves bit 0 in r15 until the next fetch clears it
  # (cpu.read_instr); the architectural value has it clear.
  if thumb: got.r[15] = got.r[15] and not 1'u32
  let final_r15 = got.r[15]
  var diffs: seq[string]
  var sigs: seq[string]
  template chk(label: string; g, w: uint32) =
    if g != w:
      diffs.add label & "=" & toHex(g, 8) & "/" & toHex(w, 8)
      sigs.add label
  var want = c.final
  if thumb: want.r[15] = want.r[15] and not 1'u32
  for i in 0 .. 15: chk("r" & $i, got.r[i], want.r[i])
  for i in 0 .. 6: chk("fiq" & $(i + 8), got.fiq[i], want.fiq[i])
  for (n, g, w) in [("svc", got.svc, want.svc), ("abt", got.abt, want.abt),
                    ("irq", got.irq, want.irq), ("und", got.und, want.und)]:
    chk(n & "13", g[0], w[0]); chk(n & "14", g[1], w[1])
  result.regs_differ = diffs.len > 0
  chk("cpsr", got.cpsr, want.cpsr)
  for k, n in ["fiq", "svc", "abt", "irq", "und"]:
    chk("spsr_" & n, got.spsr[k], want.spsr[k])
  result.psr_xor = got.cpsr xor want.cpsr
  for k in 0 .. 4: result.psr_xor = result.psr_xor or (got.spsr[k] xor want.spsr[k])
  result.state_ok = diffs.len == 0
  if diffs.len > 0: result.why = "state " & diffs.join(" ")
  result.sig = sigs.join(",")

  # ---- bus ----
  let mine = c.materialize(final_r15, thumb)
  var bus_why = ""
  var acc_why = ""
  if mine.len != c.txns.len:
    var a, b: seq[string]
    for e in mine: a.add &"{e.kind}:{e.size}:{e.address:08X}"
    for t in c.txns: b.add &"{t.kind}:{t.size}:{t.address:08X}"
    bus_why = &"{mine.len}/{c.txns.len} [{a.join(\" \")}] / [{b.join(\" \")}]"
  else:
    var prev_data_end = 1'u32     # odd: no data access yet
    for i, t in c.txns:
      let e = mine[i]
      let mask = not uint32(t.size - 1)
      if e.kind != t.kind or e.size != t.size or
         (e.address and mask) != (t.address and mask):
        bus_why = &"#{i} {e.kind}:{e.size}:{e.address:08X}/{t.kind}:{t.size}:{t.address:08X}"
        break
      if t.kind != 0 and (e.data and size_mask(t.size)) != (t.data and size_mask(t.size)):
        bus_why = &"#{i} data {e.data:08X}/{t.data:08X}"
        break
      let a = e.address and mask
      # dingbat's access type (see the header): the refill is N then S
      # (clear_pipeline's n + s); a load or store is S when it continues the
      # one before it in the same instruction, as an LDM/STM burst does.
      # The instruction's own fetch is not scored: its type is the previous
      # instruction's business (the vectors set it from the initial state).
      var seqd = -1
      case e.role
      of 1: seqd = 0
      of 2: seqd = 1
      of 3: seqd = int(a == prev_data_end)
      else: discard
      if e.role == 3: prev_data_end = a + uint32(t.size)
      if acc_why.len == 0 and seqd >= 0:
        let seqw = (t.access and 1'u32) != 0
        if (seqd == 1) != seqw:
          acc_why = "#" & $i & (if seqd == 1: " S/N" else: " N/S")
        elif not e.lock and (t.access and 8'u32) != 0:
          acc_why = "#" & $i & " lock"
  result.bus_ok = bus_why.len == 0
  result.access_ok = bus_why.len == 0 and acc_why.len == 0
  if bus_why.len > 0:
    if result.why.len > 0: result.why.add "; "
    result.why.add "bus " & bus_why
    result.sig.add (if mine.len != c.txns.len: " bus:count" else: " bus:" & bus_why.split(' ')[1].split(':')[0])
  elif acc_why.len > 0:
    if result.why.len > 0: result.why.add "; "
    result.why.add "access " & acc_why
    result.sig.add " access:" & acc_why.split(' ')[1]

# ---- known divergences ----
#
# Every failing case is put in one of these buckets or reported as
# unexplained. Each bucket is a place where dingbat follows the console and
# the vectors' model does something else -- measured on an AGB SP, cited by
# the cell in docs/hwprobe-sst.md (the probe made for these divergences,
# tests/roms/payloads/sst.s and sstrisk.s) or docs/hwprobe-results-agb.md --
# or an encoding the ARM7TDMI leaves UNPREDICTABLE that the probe did not
# reach. tests/README.md ("SingleStepTests") has the table.

proc known_divergence*(stem: string; c: ArmCase; r: CaseResult): string =
  let op = c.opcode
  let mode = c.initial.cpsr and 0x1F'u32
  let rd = int((op shr 12) and 15)
  let rn = int((op shr 16) and 15)
  let rs = int((op shr 8) and 15)
  let rm = int(op and 15)
  let s_bit = ((op shr 20) and 1) != 0
  let w_bit = ((op shr 21) and 1) != 0
  let p_bit = ((op shr 24) and 1) != 0
  if stem.startsWith("arm_data_proc"):
    let opc = (op shr 21) and 15
    if rd == 15 and s_bit and mode in [0x10'u32, 0x1F'u32]:
      if opc in 8'u32 .. 11'u32:
        return "hardware (sst u.tstp.sys): test op with Rd = r15 in User/System keeps NZCV"
      return "hardware (sst r.sysmovs, r.usermovs): S-bit write to r15 in User/System keeps NZCV"
    # In the exception modes the vectors restore CPSR from SPSR for a test
    # op with Rd = r15 as dingbat does (and the console: sst u.tstp.svc,
    # u.tstp.irq). A register-specified shift by r15 reads PC+8 on both
    # sides since the console's u.rs15_lsr.
  elif stem == "arm_ldm_stm":
    if rn == 15 and w_bit:
      return "hardware (sst r.ldmia_pc!, r.stmia_pc!): no writeback to a base of r15"
  elif stem.startsWith("arm_ldr_str"):
    if rn == 15 and (w_bit or not p_bit):
      return "hardware (sst r.ldr_pc_*, r.str_pc_*): r15 base writeback"
  elif stem == "arm_mcr_mrc":
    if rs == 14: return "hardware (sst x.mrc14_*, x.mcr14_c1): CP14 answers MRC/MCR"
  elif stem == "arm_mrs":
    if rd == 15: return "hardware (sst x.mrs_r15): MRS to r15 is a branch"
  elif stem.startsWith("arm_msr"):
    # Bits 8-27 do not latch; SPSR bit 4 is wired high.
    if not r.regs_differ and r.bus_ok and (r.psr_xor and not 0x0FFFFF10'u32) == 0:
      return "hardware (sst r.cpsr_*, r.spsr_*): PSR bits 8-27 read 0, SPSR bit 4 reads 1"
  elif stem == "arm_mul_mla":
    let rdm = int((op shr 16) and 15)
    let acc = ((op shr 21) and 1) != 0
    if rdm == 15: return "hardware (sst u.mul_rd15, u.mla_rd15): a multiply does not write r15"
    if rs == 15 or rm == 15 or (acc and rd == 15):
      return "hardware (sst u.mul_rm15, u.mul_rs15, u.mla_rn15): r15 as a multiply operand reads PC+8"
  elif stem == "arm_mull_mlal":
    let hi = int((op shr 16) and 15)
    if hi == 15 or rd == 15:
      return "hardware (sst u.umull_rdlo15, u.umull_rdhi15): a multiply does not write r15"
    if rs == 15 or rm == 15:
      return "hardware (sst u.umull_rm15): r15 as a multiply operand reads PC+8"
  elif stem == "arm_swp":
    # (r15 as Rm or Rd: the vectors, dingbat and the console agree, sst
    # u.swp_rm15 and u.swp_rd15)
    if rn == 15: return "hardware (sst u.swp_rn15): SWP with a base of r15 uses PC+8"
  elif stem == "thumb_add_cmp_mov_hi":
    if ((op shr 8) and 3) == 1 and (op and 0x80) != 0 and (op and 7) == 7:
      return "hardware (sst r.thumb_cmp_pc.*): Thumb CMP r15 restores CPSR from SPSR"
  elif stem == "thumb_undefined_bcc":
    return "hardware (sst x.thumb_dexx): Thumb Bcc with cond 1110 is undefined"
  ""
