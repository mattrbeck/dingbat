## The DS's two CPUs as one generic interpreter: the ARM946E-S (ARMv5TE, the
## ARM9) and the ARM7TDMI (ARMv4T, the ARM7). `ArmCpu[B]` is instantiated
## once per bus type; everything the CPU needs from outside is a `mixin` on B:
##
##   armv5(B): bool            -- typedesc template: ARMv5TE instruction set
##   read8/16/32(bus, a)       -- data reads (a aligned to the width)
##   write8/16/32(bus, a, v)   -- data writes
##   fetch16/32(bus, a)        -- code fetches (ITCM, BIOS, ...)
##   irq_line(bus): bool       -- IME and (IE and IF) != 0
##   irq_wake(bus): bool       -- (IE and IF) != 0: ends a halt
##   cp15_read(bus, op1, cn, cm, op2): uint32 / cp15_write(...)  (ARMv5 only)
##   swi_hook(bus, comment): bool  -- true = handled by HLE, skip the vector
##   access_cycles(bus): int   -- cycles the last instruction's bus accesses
##                                added (the bus accumulates them)
##   idle_epoch(bus): uint64   -- changes whenever anything a loop could read
##                                may have changed (idle-loop skipping, below)
##   idle_sig(bus): IdleSig    -- the bus's timing state that the next
##                                access costs depend on
##
## Timing: every instruction costs `base_cycles` master cycles, plus what
## the bus charged for its code fetch and data accesses (nds/timing.nim),
## plus its internal cycles (GBATEK "ARM CPU Instruction Cycle Times": +1I
## for a register-specified shift, LDR/LDM/SWP, m(+1/+2)I for multiplies;
## the ARM9 counts loads and multiplies as one/two interlock cycles). An
## ARM7 cycle is two master cycles, an ARM9 cycle one. The GBA core's
## cycle-exact prefetch model is deliberately not shared (docs/nds/spec.md).

import std/bitops
from std/strutils import toHex
when defined(ndsdebug): import std/tables

type
  CpuMode* = enum
    mUSR = 0x10, mFIQ = 0x11, mIRQ = 0x12, mSVC = 0x13, mABT = 0x17,
    mUND = 0x1B, mSYS = 0x1F

const
  FLAG_N* = 1'u32 shl 31
  FLAG_Z* = 1'u32 shl 30
  FLAG_C* = 1'u32 shl 29
  FLAG_V* = 1'u32 shl 28
  FLAG_Q* = 1'u32 shl 27
  FLAG_I* = 1'u32 shl 7
  FLAG_F* = 1'u32 shl 6
  FLAG_T* = 1'u32 shl 5

const
  ABORT_DATA* = 1'u8        ## a data access the protection unit refused
  ABORT_PREFETCH* = 2'u8    ## an opcode fetch it refused

type
  IdleSig* = array[8, uint32]
    ## The bus's per-CPU timing state at a loop head (sequential-access
    ## tracking, cache fast paths, protection-unit pages): equal at two heads
    ## means equal access costs in the pass that follows.

  ArmCpu*[B] = ref object
    r*: array[16, uint32]
    cpsr*: uint32
    spsr*: uint32
    bank_sp_lr: array[6, array[2, uint32]]
    fiq_r8_12: array[5, uint32]
    usr_r8_12: array[5, uint32]
    spsr_bank: array[6, uint32]
    next_pc*: uint32        ## address of the next instruction to execute
    cur_pc*: uint32         ## address of the instruction executing now
    bus*: B
    halted*: bool
    cycles*: int64          ## master-clock timestamp this CPU has reached
    base_cycles*: int64     ## master cycles charged per instruction
    vector_base*: uint32    ## 0xFFFF0000 (ARM9, CP15 control bit 13) or 0
    no_load_interwork*: bool  ## CP15 control bit 15 ("pre-ARMv5 mode"): LDR,
                              ## LDM and POP to r15 keep the T bit (GBATEK)
    instr_count*: uint64
    icycles*: int64         ## internal (I) cycles of the running instruction,
                            ## in this CPU's clocks (step converts)
    trace*: int             ## instructions left to log to stderr (debug)
    exc_count*: int         ## undefined-instruction / abort exceptions taken
    abort*: uint8           ## set by the bus: ABORT_DATA / ABORT_PREFETCH
    bank_xfer*: bool        ## an LDM/STM^ is moving user-bank registers: the
                            ## mode reads USR but the accesses stay privileged
    exc_pc*: uint32         ## the instruction that raised the last one
    # Idle-loop skipping (`loop_edge`); none of it is machine state: a fresh
    # detector proves the same loops again (not saved: savestate.nim)
    wl_on*: bool            ## skipping enabled (DINGBAT_NDS_NO_SKIP=1 clears it)
    wl_until: int64         ## the running `run` call's end
    wl_bump: uint64         ## CPU-side disturbances: exceptions, mode switches, SWIs
    wl_head: uint32         ## the watched loop head (a backward branch's target)
    wl_other: int32         ## arrivals at other heads since it was last visited
    wl_epoch: uint64        ## idle_epoch + wl_bump at the last visit
    wl_have: bool           ## wl_regs..wl_instrs hold the state at one visit
    wl_tries: int32         ## visits compared with that snapshot since
    wl_idle*: bool          ## the last visit matched it: repeating, nothing touched
    wl_cycles: int64        ## clock and opcode count at the snapshot (or the
    wl_instrs: uint64       ## last skip)
    wl_fails: int32         ## visits in a row that found the loop doing work
    wl_skipped*: int64      ## master cycles skipped so far (a statistic)
    wl_cold*: int32         ## backward branches the bus lets pass unwatched
    wl_cold_len: int32      ## the next cool-down's length
    wl_regs: array[15, uint32]
    wl_cpsr, wl_spsr: uint32
    wl_sig: IdleSig
    when defined(ndsdebug):
      profiling*: bool      ## count executed instructions per 64-byte block
      profile*: CountTable[uint32]   ## instructions per block
      cprofile*: CountTable[uint32]  ## master cycles per block

proc bank_of(mode: uint32): int {.inline.} =
  case mode and 0x1F
  of 0x10, 0x1F: 0
  of 0x11: 1
  of 0x12: 2
  of 0x13: 3
  of 0x17: 4
  of 0x1B: 5
  else: 0

proc new_arm_cpu*[B](bus: B; base_cycles: int64): ArmCpu[B] =
  result = ArmCpu[B](bus: bus, base_cycles: base_cycles)
  result.cpsr = uint32(mSVC) or FLAG_I or FLAG_F

template thumb*(cpu: ArmCpu): bool = (cpu.cpsr and FLAG_T) != 0
template flag(cpu: ArmCpu; f: uint32): bool = (cpu.cpsr and f) != 0

proc mode*(cpu: ArmCpu): uint32 {.inline.} = cpu.cpsr and 0x1F

proc switch_mode*[B](cpu: ArmCpu[B]; new_mode: uint32) =
  let old_mode = cpu.cpsr and 0x1F
  let nm = new_mode and 0x1F
  if old_mode == nm: return
  inc cpu.wl_bump
  let ob = bank_of(old_mode)
  let nb = bank_of(nm)
  if old_mode == uint32(mFIQ) or nm == uint32(mFIQ):
    if old_mode == uint32(mFIQ):
      for i in 0..4:
        cpu.fiq_r8_12[i] = cpu.r[8 + i]
        cpu.r[8 + i] = cpu.usr_r8_12[i]
    if nm == uint32(mFIQ):
      for i in 0..4:
        cpu.usr_r8_12[i] = cpu.r[8 + i]
        cpu.r[8 + i] = cpu.fiq_r8_12[i]
  if ob != nb:
    cpu.bank_sp_lr[ob][0] = cpu.r[13]
    cpu.bank_sp_lr[ob][1] = cpu.r[14]
    cpu.spsr_bank[ob] = cpu.spsr
    cpu.r[13] = cpu.bank_sp_lr[nb][0]
    cpu.r[14] = cpu.bank_sp_lr[nb][1]
    cpu.spsr = if nb == 0: cpu.cpsr else: cpu.spsr_bank[nb]
  cpu.cpsr = (cpu.cpsr and not 0x1F'u32) or nm

proc set_cpsr*[B](cpu: ArmCpu[B]; v: uint32) =
  cpu.switch_mode(v and 0x1F)
  cpu.cpsr = v

proc set_mode_sp*[B](cpu: ArmCpu[B]; mode: CpuMode; sp: uint32) =
  ## Boot helper: the banked r13 of `mode`, whatever mode the CPU is in.
  let b = bank_of(uint32(mode))
  if b == bank_of(cpu.cpsr): cpu.r[13] = sp
  else: cpu.bank_sp_lr[b][0] = sp

proc jump*[B](cpu: ArmCpu[B]; target: uint32) {.inline.} =
  ## Branch in the current state.
  cpu.next_pc = if cpu.thumb: target and not 1'u32 else: target and not 3'u32

proc jump_interwork*[B](cpu: ArmCpu[B]; target: uint32) {.inline.} =
  ## BX semantics: bit 0 selects Thumb.
  if (target and 1) != 0:
    cpu.cpsr = cpu.cpsr or FLAG_T
    cpu.next_pc = target and not 1'u32
  else:
    cpu.cpsr = cpu.cpsr and not FLAG_T
    cpu.next_pc = target and not 3'u32

proc jump_load[B](cpu: ArmCpu[B]; target: uint32) {.inline.} =
  ## A load into r15 (LDR, LDM, POP): ARMv5 interworks unless CP15 control
  ## bit 15 is set; ARMv4 stays in the current state.
  mixin armv5
  when armv5(B):
    if cpu.no_load_interwork: cpu.jump(target) else: cpu.jump_interwork(target)
  else:
    cpu.jump(target)

proc exception*[B](cpu: ArmCpu[B]; mode: CpuMode; vector: uint32; lr: uint32) =
  let old = cpu.cpsr
  inc cpu.wl_bump
  cpu.switch_mode(uint32(mode))
  cpu.spsr = old
  cpu.r[14] = lr
  cpu.cpsr = (cpu.cpsr and not FLAG_T) or FLAG_I
  if mode == mFIQ: cpu.cpsr = cpu.cpsr or FLAG_F
  cpu.next_pc = cpu.vector_base + vector

proc count_exc(cpu: ArmCpu) {.noinline.} =
  ## Undefined-instruction and abort exceptions, for tools/ndssweep.nim's
  ## crash check.
  inc cpu.exc_count
  cpu.exc_pc = cpu.cur_pc

proc undefined_instr*[B](cpu: ArmCpu[B]) =
  when defined(ndstrace) or not defined(release):
    stderr.writeLine("nds cpu: undefined instruction at 0x" & toHex(cpu.cur_pc, 8) &
                     (if cpu.thumb: " (thumb)" else: ""))
  cpu.count_exc()
  cpu.exception(mUND, 0x04, cpu.next_pc)

proc software_interrupt*[B](cpu: ArmCpu[B]; comment: uint32) =
  mixin swi_hook
  inc cpu.wl_bump
  if swi_hook(cpu.bus, comment): return
  cpu.exception(mSVC, 0x08, cpu.next_pc)

proc restore_spsr[B](cpu: ArmCpu[B]) {.inline.} =
  ## CPSR <- SPSR for an S-bit write to r15 / LDM^ with r15.
  if bank_of(cpu.cpsr) != 0: cpu.set_cpsr(cpu.spsr)

# ---------------------------------------------------------------------------
# Condition codes, shifter, ALU helpers

proc cond_passed(cpu: ArmCpu; cond: uint32): bool {.inline.} =
  let n = cpu.flag(FLAG_N)
  let z = cpu.flag(FLAG_Z)
  let c = cpu.flag(FLAG_C)
  let v = cpu.flag(FLAG_V)
  case cond
  of 0x0: z
  of 0x1: not z
  of 0x2: c
  of 0x3: not c
  of 0x4: n
  of 0x5: not n
  of 0x6: v
  of 0x7: not v
  of 0x8: c and not z
  of 0x9: (not c) or z
  of 0xA: n == v
  of 0xB: n != v
  of 0xC: (not z) and (n == v)
  of 0xD: z or (n != v)
  of 0xE: true
  else: false

template set_nz(cpu: ArmCpu; res: uint32) =
  cpu.cpsr = (cpu.cpsr and not (FLAG_N or FLAG_Z)) or (res and FLAG_N) or
             (if res == 0: FLAG_Z else: 0'u32)

template set_c(cpu: ArmCpu; c: bool) =
  cpu.cpsr = if c: cpu.cpsr or FLAG_C else: cpu.cpsr and not FLAG_C

template set_v(cpu: ArmCpu; v: bool) =
  cpu.cpsr = if v: cpu.cpsr or FLAG_V else: cpu.cpsr and not FLAG_V

proc add_flags(cpu: ArmCpu; a, b: uint32; carry_in: uint32; s: bool): uint32 {.inline.} =
  let wide = uint64(a) + uint64(b) + uint64(carry_in)
  result = uint32(wide)
  if s:
    cpu.set_nz(result)
    cpu.set_c(wide > 0xFFFF_FFFF'u64)
    cpu.set_v(((a xor result) and (b xor result) and 0x8000_0000'u32) != 0)

proc sub_flags(cpu: ArmCpu; a, b: uint32; carry_in: uint32; s: bool): uint32 {.inline.} =
  ## a - b - (1 - carry_in); carry = no borrow
  let wide = uint64(a) + uint64(not b) + uint64(carry_in)
  result = uint32(wide)
  if s:
    cpu.set_nz(result)
    cpu.set_c(wide > 0xFFFF_FFFF'u64)
    cpu.set_v(((a xor b) and (a xor result) and 0x8000_0000'u32) != 0)

proc shift_value(cpu: ArmCpu; kind: uint32; value: uint32; amount: uint32;
                 by_reg: bool; carry: var bool): uint32 {.inline.} =
  ## The barrel shifter. `by_reg` = amount from a register (only the low byte
  ## counts, 0 = no shift); otherwise the 5-bit immediate with its 0 cases.
  case kind
  of 0: # LSL
    if amount == 0: return value
    if amount < 32:
      carry = ((value shr (32 - amount)) and 1) != 0
      return value shl amount
    carry = if amount == 32: (value and 1) != 0 else: false
    return 0
  of 1: # LSR
    var amt = amount
    if amt == 0:
      if by_reg: return value
      amt = 32
    if amt < 32:
      carry = ((value shr (amt - 1)) and 1) != 0
      return value shr amt
    carry = if amt == 32: (value shr 31) != 0 else: false
    return 0
  of 2: # ASR
    var amt = amount
    if amt == 0:
      if by_reg: return value
      amt = 32
    if amt < 32:
      carry = ((value shr (amt - 1)) and 1) != 0
      return uint32(cast[int32](value) shr amt)
    carry = (value shr 31) != 0
    return if carry: 0xFFFF_FFFF'u32 else: 0
  else: # ROR / RRX
    if amount == 0:
      if by_reg: return value
      let c = (value and 1) != 0
      result = (value shr 1) or (if cpu.flag(FLAG_C): 0x8000_0000'u32 else: 0)
      carry = c
      return
    let amt = amount and 31
    if amt == 0:
      carry = (value shr 31) != 0
      return value
    result = rotateRightBits(value, amt)
    carry = (result shr 31) != 0

proc reg_pc12(cpu: ArmCpu; idx: int): uint32 {.inline.} =
  ## A register operand read during a register-specified shift: r15 reads +12.
  if idx == 15: cpu.cur_pc + 12 else: cpu.r[idx]

# ---------------------------------------------------------------------------
# ARM instructions

proc arm_data_processing[B](cpu: ArmCpu[B]; instr: uint32) =
  let opcode = (instr shr 21) and 0xF
  let s = (instr and (1'u32 shl 20)) != 0
  let rn = int((instr shr 16) and 0xF)
  let rd = int((instr shr 12) and 0xF)
  var carry = cpu.flag(FLAG_C)
  var op2: uint32
  var op1: uint32
  if (instr and (1'u32 shl 25)) != 0:
    let rot = ((instr shr 8) and 0xF) * 2
    op2 = rotateRightBits(instr and 0xFF, rot)
    if rot != 0: carry = (op2 shr 31) != 0
    op1 = cpu.r[rn]
  else:
    let rm = int(instr and 0xF)
    let kind = (instr shr 5) and 3
    if (instr and 0x10) != 0:
      inc cpu.icycles
      let amount = cpu.reg_pc12(int((instr shr 8) and 0xF)) and 0xFF
      op2 = cpu.shift_value(kind, cpu.reg_pc12(rm), amount, true, carry)
      op1 = cpu.reg_pc12(rn)
    else:
      op2 = cpu.shift_value(kind, cpu.r[rm], (instr shr 7) and 0x1F, false, carry)
      op1 = cpu.r[rn]
  let cin = if cpu.flag(FLAG_C): 1'u32 else: 0'u32
  var res: uint32
  var write = true
  var logical = false
  case opcode
  of 0x0: res = op1 and op2; logical = true
  of 0x1: res = op1 xor op2; logical = true
  of 0x2: res = cpu.sub_flags(op1, op2, 1, s and rd != 15)
  of 0x3: res = cpu.sub_flags(op2, op1, 1, s and rd != 15)
  of 0x4: res = cpu.add_flags(op1, op2, 0, s and rd != 15)
  of 0x5: res = cpu.add_flags(op1, op2, cin, s and rd != 15)
  of 0x6: res = cpu.sub_flags(op1, op2, cin, s and rd != 15)
  of 0x7: res = cpu.sub_flags(op2, op1, cin, s and rd != 15)
  of 0x8: res = op1 and op2; logical = true; write = false
  of 0x9: res = op1 xor op2; logical = true; write = false
  of 0xA: res = cpu.sub_flags(op1, op2, 1, true); write = false
  of 0xB: res = cpu.add_flags(op1, op2, 0, true); write = false
  of 0xC: res = op1 or op2; logical = true
  of 0xD: res = op2; logical = true
  of 0xE: res = op1 and not op2; logical = true
  else: res = not op2; logical = true
  if s and logical and (rd != 15 or not write):
    cpu.set_nz(res)
    cpu.set_c(carry)
  if write:
    if rd == 15:
      if s: cpu.restore_spsr()
      cpu.jump(res)
    else:
      cpu.r[rd] = res
  elif rd == 15 and s:
    # TSTP/TEQP/CMPP/CMNP: legacy 26-bit forms; restore the PSR anyway
    cpu.restore_spsr()

proc arm_mrs[B](cpu: ArmCpu[B]; instr: uint32) =
  let rd = int((instr shr 12) and 0xF)
  # User and System have no SPSR: reading it gives the CPSR
  cpu.r[rd] = if (instr and (1'u32 shl 22)) != 0 and bank_of(cpu.cpsr) != 0: cpu.spsr
              else: cpu.cpsr

proc arm_msr[B](cpu: ArmCpu[B]; instr: uint32) =
  mixin armv5
  # PSR bits that exist: NZCV, Q on ARMv5, and the control byte; mode bit 4
  # is wired high (no 26-bit modes on either core).
  const psr_bits = when armv5(B): 0xF800_00FF'u32 else: 0xF000_00FF'u32
  var value =
    if (instr and (1'u32 shl 25)) != 0:
      rotateRightBits(instr and 0xFF, ((instr shr 8) and 0xF) * 2)
    else: cpu.r[instr and 0xF]
  value = value or 0x10
  var mask = 0'u32
  if (instr and (1'u32 shl 19)) != 0: mask = mask or 0xFF00_0000'u32
  if (instr and (1'u32 shl 16)) != 0: mask = mask or 0x0000_00FF'u32
  mask = mask and psr_bits
  if (instr and (1'u32 shl 22)) != 0:
    if bank_of(cpu.cpsr) != 0:
      cpu.spsr = (cpu.spsr and not mask) or (value and mask)
  else:
    if cpu.mode == uint32(mUSR): mask = mask and 0xFF00_0000'u32
    mask = mask and not FLAG_T
    cpu.set_cpsr((cpu.cpsr and not mask) or (value and mask))

proc mul_cycles[B](cpu: ArmCpu[B]; rs: uint32; extra: int64) {.inline.} =
  ## ARM7: m cycles by the multiplier's significant bytes (+1 accumulate /
  ## long). ARM9 (no early termination): 1, 2 for the long forms.
  mixin armv5
  when armv5(B):
    cpu.icycles += 1 + min(extra, 1)
  else:
    let m = if (rs and 0xFFFF_FF00'u32) == 0 or (rs and 0xFFFF_FF00'u32) == 0xFFFF_FF00'u32: 1
            elif (rs and 0xFFFF_0000'u32) == 0 or (rs and 0xFFFF_0000'u32) == 0xFFFF_0000'u32: 2
            elif (rs and 0xFF00_0000'u32) == 0 or (rs and 0xFF00_0000'u32) == 0xFF00_0000'u32: 3
            else: 4
    cpu.icycles += m + extra

proc arm_multiply[B](cpu: ArmCpu[B]; instr: uint32) =
  let rd = int((instr shr 16) and 0xF)
  let rn = int((instr shr 12) and 0xF)
  let rs = int((instr shr 8) and 0xF)
  let rm = int(instr and 0xF)
  let s = (instr and (1'u32 shl 20)) != 0
  let acc = (instr shr 21) and 1
  cpu.mul_cycles(cpu.r[rs], int64(acc) + int64((instr shr 23) and 1))
  case (instr shr 21) and 7
  of 0, 1: # MUL / MLA
    var res = cpu.r[rm] * cpu.r[rs]
    if (instr and (1'u32 shl 21)) != 0: res += cpu.r[rn]
    cpu.r[rd] = res
    if s: cpu.set_nz(res)
  of 4, 5, 6, 7: # UMULL UMLAL SMULL SMLAL (rd = hi, rn = lo)
    let signed = (instr and (1'u32 shl 22)) != 0
    var res: uint64 =
      if signed: cast[uint64](int64(cast[int32](cpu.r[rm])) * int64(cast[int32](cpu.r[rs])))
      else: uint64(cpu.r[rm]) * uint64(cpu.r[rs])
    if (instr and (1'u32 shl 21)) != 0:
      res += (uint64(cpu.r[rd]) shl 32) or uint64(cpu.r[rn])
    cpu.r[rn] = uint32(res)
    cpu.r[rd] = uint32(res shr 32)
    if s:
      cpu.cpsr = (cpu.cpsr and not (FLAG_N or FLAG_Z)) or
        (if (res shr 63) != 0: FLAG_N else: 0) or (if res == 0: FLAG_Z else: 0)
  else:
    cpu.undefined_instr()

proc arm_swap[B](cpu: ArmCpu[B]; instr: uint32) =
  mixin read8, read32, write8, write32
  let rn = int((instr shr 16) and 0xF)
  let rd = int((instr shr 12) and 0xF)
  let rm = int(instr and 0xF)
  let a = cpu.r[rn]
  let src = cpu.r[rm]
  inc cpu.icycles
  if (instr and (1'u32 shl 22)) != 0:
    let v = read8(cpu.bus, a)
    write8(cpu.bus, a, uint8(src))
    cpu.r[rd] = v
  else:
    let v = rotateRightBits(read32(cpu.bus, a and not 3'u32), (a and 3) * 8)
    write32(cpu.bus, a and not 3'u32, src)
    cpu.r[rd] = v

proc load_word_rotated[B](cpu: ArmCpu[B]; a: uint32): uint32 {.inline.} =
  mixin read32
  rotateRightBits(read32(cpu.bus, a and not 3'u32), (a and 3) * 8)

proc write_reg_load[B](cpu: ArmCpu[B]; rd: int; v: uint32) {.inline.} =
  ## A load into rd; r15 interworks on ARMv5.
  if rd == 15: cpu.jump_load(v)
  else:
    cpu.r[rd] = v

proc arm_single_transfer[B](cpu: ArmCpu[B]; instr: uint32) =
  mixin read8, write8, write32
  let p = (instr and (1'u32 shl 24)) != 0
  let u = (instr and (1'u32 shl 23)) != 0
  let byt = (instr and (1'u32 shl 22)) != 0
  let w = (instr and (1'u32 shl 21)) != 0
  let load = (instr and (1'u32 shl 20)) != 0
  let rn = int((instr shr 16) and 0xF)
  let rd = int((instr shr 12) and 0xF)
  var offset: uint32
  if (instr and (1'u32 shl 25)) != 0:
    var carry = cpu.flag(FLAG_C)
    offset = cpu.shift_value((instr shr 5) and 3, cpu.r[instr and 0xF],
                             (instr shr 7) and 0x1F, false, carry)
  else:
    offset = instr and 0xFFF
  let base = cpu.r[rn]
  let offset_addr = if u: base + offset else: base - offset
  let a = if p: offset_addr else: base
  if load:
    inc cpu.icycles
    let v = if byt: read8(cpu.bus, a) else: cpu.load_word_rotated(a)
    if (not p or w) and rn != rd: cpu.r[rn] = offset_addr
    cpu.write_reg_load(rd, v)
  else:
    let v = if rd == 15: cpu.cur_pc + 12 else: cpu.r[rd]
    if byt: write8(cpu.bus, a, uint8(v))
    else: write32(cpu.bus, a and not 3'u32, v)
    if not p or w: cpu.r[rn] = offset_addr

proc arm_halfword_transfer[B](cpu: ArmCpu[B]; instr: uint32) =
  mixin read8, read16, read32, write16, write32, armv5
  let p = (instr and (1'u32 shl 24)) != 0
  let u = (instr and (1'u32 shl 23)) != 0
  let w = (instr and (1'u32 shl 21)) != 0
  let load = (instr and (1'u32 shl 20)) != 0
  let rn = int((instr shr 16) and 0xF)
  let rd = int((instr shr 12) and 0xF)
  let sh = (instr shr 5) and 3
  let offset =
    if (instr and (1'u32 shl 22)) != 0: ((instr shr 4) and 0xF0) or (instr and 0xF)
    else: cpu.r[instr and 0xF]
  let base = cpu.r[rn]
  let offset_addr = if u: base + offset else: base - offset
  let a = if p: offset_addr else: base
  let wb = not p or w
  if load:
    inc cpu.icycles
    var v: uint32
    case sh
    of 1:
      when armv5(B): v = read16(cpu.bus, a and not 1'u32)
      else: v = rotateRightBits(read16(cpu.bus, a and not 1'u32), (a and 1) * 8)
    of 2:
      v = uint32(cast[int32](cast[int8](uint8(read8(cpu.bus, a)))))
    else:
      when armv5(B):
        v = uint32(cast[int32](cast[int16](uint16(read16(cpu.bus, a and not 1'u32)))))
      else:
        if (a and 1) != 0: v = uint32(cast[int32](cast[int8](uint8(read8(cpu.bus, a)))))
        else: v = uint32(cast[int32](cast[int16](uint16(read16(cpu.bus, a)))))
    if wb and rn != rd: cpu.r[rn] = offset_addr
    cpu.write_reg_load(rd, v)
  else:
    case sh
    of 1:
      let v = if rd == 15: cpu.cur_pc + 12 else: cpu.r[rd]
      write16(cpu.bus, a and not 1'u32, uint16(v))
      if wb: cpu.r[rn] = offset_addr
    of 2: # LDRD (ARMv5TE)
      when armv5(B):
        if (rd and 1) != 0: cpu.undefined_instr(); return
        let lo = read32(cpu.bus, a and not 3'u32)
        let hi = read32(cpu.bus, (a + 4) and not 3'u32)
        if wb and rn != rd and rn != rd + 1: cpu.r[rn] = offset_addr
        cpu.r[rd] = lo
        cpu.write_reg_load(rd + 1, hi)
      else:
        # ARM7TDMI: no transfer, no exception, but the base is written back
        # (arm7wrestler, hardware-verified)
        if wb: cpu.r[rn] = offset_addr
    else: # STRD
      when armv5(B):
        if (rd and 1) != 0: cpu.undefined_instr(); return
        write32(cpu.bus, a and not 3'u32, cpu.r[rd])
        write32(cpu.bus, (a + 4) and not 3'u32,
                if rd + 1 == 15: cpu.cur_pc + 12 else: cpu.r[rd + 1])
        if wb: cpu.r[rn] = offset_addr
      else:
        if wb: cpu.r[rn] = offset_addr  # as LDRD above

proc arm_block_transfer[B](cpu: ArmCpu[B]; instr: uint32) =
  mixin read32, write32, armv5
  let p = (instr and (1'u32 shl 24)) != 0
  let u = (instr and (1'u32 shl 23)) != 0
  let s = (instr and (1'u32 shl 22)) != 0
  let w = (instr and (1'u32 shl 21)) != 0
  let load = (instr and (1'u32 shl 20)) != 0
  let rn = int((instr shr 16) and 0xF)
  var list = instr and 0xFFFF
  var count = uint32(countSetBits(list))
  let base = cpu.r[rn]
  if list == 0:
    # Empty list: ARMv4 transfers r15 and steps the base by 0x40; ARMv5
    # transfers nothing but still steps the base (GBATEK "ARM Opcodes:
    # Memory: Block Data Transfer").
    when not armv5(B): list = 0x8000
    count = 16
  let start =
    if u: (if p: base + 4 else: base)
    else: (if p: base - count * 4 else: base - count * 4 + 4)
  let new_base = if u: base + count * 4 else: base - count * 4
  let rn_bit = 1'u32 shl rn
  # S without a loaded r15: the user-bank registers are transferred, but the
  # base and its writeback stay in the current mode's bank.
  let user_bank = s and (not load or (list and 0x8000) == 0)
  var old_mode = 0'u32
  if user_bank:
    old_mode = cpu.mode
    cpu.switch_mode(uint32(mUSR))
    cpu.bank_xfer = old_mode != uint32(mUSR)
  var a = start
  if load:
    inc cpu.icycles
    # Rb in the list with writeback: ARMv4 keeps the loaded value; ARMv5
    # writes back if Rb is the only register or not the last one (GBATEK).
    var wb = w
    if (list and rn_bit) != 0:
      when armv5(B): wb = w and (list == rn_bit or (list and not ((rn_bit shl 1) - 1)) != 0)
      else: wb = false
    var pc_val = 0'u32
    for i in 0..15:
      if (list and (1'u32 shl i)) != 0:
        let v = read32(cpu.bus, a and not 3'u32)
        a += 4
        if i == 15: pc_val = v
        else: cpu.r[i] = v
    if user_bank: cpu.switch_mode(old_mode); cpu.bank_xfer = false
    if wb: cpu.r[rn] = new_base
    if (list and 0x8000) != 0:
      if s:
        cpu.restore_spsr()
        cpu.jump(pc_val)
      else:
        cpu.jump_load(pc_val)
  else:
    # ARMv4 stores the new base for Rb not first in the list; ARMv5 always
    # stores the old base.
    let first_bit = list and (not list + 1)
    for i in 0..15:
      if (list and (1'u32 shl i)) != 0:
        var v = if i == 15: cpu.cur_pc + 12 else: cpu.r[i]
        when not armv5(B):
          if i == rn and w and first_bit != rn_bit: v = new_base
        write32(cpu.bus, a and not 3'u32, v)
        a += 4
    if user_bank: cpu.switch_mode(old_mode); cpu.bank_xfer = false
    if w: cpu.r[rn] = new_base

proc arm_branch[B](cpu: ArmCpu[B]; instr: uint32) =
  let offset = uint32(cast[int32](instr shl 8) shr 6)
  if (instr and (1'u32 shl 24)) != 0: cpu.r[14] = cpu.cur_pc + 4
  cpu.jump(cpu.cur_pc + 8 + offset)

proc arm_blx_imm[B](cpu: ArmCpu[B]; instr: uint32) =
  let offset = uint32(cast[int32](instr shl 8) shr 6) or ((instr shr 23) and 2)
  cpu.r[14] = cpu.cur_pc + 4
  cpu.cpsr = cpu.cpsr or FLAG_T
  cpu.next_pc = cpu.cur_pc + 8 + offset

proc arm_bx[B](cpu: ArmCpu[B]; instr: uint32) =
  mixin armv5
  let target = cpu.r[instr and 0xF]
  if (instr and 0x20) != 0: # BLX reg
    when armv5(B): cpu.r[14] = cpu.cur_pc + 4
    else: cpu.undefined_instr(); return
  cpu.jump_interwork(target)

proc arm_clz[B](cpu: ArmCpu[B]; instr: uint32) =
  let v = cpu.r[instr and 0xF]
  cpu.r[(instr shr 12) and 0xF] = if v == 0: 32'u32 else: uint32(countLeadingZeroBits(v))

proc saturate(cpu: ArmCpu; v: int64): uint32 {.inline.} =
  if v > int64(high(int32)):
    cpu.cpsr = cpu.cpsr or FLAG_Q
    return 0x7FFF_FFFF'u32
  if v < int64(low(int32)):
    cpu.cpsr = cpu.cpsr or FLAG_Q
    return 0x8000_0000'u32
  uint32(cast[uint64](v))

proc arm_qarith[B](cpu: ArmCpu[B]; instr: uint32) =
  let rn = int((instr shr 16) and 0xF)
  let rd = int((instr shr 12) and 0xF)
  let rm = int(instr and 0xF)
  let a = int64(cast[int32](cpu.r[rm]))
  var b = int64(cast[int32](cpu.r[rn]))
  let op = (instr shr 21) and 3
  if op >= 2: b = int64(cast[int32](cpu.saturate(b * 2)))
  cpu.r[rd] = if (op and 1) == 0: cpu.saturate(a + b) else: cpu.saturate(a - b)

proc half(v: uint32; top: bool): int64 {.inline.} =
  int64(cast[int16](uint16(if top: v shr 16 else: v)))

proc arm_signed_mul16[B](cpu: ArmCpu[B]; instr: uint32) =
  ## SMLAxy / SMLAWy / SMULWy / SMLALxy / SMULxy (ARMv5TE)
  let rd = int((instr shr 16) and 0xF)
  let rn = int((instr shr 12) and 0xF)
  let rs = int((instr shr 8) and 0xF)
  let rm = int(instr and 0xF)
  let x = (instr and 0x20) != 0
  let y = (instr and 0x40) != 0
  case (instr shr 21) and 3
  of 0: # SMLAxy
    let prod = half(cpu.r[rm], x) * half(cpu.r[rs], y)
    let acc = int64(cast[int32](cpu.r[rn]))
    let sum = prod + acc
    if sum > int64(high(int32)) or sum < int64(low(int32)): cpu.cpsr = cpu.cpsr or FLAG_Q
    cpu.r[rd] = uint32(cast[uint64](sum))
  of 1: # SMLAWy / SMULWy
    let prod = (int64(cast[int32](cpu.r[rm])) * half(cpu.r[rs], y)) shr 16
    if x: # SMULWy
      cpu.r[rd] = uint32(cast[uint64](prod))
    else:
      let sum = prod + int64(cast[int32](cpu.r[rn]))
      if sum > int64(high(int32)) or sum < int64(low(int32)): cpu.cpsr = cpu.cpsr or FLAG_Q
      cpu.r[rd] = uint32(cast[uint64](sum))
  of 2: # SMLALxy (rd = hi, rn = lo)
    let prod = half(cpu.r[rm], x) * half(cpu.r[rs], y)
    let acc = cast[int64]((uint64(cpu.r[rd]) shl 32) or uint64(cpu.r[rn]))
    let res = cast[uint64](acc + prod)
    cpu.r[rn] = uint32(res)
    cpu.r[rd] = uint32(res shr 32)
  else: # SMULxy
    cpu.r[rd] = uint32(cast[uint64](half(cpu.r[rm], x) * half(cpu.r[rs], y)))

proc arm_coproc_transfer[B](cpu: ArmCpu[B]; instr: uint32) =
  mixin armv5, cp15_read, cp15_write
  let cp = (instr shr 8) and 0xF
  when armv5(B):
    if cp == 15:
      let op1 = (instr shr 21) and 7
      let cn = (instr shr 16) and 0xF
      let rd = int((instr shr 12) and 0xF)
      let cm = instr and 0xF
      let op2 = (instr shr 5) and 7
      if (instr and (1'u32 shl 20)) != 0:
        let v = cp15_read(cpu.bus, op1, cn, cm, op2)
        if rd == 15:
          cpu.cpsr = (cpu.cpsr and 0x0FFF_FFFF'u32) or (v and 0xF000_0000'u32)
        else:
          cpu.r[rd] = v
      else:
        cp15_write(cpu.bus, op1, cn, cm, op2,
                   if rd == 15: cpu.cur_pc + 12 else: cpu.r[rd])
      return
  else:
    # ARM7TDMI: CP14 is the EmbeddedICE debug comms channel; with no debugger
    # attached reads are 0 and writes vanish. MRC p14 does not trap on the DS
    # (arm7wrestler); p15 and the rest are undefined.
    if cp == 14:
      if (instr and (1'u32 shl 20)) != 0:
        let rd = int((instr shr 12) and 0xF)
        if rd == 15: cpu.cpsr = cpu.cpsr and 0x0FFF_FFFF'u32
        else: cpu.r[rd] = 0
      return
  cpu.undefined_instr()

proc execute_arm*[B](cpu: ArmCpu[B]; instr: uint32) =
  mixin armv5
  let cond = instr shr 28
  if cond != 0xE and not cpu.cond_passed(cond):
    if cond == 0xF:
      when armv5(B):
        # Unconditional space: BLX imm, PLD (a hint: nothing to do)
        if (instr and 0x0E00_0000'u32) == 0x0A00_0000'u32:
          cpu.arm_blx_imm(instr)
        elif (instr and 0x0D70_F000'u32) == 0x0550_F000'u32:
          discard
        else:
          cpu.undefined_instr()
      else:
        cpu.undefined_instr()
    return
  case (instr shr 25) and 7
  of 0:
    if (instr and 0x0FFF_FFD0'u32) == 0x012F_FF10'u32:
      cpu.arm_bx(instr)
    elif (instr and 0x90) == 0x90:
      # multiplies, swaps, halfword/doubleword transfers
      let sh = (instr shr 5) and 3
      if sh == 0:
        if (instr and 0x0100_0000'u32) != 0: cpu.arm_swap(instr)
        else: cpu.arm_multiply(instr)
      else:
        cpu.arm_halfword_transfer(instr)
    elif (instr and 0x0190_0000'u32) == 0x0100_0000'u32:
      # TST/TEQ/CMP/CMN without S: the miscellaneous instructions
      if (instr and 0xF0) == 0:
        if (instr and 0x0020_0000'u32) != 0: cpu.arm_msr(instr)
        else: cpu.arm_mrs(instr)
      else:
        when armv5(B):
          if (instr and 0x0FFF_0FF0'u32) == 0x016F_0F10'u32: cpu.arm_clz(instr)
          elif (instr and 0x0F90_00F0'u32) == 0x0100_0050'u32: cpu.arm_qarith(instr)
          elif (instr and 0x0FF0_00F0'u32) == 0x0120_0070'u32:
            cpu.exception(mABT, 0x0C, cpu.cur_pc + 4)  # BKPT: prefetch abort
          elif (instr and 0x0F90_0090'u32) == 0x0100_0080'u32: cpu.arm_signed_mul16(instr)
          else: cpu.undefined_instr()
        else:
          # ARM7TDMI: CLZ/Q*/BKPT/BLX (bit 4 set) are undefined, the
          # halfword multiplies (bit 7 set, bit 4 clear) execute as nothing
          # (arm7wrestler, hardware-verified)
          if (instr and 0x10) != 0: cpu.undefined_instr()
    else:
      cpu.arm_data_processing(instr)
  of 1:
    if (instr and 0x0190_0000'u32) == 0x0100_0000'u32:
      if (instr and 0x0020_0000'u32) != 0: cpu.arm_msr(instr)
      else: cpu.undefined_instr()
    else:
      cpu.arm_data_processing(instr)
  of 2: cpu.arm_single_transfer(instr)
  of 3:
    if (instr and 0x10) != 0: cpu.undefined_instr()
    else: cpu.arm_single_transfer(instr)
  of 4: cpu.arm_block_transfer(instr)
  of 5: cpu.arm_branch(instr)
  of 6: cpu.undefined_instr()  # LDC/STC: no coprocessor answers on the DS
  else:
    if (instr and 0x0100_0000'u32) != 0:
      cpu.software_interrupt((instr shr 16) and 0xFF)
    elif (instr and 0x10) != 0:
      cpu.arm_coproc_transfer(instr)
    else:
      cpu.undefined_instr()

# ---------------------------------------------------------------------------
# Thumb instructions

proc execute_thumb*[B](cpu: ArmCpu[B]; instr: uint32) =
  mixin read8, read16, write8, write16, write32, armv5
  let pc4 = cpu.cur_pc + 4
  case instr shr 11
  of 0, 1, 2: # shift by immediate
    let rd = int(instr and 7)
    let rs = int((instr shr 3) and 7)
    var carry = cpu.flag(FLAG_C)
    let res = cpu.shift_value(instr shr 11, cpu.r[rs], (instr shr 6) and 0x1F, false, carry)
    cpu.r[rd] = res
    cpu.set_nz(res)
    cpu.set_c(carry)
  of 3: # add/sub register or imm3
    let rd = int(instr and 7)
    let a = cpu.r[(instr shr 3) and 7]
    let b = if (instr and 0x400) != 0: (instr shr 6) and 7 else: cpu.r[(instr shr 6) and 7]
    cpu.r[rd] = if (instr and 0x200) != 0: cpu.sub_flags(a, b, 1, true)
                else: cpu.add_flags(a, b, 0, true)
  of 4..7: # mov/cmp/add/sub imm8
    let rd = int((instr shr 8) and 7)
    let imm = instr and 0xFF
    case (instr shr 11) and 3
    of 0: cpu.r[rd] = imm; cpu.set_nz(imm)
    of 1: discard cpu.sub_flags(cpu.r[rd], imm, 1, true)
    of 2: cpu.r[rd] = cpu.add_flags(cpu.r[rd], imm, 0, true)
    else: cpu.r[rd] = cpu.sub_flags(cpu.r[rd], imm, 1, true)
  of 8:
    if (instr and 0x400) == 0: # ALU ops
      let rd = int(instr and 7)
      let rs = cpu.r[(instr shr 3) and 7]
      let d = cpu.r[rd]
      let cin = if cpu.flag(FLAG_C): 1'u32 else: 0'u32
      var carry = cpu.flag(FLAG_C)
      case (instr shr 6) and 0xF
      of 0x0: cpu.r[rd] = d and rs; cpu.set_nz(cpu.r[rd])
      of 0x1: cpu.r[rd] = d xor rs; cpu.set_nz(cpu.r[rd])
      of 0x2, 0x3, 0x4, 0x7:
        let kind = case (instr shr 6) and 0xF
                   of 0x2: 0'u32
                   of 0x3: 1'u32
                   of 0x4: 2'u32
                   else: 3'u32
        inc cpu.icycles
        let res = cpu.shift_value(kind, d, rs and 0xFF, true, carry)
        cpu.r[rd] = res
        cpu.set_nz(res)
        cpu.set_c(carry)
      of 0x5: cpu.r[rd] = cpu.add_flags(d, rs, cin, true)
      of 0x6: cpu.r[rd] = cpu.sub_flags(d, rs, cin, true)
      of 0x8: cpu.set_nz(d and rs)
      of 0x9: cpu.r[rd] = cpu.sub_flags(0, rs, 1, true)
      of 0xA: discard cpu.sub_flags(d, rs, 1, true)
      of 0xB: discard cpu.add_flags(d, rs, 0, true)
      of 0xC: cpu.r[rd] = d or rs; cpu.set_nz(cpu.r[rd])
      of 0xD:
        cpu.mul_cycles(d, 0)
        cpu.r[rd] = d * rs; cpu.set_nz(cpu.r[rd])
      of 0xE: cpu.r[rd] = d and not rs; cpu.set_nz(cpu.r[rd])
      else: cpu.r[rd] = not rs; cpu.set_nz(cpu.r[rd])
    else: # hi register ops / BX / BLX
      let rd = int((instr and 7) or ((instr shr 4) and 8))
      let rs = int((instr shr 3) and 0xF)
      let sv = if rs == 15: pc4 else: cpu.r[rs]
      case (instr shr 8) and 3
      of 0:
        let res = (if rd == 15: pc4 else: cpu.r[rd]) + sv
        if rd == 15: cpu.jump(res) else: cpu.r[rd] = res
      of 1:
        discard cpu.sub_flags(if rd == 15: pc4 else: cpu.r[rd], sv, 1, true)
      of 2:
        if rd == 15: cpu.jump(sv) else: cpu.r[rd] = sv
      else:
        if (instr and 0x80) != 0:
          when armv5(B):
            cpu.r[14] = (cpu.cur_pc + 2) or 1
          else:
            cpu.undefined_instr(); return
        cpu.jump_interwork(sv)
  of 9: # LDR pc-relative
    inc cpu.icycles
    let rd = int((instr shr 8) and 7)
    cpu.r[rd] = cpu.load_word_rotated((pc4 and not 3'u32) + (instr and 0xFF) * 4)
  of 10, 11: # load/store register offset
    let rd = int(instr and 7)
    let a = cpu.r[(instr shr 3) and 7] + cpu.r[(instr shr 6) and 7]
    if ((instr shr 9) and 7) >= 3: inc cpu.icycles
    case (instr shr 9) and 7
    of 0: write32(cpu.bus, a and not 3'u32, cpu.r[rd])
    of 1: write16(cpu.bus, a and not 1'u32, uint16(cpu.r[rd]))
    of 2: write8(cpu.bus, a, uint8(cpu.r[rd]))
    of 3: cpu.r[rd] = uint32(cast[int32](cast[int8](uint8(read8(cpu.bus, a)))))
    of 4: cpu.r[rd] = cpu.load_word_rotated(a)
    of 5:
      when armv5(B): cpu.r[rd] = read16(cpu.bus, a and not 1'u32)
      else: cpu.r[rd] = rotateRightBits(read16(cpu.bus, a and not 1'u32), (a and 1) * 8)
    of 6: cpu.r[rd] = read8(cpu.bus, a)
    else:
      when armv5(B):
        cpu.r[rd] = uint32(cast[int32](cast[int16](uint16(read16(cpu.bus, a and not 1'u32)))))
      else:
        if (a and 1) != 0: cpu.r[rd] = uint32(cast[int32](cast[int8](uint8(read8(cpu.bus, a)))))
        else: cpu.r[rd] = uint32(cast[int32](cast[int16](uint16(read16(cpu.bus, a)))))
  of 12..15: # load/store immediate offset
    let rd = int(instr and 7)
    let base = cpu.r[(instr shr 3) and 7]
    let off = (instr shr 6) and 0x1F
    let byt = (instr and 0x1000) != 0
    let a = if byt: base + off else: base + off * 4
    if (instr and 0x800) != 0:
      inc cpu.icycles
      cpu.r[rd] = if byt: read8(cpu.bus, a) else: cpu.load_word_rotated(a)
    else:
      if byt: write8(cpu.bus, a, uint8(cpu.r[rd]))
      else: write32(cpu.bus, a and not 3'u32, cpu.r[rd])
  of 16, 17: # STRH/LDRH imm
    let rd = int(instr and 7)
    let a = cpu.r[(instr shr 3) and 7] + ((instr shr 6) and 0x1F) * 2
    if (instr and 0x800) != 0:
      inc cpu.icycles
      when armv5(B): cpu.r[rd] = read16(cpu.bus, a and not 1'u32)
      else: cpu.r[rd] = rotateRightBits(read16(cpu.bus, a and not 1'u32), (a and 1) * 8)
    else:
      write16(cpu.bus, a and not 1'u32, uint16(cpu.r[rd]))
  of 18, 19: # SP-relative
    let rd = int((instr shr 8) and 7)
    let a = cpu.r[13] + (instr and 0xFF) * 4
    if (instr and 0x800) != 0:
      inc cpu.icycles
      cpu.r[rd] = cpu.load_word_rotated(a)
    else: write32(cpu.bus, a and not 3'u32, cpu.r[rd])
  of 20, 21: # ADD rd, pc/sp, imm
    let rd = int((instr shr 8) and 7)
    cpu.r[rd] = (if (instr and 0x800) != 0: cpu.r[13] else: pc4 and not 3'u32) +
                (instr and 0xFF) * 4
  of 22, 23:
    if (instr and 0x0F00) == 0x0000: # ADD sp, ±imm7
      let off = (instr and 0x7F) * 4
      cpu.r[13] = if (instr and 0x80) != 0: cpu.r[13] - off else: cpu.r[13] + off
    elif (instr and 0x0600) == 0x0400: # PUSH/POP
      mixin read32
      let list = instr and 0xFF
      let r = (instr and 0x100) != 0
      if (instr and 0x800) != 0: # POP
        inc cpu.icycles
        var a = cpu.r[13]
        for i in 0..7:
          if (list and (1'u32 shl i)) != 0:
            cpu.r[i] = read32(cpu.bus, a and not 3'u32); a += 4
        if r:
          cpu.jump_load(read32(cpu.bus, a and not 3'u32)); a += 4
        cpu.r[13] = a
      else:
        let n = uint32(countSetBits(list)) + (if r: 1'u32 else: 0'u32)
        var a = cpu.r[13] - n * 4
        cpu.r[13] = a
        for i in 0..7:
          if (list and (1'u32 shl i)) != 0:
            write32(cpu.bus, a and not 3'u32, cpu.r[i]); a += 4
        if r: write32(cpu.bus, a and not 3'u32, cpu.r[14])
    elif (instr and 0x0F00) == 0x0E00:
      when armv5(B): cpu.exception(mABT, 0x0C, cpu.cur_pc + 4)  # BKPT
      else: cpu.undefined_instr()
    else:
      cpu.undefined_instr()
  of 24, 25: # LDMIA/STMIA
    mixin read32
    let rb = int((instr shr 8) and 7)
    var list = instr and 0xFF
    var a = cpu.r[rb]
    if list == 0:
      when armv5(B):
        cpu.r[rb] = a + 0x40
      else:
        if (instr and 0x800) != 0: cpu.jump(read32(cpu.bus, a and not 3'u32))
        else: write32(cpu.bus, a and not 3'u32, cpu.cur_pc + 6)
        cpu.r[rb] = a + 0x40
      return
    let n = uint32(countSetBits(list))
    if (instr and 0x800) != 0:
      inc cpu.icycles
      for i in 0..7:
        if (list and (1'u32 shl i)) != 0:
          cpu.r[i] = read32(cpu.bus, a and not 3'u32); a += 4
      # no writeback when rb is loaded, ARMv5 included (GBATEK)
      if (list and (1'u32 shl rb)) == 0: cpu.r[rb] = a
    else:
      var first = true
      for i in 0..7:
        if (list and (1'u32 shl i)) != 0:
          var v = cpu.r[i]
          when not armv5(B):
            if i == rb and not first: v = cpu.r[rb] + n * 4
          write32(cpu.bus, a and not 3'u32, v); a += 4
          first = false
      cpu.r[rb] = a
  of 26, 27: # conditional branch / SWI
    let cond = (instr shr 8) and 0xF
    if cond == 0xF:
      cpu.software_interrupt(instr and 0xFF)
    elif cond == 0xE:
      cpu.undefined_instr()
    elif cpu.cond_passed(cond):
      cpu.jump(pc4 + uint32(cast[int32](cast[int8](uint8(instr and 0xFF))) * 2))
  of 28: # B
    cpu.jump(pc4 + uint32((cast[int32](instr shl 21)) shr 20))
  of 29: # BLX suffix (ARMv5)
    when armv5(B):
      if (instr and 1) != 0: cpu.undefined_instr(); return
      let target = (cpu.r[14] + (instr and 0x7FF) * 2) and not 3'u32
      cpu.r[14] = (cpu.cur_pc + 2) or 1
      cpu.cpsr = cpu.cpsr and not FLAG_T
      cpu.next_pc = target
    else:
      cpu.undefined_instr()
  of 30: # BL prefix
    cpu.r[14] = pc4 + uint32((cast[int32](instr shl 21)) shr 9)
  else: # BL suffix
    let target = cpu.r[14] + (instr and 0x7FF) * 2
    cpu.r[14] = (cpu.cur_pc + 2) or 1
    cpu.jump(target)

# ---------------------------------------------------------------------------
# Run loop

proc trace_instr(cpu: ArmCpu; instr: uint32) {.noinline.} =
  dec cpu.trace
  var line = toHex(cpu.cur_pc, 8) & ": " &
             (if cpu.thumb: "    " & toHex(instr, 4) else: toHex(instr, 8))
  for i in 0..14: line.add(" " & toHex(cpu.r[i], 8))
  line.add(" " & toHex(cpu.cpsr, 8))
  stderr.writeLine(line)

proc take_abort[B](cpu: ArmCpu[B]; a: uint32) {.noinline.} =
  ## ARM946E-S aborts (protection unit, GBATEK "ARM CP15 Protection Unit"):
  ## a refused fetch takes the prefetch abort instead of running the opcode
  ## (lr = opcode + 4), a refused data access the data abort after it
  ## (lr = opcode + 8, in both states: the ARM ARM's exception table). The
  ## refused access itself did nothing; a base register the aborted opcode
  ## wrote back stays written (the ARM9's base-restored model is not
  ## modelled).
  cpu.count_exc()
  if cpu.abort == ABORT_PREFETCH: cpu.exception(mABT, 0x0C, a + 4)
  else: cpu.exception(mABT, 0x10, a + 8)
  cpu.abort = 0

proc step*[B](cpu: ArmCpu[B]) {.inline.} =
  mixin fetch16, fetch32, irq_line, access_cycles, armv5
  if irq_line(cpu.bus) and (cpu.cpsr and FLAG_I) == 0:
    cpu.exception(mIRQ, 0x18, cpu.next_pc + 4)
  let a = cpu.next_pc
  cpu.cur_pc = a
  when defined(ndsdebug):
    if cpu.profiling: cpu.profile.inc(a and not 63'u32)
  if cpu.thumb:
    let instr = fetch16(cpu.bus, a)
    if unlikely(cpu.trace > 0): cpu.trace_instr(instr)
    cpu.next_pc = a + 2
    cpu.r[15] = a + 4
    when armv5(B):
      if likely(cpu.abort == 0): cpu.execute_thumb(instr)
    else: cpu.execute_thumb(instr)
  else:
    let instr = fetch32(cpu.bus, a)
    if unlikely(cpu.trace > 0): cpu.trace_instr(instr)
    cpu.next_pc = a + 4
    cpu.r[15] = a + 8
    when armv5(B):
      if likely(cpu.abort == 0): cpu.execute_arm(instr)
    else: cpu.execute_arm(instr)
  when armv5(B):
    if unlikely(cpu.abort != 0): cpu.take_abort(a)
  inc cpu.instr_count
  # an ARM7 cycle is two master cycles, an ARM9 cycle one
  let ic = when armv5(B): cpu.icycles else: cpu.icycles * 2
  cpu.icycles = 0
  let spent = cpu.base_cycles + access_cycles(cpu.bus) + ic
  cpu.cycles += spent
  when defined(ndsdebug):
    if cpu.profiling: cpu.cprofile.inc(a and not 63'u32, int(spent))

# ---------------------------------------------------------------------------
# Idle-loop skipping
#
# A program that waits by spinning (polling VCOUNT, an IPC flag, a word the
# other CPU writes, or `B .`) repeats the same passes of a loop, with
# nothing changing until something outside the CPU does: an event, the other
# CPU, a frontend call. The bus keeps `idle_epoch`, bumped by anything a
# loop could see change: a store that changes memory, any I/O or VRAM store,
# a read with a side effect or a time-dependent value, a cache line fill, an
# event, a frontend call; the CPU adds its own count of exceptions, mode
# switches and SWIs. Backward branches land on loop heads; one head at a
# time is watched. When the CPU is back at it with the epoch untouched since
# an earlier visit and registers, CPSR/SPSR and the bus's timing state
# (idle_sig) as they were then, the stretch between the two visits read the
# same values, cost the same cycles and ended where it began: it repeats
# exactly until something outside changes. Inside one `run` nothing outside
# runs, so the whole repeats that fit before `until` are counted instead of
# executed: the clock and the opcode count advance by whole repeats, exactly
# as executing them would. The GBA core's waitloop skipping follows the same
# rule: output with skipping on must equal output with it off, byte for
# byte (docs/nds/perf.md).
#
# The repeat may hold inner loops and calls (scanKeys in a keysDown wait):
# other backward branches do not move the watched head unless it stops being
# visited, and an arrival is compared with a snapshot kept for up to
# WL_TRIES arrivals, not only with the previous one. `wl_idle` tells the
# machine loop the CPU is in such a repeat (nds.nim `quiet`), so it need not
# interleave the CPUs finely while nothing changes.

const
  WL_OTHER = 32     ## arrivals at other heads before the watched one is given up
  WL_TRIES = 32     ## arrivals compared with one snapshot before a new one is taken
  WL_FAILS = 16     ## visits in a row finding work before the CPU stops watching
  WL_COLD = 256     ## for this many backward branches, doubling each time it
  WL_COLD_MAX = 8192  ## stops again without having found a loop to skip (code
                    ## that works, not waits, then rarely pays for a call)

proc cool_down[B](cpu: ArmCpu[B]) {.inline.} =
  inc cpu.wl_fails
  if cpu.wl_fails >= WL_FAILS:
    cpu.wl_fails = 0
    cpu.wl_cold_len = clamp(cpu.wl_cold_len * 2, WL_COLD, WL_COLD_MAX)
    cpu.wl_cold = cpu.wl_cold_len
    cpu.wl_have = false

proc loop_edge*[B](cpu: ArmCpu[B]) {.noinline.} =
  ## Called by the bus as it fetches the target of a backward branch (the
  ## loop head), before the fetch changes its timing state. The opcode at
  ## `cur_pc` has passed the run loop's clock check and the interrupt
  ## check, so whole repeats are skipped only while it would still start
  ## before `wl_until`.
  mixin idle_epoch, idle_sig
  let head = cpu.cur_pc
  if head != cpu.wl_head:
    inc cpu.wl_other
    if cpu.wl_other < WL_OTHER and cpu.trace == 0: return
    # the watched head is no longer visited: watch this one
    cpu.wl_head = head
    cpu.wl_other = 0
    cpu.wl_epoch = idle_epoch(cpu.bus) + cpu.wl_bump
    cpu.wl_have = false
    cpu.wl_idle = false
    cpu.cool_down()
    return
  cpu.wl_other = 0
  let epoch = idle_epoch(cpu.bus) + cpu.wl_bump
  if epoch != cpu.wl_epoch or cpu.trace > 0:
    # something was touched since the last visit: start over from here
    cpu.wl_epoch = epoch
    cpu.wl_have = false
    cpu.wl_idle = false
    cpu.cool_down()
    return
  let sig = idle_sig(cpu.bus)
  if cpu.wl_have and cpu.wl_tries < WL_TRIES:
    var same = cpu.cpsr == cpu.wl_cpsr and cpu.spsr == cpu.wl_spsr and sig == cpu.wl_sig
    if same:
      for i in 0..14:
        if cpu.r[i] != cpu.wl_regs[i]: same = false; break
    if not same:
      inc cpu.wl_tries
      cpu.wl_idle = false
      cpu.cool_down()
      return
    # back where the snapshot was taken, nothing touched: skip the whole
    # repeats that fit
    cpu.wl_idle = true
    cpu.wl_fails = 0
    cpu.wl_cold_len = 0
    let period = cpu.cycles - cpu.wl_cycles
    if period > 0:
      let k = (cpu.wl_until - 1 - cpu.cycles) div period
      if k > 0:
        cpu.instr_count += uint64(k) * (cpu.instr_count - cpu.wl_instrs)
        cpu.cycles += k * period
        cpu.wl_skipped += k * period
  else:
    # no snapshot since the last touch (or it never came round again): take one
    for i in 0..14: cpu.wl_regs[i] = cpu.r[i]
    cpu.wl_cpsr = cpu.cpsr
    cpu.wl_spsr = cpu.spsr
    cpu.wl_sig = sig
    cpu.wl_have = true
    cpu.wl_tries = 0
    cpu.wl_idle = false
  cpu.wl_cycles = cpu.cycles
  cpu.wl_instrs = cpu.instr_count

proc idle_now*[B](cpu: ArmCpu[B]): bool {.inline.} =
  ## In a loop whose last pass was a no-op, with nothing touched since.
  mixin idle_epoch
  cpu.wl_idle and idle_epoch(cpu.bus) + cpu.wl_bump == cpu.wl_epoch

proc run*[B](cpu: ArmCpu[B]; until: int64) =
  ## Execute until the CPU's clock reaches `until` (master cycles).
  mixin irq_wake
  cpu.wl_until = until
  while cpu.cycles < until:
    if cpu.halted:
      if irq_wake(cpu.bus):
        cpu.halted = false
      else:
        cpu.cycles = until
        return
    cpu.step()

proc reg_dump*(cpu: ArmCpu): string =
  for i in 0..15:
    result.add("r" & $i & "=" & toHex(if i == 15: cpu.next_pc else: cpu.r[i], 8) & " ")
  result.add("cpsr=" & toHex(cpu.cpsr, 8))

