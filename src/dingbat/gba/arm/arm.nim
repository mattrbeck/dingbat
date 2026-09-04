# ARM instruction handlers (included by gba.nim)

proc exception_return_restore*(cpu: CPU) =
  ## CPSR <- SPSR after an instruction that loaded r15 with the S bit set
  ## (subs pc, lr, #4 / ldmfd sp!, {..., pc}^). Assumes set_reg(15) already
  ## ran, so the pipeline offset is corrected when returning to thumb.
  # IRQ return gives back the one cycle cpu.irq over-charged beyond an even
  # split of the data sheet's 2S+1N entry + 2S+1N return, except when the
  # return refills from the gamepak, where restarting the ROM fetch stream
  # costs it (hardware: gbaedge IRQLAT2 on AGB SP, docs/hwprobe.md). SWI
  # entry/return splits evenly (mGBA suite BIOS timing rows).
  if cast[CpuMode](cpu.cpsr.mode) == modeIRQ and
     int(bits_range(cpu.r[15], 24, 27)) notin 8..13:
    cpu.gba.bus.add_cycles(-1)
  if cpu.spsr.thumb:
    cpu.r[15] -= 4
    # set_reg(15) refilled at ARM width; a Thumb return refills with two
    # halfword fetches, so charge the difference.
    let page = int(bits_range(cpu.r[15], 24, 27))
    cpu.gba.bus.add_cycles(2 * (int(cpu.gba.bus.wait16_s[page]) -
                                int(cpu.gba.bus.wait32_s[page])))
  let old_spsr = uint32(cpu.spsr)
  let was_irq_disabled = cpu.cpsr.irq_disable
  let new_mode = cast[CpuMode](cpu.spsr.mode)
  cpu.switch_mode(new_mode)
  cpu.cpsr = cast[PSR](old_spsr)
  let bank = mode_bank(new_mode)
  cpu.spsr = cast[PSR](if bank in {0, UNDEF_BANK}: uint32(cpu.cpsr)
                       else: cpu.spsr_banks[bank])
  if was_irq_disabled and not cpu.cpsr.irq_disable:
    # No IRQ_GATE_DELAY on an exception return's SPSR restore (mGBA suite
    # multi-IRQ Timer count-up rows); the gate evidence covers IME/IE/msr.
    cpu.gba.interrupts.schedule_interrupt_check()

proc arm_unimplemented*(cpu: CPU; instr: uint32) =
  # und() writes PC; no step.
  cpu.und()

proc arm_unused*(cpu: CPU; instr: uint32) =
  cpu.und()

proc rotate_register*(cpu: CPU; instr: uint32; carry_out: ptr bool; allow_register_shifts: bool): uint32 =
  let reg        = int(bits_range(instr, 0, 3))
  let shift_type = int(bits_range(instr, 5, 6))
  let immediate  = not (allow_register_shifts and bit(instr, 4))
  var shift_amount: uint32
  if immediate:
    shift_amount = bits_range(instr, 7, 11)
  else:
    let shift_register = int(bits_range(instr, 8, 11))
    shift_amount = cpu.r[shift_register] and 0xFF'u32
  case shift_type
  of 0b00: cpu.lsl(cpu.r[reg], shift_amount, carry_out)
  of 0b01: cpu.lsr(cpu.r[reg], shift_amount, immediate, carry_out)
  of 0b10: cpu.asr(cpu.r[reg], shift_amount, immediate, carry_out)
  of 0b11: cpu.ror(cpu.r[reg], shift_amount, immediate, carry_out)
  else: raise newException(Exception, "Impossible shift type: " & hex_str(uint8(shift_type)))

proc immediate_offset*(cpu: CPU; instr: uint32; carry_out: ptr bool): uint32 =
  let rotate = bits_range(instr, 8, 11)
  let imm    = bits_range(instr, 0, 7)
  cpu.ror(imm, rotate shl 1, false, carry_out)

type ArmAluOp* = enum
  AND, EOR, SUB, RSB,
  ADD, ADC, SBC, RSC,
  TST, TEQ, CMP, CMN,
  ORR, MOV, BIC, MVN

# ARM7TDMI Booth-multiplier carry model. The "meaningless" C flag after
# MULS/MLAS/UMULLS/UMLALS/SMULLS/SMLALS is deterministic: radix-4 Booth
# recoding + carry-save adders with early termination. Port of
# zaydlang/multiplication-algorithm (zlib license, fuzzed against ARM7TDMI
# silicon); pinned by the gbaedge MULFLAGS rows on AGB SP (docs/hwprobe.md).
# Only the carry is computed here, so the original's final full-adder stage
# is omitted: an altered version of the original, per clause 2 below.
#
# Copyright (c) 2024 zaydlang
#
# This software is provided 'as-is', without any express or implied warranty.
# In no event will the authors be held liable for any damages arising from the
# use of this software.
#
# Permission is granted to anyone to use this software for any purpose,
# including commercial applications, and to alter it and redistribute it
# freely, subject to the following restrictions:
#
#     1. The origin of this software must not be misrepresented; you must not
#        claim that you wrote the original software. If you use this software
#        in a product, an acknowledgment in the product documentation would be
#        appreciated but is not required.
#     2. Altered source versions must be plainly marked as such, and must not
#        be misrepresented as being the original software.
#     3. This notice may not be removed or altered from any source
#        distribution.

type
  MulFlavor* = enum mfShort, mfLongSigned, mfLongUnsigned
  MulCsa = object
    output, carry: uint64
  MulU128 = object
    lo, hi: uint64

proc mul_mask(lo, hi: int): uint64 {.inline.} =
  ((1'u64 shl (hi - lo)) - 1) shl lo

proc mul_sext(value: uint64; from_size, to_size: int): uint64 {.inline.} =
  if bit(value, from_size - 1): value or mul_mask(from_size, to_size)
  else: value

proc mul_asr(value: uint64; shift, size: int): uint64 {.inline.} =
  uint64(cast[int64](mul_sext(value, size, 64)) shr shift) and mul_mask(0, size)

proc mul_ror128(input: MulU128; shift: int): MulU128 {.inline.} =
  MulU128(lo: (input.lo shr shift) or (input.hi shl (64 - shift)),
          hi: (input.hi shr shift) or (input.lo shl (64 - shift)))

proc booth_recode(input: uint64; chunk: uint32): (uint64, uint64) {.inline.} =
  ## -> (recoded addend masked to 34 bits, booth carry)
  case chunk
  of 1, 2: ((input) and 0x3FFFFFFFF'u64, 0'u64)
  of 3:    ((2'u64 * input) and 0x3FFFFFFFF'u64, 0'u64)
  of 4:    ((not (2'u64 * input)) and 0x3FFFFFFFF'u64, 1'u64)
  of 5, 6: ((not input) and 0x3FFFFFFFF'u64, 1'u64)
  else:    (0'u64, 0'u64)  # 0 and 7

proc mul_booth_carry*(flavor: MulFlavor; multiplicand32, multiplier32: uint32;
                      accumulator: uint64): bool =
  let signed = flavor in {mfShort, mfLongSigned}
  var multiplier =
    if signed: mul_sext(uint64(multiplier32), 32, 34)
    else:      uint64(multiplier32) and 0x1FFFFFFFF'u64
  let multiplicand =
    if signed: mul_sext(uint64(multiplicand32), 32, 34)
    else:      uint64(multiplicand32) and 0x1FFFFFFFF'u64

  var csa = MulCsa(
    output: accumulator,
    carry: (if bit(multiplier, 0): not multiplicand else: 0'u64))
  var acc_shift_register = accumulator shr 34

  var partial_sum   = MulU128(lo: csa.output and 1)
  var partial_carry = MulU128(lo: csa.carry and 1)
  csa.output = csa.output shr 1
  csa.carry  = csa.carry shr 1
  partial_sum   = mul_ror128(partial_sum, 1)
  partial_carry = mul_ror128(partial_carry, 1)

  var iterations = 0
  while true:
    # One multiplier cycle: 4 radix-4 booth chunks through the CSA array
    var chunk_csa = csa
    var cycle = MulCsa()
    for i in 0 ..< 4:
      chunk_csa.output = chunk_csa.output and 0x1FFFFFFFF'u64
      chunk_csa.carry  = chunk_csa.carry and 0x1FFFFFFFF'u64
      let (addend, booth_c) =
        booth_recode(multiplicand, uint32((multiplier shr (2 * i)) and 0b111))
      var res = MulCsa(
        output: chunk_csa.output xor (addend and 0x1FFFFFFFF'u64) xor chunk_csa.carry,
        carry: (chunk_csa.output and (addend and 0x1FFFFFFFF'u64)) or
               ((addend and 0x1FFFFFFFF'u64) and chunk_csa.carry) or
               (chunk_csa.carry and chunk_csa.output))
      res.carry = (res.carry shl 1) or booth_c
      cycle.output = cycle.output or ((res.output and 3) shl (2 * i))
      cycle.carry  = cycle.carry or ((res.carry and 3) shl (2 * i))
      res.output = res.output shr 2
      res.carry  = res.carry shr 2
      # TransH/High handling: acc_shift_register holds the upper acc bits
      let magic = uint64(bit(acc_shift_register, 0)) +
                  uint64(not bit(chunk_csa.carry, 32)) +
                  uint64(not bit(addend, 33))
      res.output = res.output or (magic shl 31)
      res.carry  = res.carry or (uint64(not bit(acc_shift_register, 1)) shl 32)
      acc_shift_register = acc_shift_register shr 2
      chunk_csa = res
    cycle.output = cycle.output or (chunk_csa.output shl 8)
    cycle.carry  = cycle.carry or (chunk_csa.carry shl 8)
    csa = cycle

    partial_sum.lo   = partial_sum.lo or (csa.output and 0xFF)
    partial_carry.lo = partial_carry.lo or (csa.carry and 0xFF)
    csa.output = csa.output shr 8
    csa.carry  = csa.carry shr 8
    partial_sum   = mul_ror128(partial_sum, 8)
    partial_carry = mul_ror128(partial_carry, 8)
    multiplier = mul_asr(multiplier, 8, 33)
    inc iterations
    # Early termination on an exhausted (or all-ones, if signed) multiplier
    if signed:
      if multiplier == 0x1FFFFFFFF'u64 or multiplier == 0: break
    else:
      if multiplier == 0: break

  partial_sum.lo   = partial_sum.lo or csa.output
  partial_carry.lo = partial_carry.lo or csa.carry

  const CORRECTION_ROR = [23, 15, 7, 31]
  partial_carry = mul_ror128(partial_carry, CORRECTION_ROR[iterations - 1])

  if flavor == mfShort and iterations == 4:
    bit(partial_carry.hi, 31)
  else:
    bit(partial_carry.hi, 63)

proc arm_multiply*[accumulate, set_cond: static bool](cpu: CPU; instr: uint32) =
  let rd  = int(bits_range(instr, 16, 19))
  let rn {.used.} = int(bits_range(instr, 12, 15))  # unread unless `accumulate`
  let rs  = int(bits_range(instr, 8, 11))
  let rm  = int(bits_range(instr, 0, 3))
  let acc = when accumulate: cpu.r[rn] else: 0'u32
  cpu.idle(mul_i_cycles(cpu.r[rs], true) + (when accumulate: 1 else: 0))
  when set_cond:
    cpu.cpsr.carry = mul_booth_carry(mfShort, cpu.r[rm], cpu.r[rs], uint64(acc))
  discard cpu.set_reg(rd, cpu.r[rm] * cpu.r[rs] + acc)
  when set_cond: cpu.set_neg_and_zero_flags(cpu.r[rd])
  if rd != 15: cpu.step_arm()

proc arm_multiply_long*[signed, accumulate, set_cond: static bool](cpu: CPU; instr: uint32) =
  let rdhi = int(bits_range(instr, 16, 19))
  let rdlo = int(bits_range(instr, 12, 15))
  let rs   = int(bits_range(instr, 8, 11))
  let rm   = int(bits_range(instr, 0, 3))
  let rm_val = cpu.r[rm]
  let rs_val = cpu.r[rs]
  let acc {.used.} =  # unread unless `accumulate`/`set_cond`
    when accumulate: (uint64(cpu.r[rdhi]) shl 32) or uint64(cpu.r[rdlo])
    else: 0'u64
  var res: uint64 =
    when signed:
      cast[uint64](int64(cast[int32](rm_val)) * int64(cast[int32](rs_val)))
    else:
      uint64(rm_val) * uint64(rs_val)
  cpu.idle(mul_i_cycles(rs_val, signed) + (when accumulate: 2 else: 1))
  when accumulate:
    res += acc
  discard cpu.set_reg(rdhi, uint32(res shr 32))
  discard cpu.set_reg(rdlo, uint32(res))
  when set_cond:
    cpu.cpsr.negative = bit(cpu.r[rdhi], 31)
    cpu.cpsr.zero     = (res == 0)
    cpu.cpsr.carry = mul_booth_carry(
      (when signed: mfLongSigned else: mfLongUnsigned), rm_val, rs_val, acc)
  if rdhi != 15 and rdlo != 15: cpu.step_arm()

proc arm_single_data_swap*[byte_quantity: static bool](cpu: CPU; instr: uint32) =
  let rn = int(bits_range(instr, 16, 19))
  let rd = int(bits_range(instr, 12, 15))
  let rm = int(bits_range(instr, 0, 3))
  when byte_quantity:
    let tmp = cpu.gba.bus[cpu.r[rn]]
    cpu.gba.bus[cpu.r[rn]] = uint8(cpu.r[rm])
    discard cpu.set_reg(rd, uint32(tmp))
  else:
    let tmp = cpu.gba.bus.read_word_rotate(cpu.r[rn])
    cpu.gba.bus.write_word(cpu.r[rn], cpu.r[rm])
    discard cpu.set_reg(rd, tmp)
  cpu.idle(1)
  if rd != 15: cpu.step_arm()

proc arm_halfword_data_transfer*[pre, add, immediate, write_back, load: static bool,
                                  sh: static uint32](cpu: CPU; instr: uint32) =
  let rn     = int(bits_range(instr, 16, 19))
  let rd     = int(bits_range(instr, 12, 15))
  let offset =
    when immediate:
      (bits_range(instr, 8, 11) shl 4) or bits_range(instr, 0, 3)
    else:
      cpu.r[int(bits_range(instr, 0, 3))]
  var address = cpu.r[rn]
  when pre:
    when add: address += offset
    else:     address -= offset
  when sh == 0b00:
    raise newException(Exception, "HalfwordDataTransfer sh=00: " & hex_str(instr))
  elif sh == 0b01:  # ldrh/strh
    when load:
      let value = cpu.gba.bus.read_half_rotate(address)
      cpu.idle(1)
      discard cpu.set_reg(rd, value)
    else:
      cpu.gba.bus.write_half(address, uint16(cpu.r[rd] and 0xFFFF'u32))
      if rd == 15:
        cpu.gba.bus.write_half(address, uint16(cpu.gba.bus.read_half(address)) + 4)
  elif sh == 0b10:  # ldrsb
    let value = uint32(cast[int32](cast[int8](cpu.gba.bus[address])))
    cpu.idle(1)
    discard cpu.set_reg(rd, value)
  else:  # sh == 0b11, ldrsh
    let value = cpu.gba.bus.read_half_signed(address)
    cpu.idle(1)
    discard cpu.set_reg(rd, value)
  when not pre:
    when add: address += offset
    else:     address -= offset
  when write_back or not pre:
    if rd != rn or not load:
      discard cpu.set_reg(rn, address)
  if not (load and rd == 15): cpu.step_arm()

proc arm_single_data_transfer*[imm_flag, pre_addressing, add_offset, byte_quantity,
                                 write_back, load, bit0: static bool](cpu: CPU; instr: uint32) =
  var carry_out {.used.} = false  # written only in the `imm_flag` instantiations
  let rn = int(bits_range(instr, 16, 19))
  let rd = int(bits_range(instr, 12, 15))
  let offset =
    when imm_flag:
      cpu.rotate_register(bits_range(instr, 0, 11), addr carry_out, allow_register_shifts = false)
    else:
      bits_range(instr, 0, 11)
  var address = cpu.r[rn]
  when pre_addressing:
    when add_offset: address += offset
    else:            address -= offset
  # Base writeback with rn=15 (architecturally UNPREDICTABLE): `str r1,
  # [r15], #4` writes PC := base+4, `ldr r1, [r15], #4` writes PC := base+8
  # and suppresses the load while the bus read still happens (hardware:
  # gbaedge THUMBPC2 on AGB SP, probed at offset 4 only; docs/hwprobe.md).
  const pc_writeback = write_back or not pre_addressing
  when load:
    let value =
      when byte_quantity:
        uint32(cpu.gba.bus[address])
      else:
        cpu.gba.bus.read_word_rotate(address)
    cpu.idle(1)
    when pc_writeback:
      if rn != 15:
        discard cpu.set_reg(rd, value)
    else:
      discard cpu.set_reg(rd, value)
  else:
    when byte_quantity:
      cpu.gba.bus[address] = uint8(cpu.r[rd])
    else:
      cpu.gba.bus.write_word(address, cpu.r[rd])
    if rd == 15:
      cpu.gba.bus.write_word(address, cpu.gba.bus.read_word(address) + 4)
  when not pre_addressing:
    when add_offset: address += offset
    else:            address -= offset
  when pc_writeback:
    if rn == 15:
      discard cpu.set_reg(15, when load: address + 4 else: address)
      return
    if rd != rn or not load:
      discard cpu.set_reg(rn, address)
  if not (load and rd == 15): cpu.step_arm()

proc arm_block_data_transfer*[pre_address, add, s_bit, write_back, load: static bool](cpu: CPU; instr: uint32) =
  let rn = int(bits_range(instr, 16, 19))
  var list = bits_range(instr, 0, 15)
  when s_bit:
    var saved_mode: uint32 = 0
    var user_bank = false
    # LDM^ with r15 in the list is an exception return (current banks, then
    # CPSR <- SPSR); every other S-bit form transfers the user bank.
    if not (load and bit(list, 15)):
      user_bank = true
      saved_mode = cpu.cpsr.mode
  # The base is read from the CURRENT bank before the user-bank switch; the
  # transfers and any writeback then use the user bank (hardware: gbaedge
  # LDMUSER on AGB SP, `stmia r13!, {r13}^` from IRQ mode; docs/hwprobe.md).
  var address  = cpu.r[rn]
  var bits_set = count_set_bits(list)
  if bits_set == 0:
    bits_set = 16
    list = 0x8000'u32
  let step       = when add: 4 else: -4
  let final_addr {.used.} = uint32(int(address) + bits_set * step)
  when s_bit:
    if user_bank:
      cpu.switch_mode(modeUSR)
  when add:
    when pre_address: address += 4
  else:
    address = final_addr
    when not pre_address: address += 4
  var first_transfer = false
  for idx in 0..15:
    if bit(list, idx):
      when load:
        let value = cpu.gba.bus.read_word(address)
        if idx == 15: cpu.idle(1)  # the I cycle precedes the pipeline refill
        discard cpu.set_reg(idx, value)
      else:
        cpu.gba.bus.write_word(address, cpu.r[idx])
        if idx == 15:
          cpu.gba.bus.write_word(address, cpu.gba.bus.read_word(address) + 4)
      address += 4
      when write_back:
        # Block transfers with base r15 perform no writeback in either direction
        # (hardware: gbaedge THUMBPC2 and PCWB2 on AGB SP, docs/hwprobe.md).
        if not first_transfer and not (load and bit(list, rn)) and
           rn != 15:
          discard cpu.set_reg(rn, final_addr)
      first_transfer = true
  when load:
    if not bit(list, 15): cpu.idle(1)  # I cycle after the last transfer
  when s_bit:
    if user_bank:
      cpu.switch_mode(cast[CpuMode](saved_mode))
    else:
      cpu.exception_return_restore()
  if not (load and bit(list, 15)): cpu.step_arm()

proc arm_branch*[link: static bool](cpu: CPU; instr: uint32) =
  let offset = cast[int32](bits_range(instr, 0, 23) shl 8) shr 6
  when link: discard cpu.set_reg(14, cpu.r[15] - 4)
  discard cpu.set_reg(15, uint32(int(cpu.r[15]) + offset))

proc arm_software_interrupt*(cpu: CPU; instr: uint32) =
  let use_hle = cpu.gba.use_hle or (cpu.gba.hle_after_bios and cpu.r[15] >= 0x08000000'u32)
  let swi_num = bits_range(instr, 16, 23)
  if use_hle:
    cpu.hle_swi(swi_num)
    cpu.step_arm()
  else:
    let lr = cpu.r[15] - 4
    let old_cpsr = cpu.cpsr
    cpu.switch_mode(modeSVC)
    cpu.spsr = old_cpsr
    discard cpu.set_reg(14, lr)
    cpu.cpsr.irq_disable = true
    discard cpu.set_reg(15, 0x08'u32)

proc arm_psr_transfer*[imm_flag, spsr, msr: static bool](cpu: CPU; instr: uint32) =
  let mode     = cast[CpuMode](cpu.cpsr.mode)
  let has_spsr {.used.} = mode != modeUSR and mode != modeSYS  # unread in some instantiations
  when msr:
    var mask: uint32 = 0
    if bit(instr, 19): mask = mask or 0xFF000000'u32
    if bit(instr, 18): mask = mask or 0x00FF0000'u32
    if bit(instr, 17): mask = mask or 0x0000FF00'u32
    if bit(instr, 16): mask = mask or 0x000000FF'u32
    var carry_out {.used.} = false  # written only in the `imm_flag` instantiations
    let value =
      when imm_flag:
        cpu.immediate_offset(bits_range(instr, 0, 11), addr carry_out) and mask
      else:
        cpu.r[int(bits_range(instr, 0, 3))] and mask
    when spsr:
      if has_spsr:
        # See PSR_PHYS_MASK; SPSR forces mode bit4 high.
        cpu.spsr = cast[PSR](
          (((uint32(cpu.spsr) and not mask) or value) and PSR_PHYS_MASK) or 0x10'u32)
    else:
      let was_irq_disabled = cpu.cpsr.irq_disable
      if (mask and 0xFF) > 0:
        cpu.switch_mode(cast[CpuMode](value and 0x1F'u32))
      cpu.cpsr = cast[PSR]((((uint32(cpu.cpsr) and not mask) or value) and PSR_PHYS_MASK))
      if cpu.cpsr.thumb:
        # MSR writes the T bit on ARM7TDMI (Pokemon Pinball R/S exits its
        # decompressor via `msr cpsr, r2` with T set, then a Thumb `bx r0`). The
        # two words already prefetched as ARM: A+4 executes as a Thumb nop, then
        # the low halfword of A+8, and fetching resumes at A+12 (hardware: gbaedge
        # MSRTBIT/MSRTBIT2 on AGB SP, docs/hwprobe.md).
        cpu.pipeline.clear()
        cpu.pipeline.push(0x46C0'u32)  # Thumb nop (mov r8, r8)
        cpu.pipeline.push(cpu.gba.bus.read_word_internal(cpu.r[15]) and 0xFFFF'u32)
      if was_irq_disabled and not cpu.cpsr.irq_disable:
        if cpu.gba.interrupts.irq_deliverable:
          # msr clearing CPSR.I over a parked IF recognizes late, like the IME/IE
          # gate stores (gbaedge IRQWIN/IRQWIN2).
          cpu.gba.interrupts.gate_opened()
        else:
          cpu.gba.interrupts.schedule_interrupt_check()
  else:  # MRS
    let rd = int(bits_range(instr, 12, 15))
    if spsr and has_spsr:
      discard cpu.set_reg(rd, uint32(cpu.spsr))
    else:
      discard cpu.set_reg(rd, uint32(cpu.cpsr))
  when not msr:
    if bits_range(instr, 12, 15) != 15: cpu.step_arm()
  else:
    cpu.step_arm()

proc arm_branch_exchange*(cpu: CPU; instr: uint32) =
  # The 12-bit LUT cannot see bits 19-8, so an SBO-violated BX (0xE120FF11)
  # lands here too; on hardware it executes as MSR CPSR from a register
  # (hardware: gbaedge BXDECODE on AGB SP, docs/hwprobe.md). The ARMv5
  # BLX-register word arrives via its own LUT entry and executes as BX.
  if bits_range(instr, 4, 7) == 0b0001'u32 and bits_range(instr, 8, 19) != 0xFFF'u32:
    arm_psr_transfer[false, false, true](cpu, instr)
    return
  let address = cpu.r[int(bits_range(instr, 0, 3))]
  cpu.cpsr.thumb = bit(address, 0)
  discard cpu.set_reg(15, address)

proc arm_data_processing*[imm_flag: static bool, opcode: static ArmAluOp,
                            set_cond, bit4: static bool](cpu: CPU; instr: uint32) =
  const pc_reads_12_ahead = not imm_flag and bit4
  when pc_reads_12_ahead:
    cpu.r[15] += 4
    cpu.idle(1)  # register-specified shift costs one internal cycle
  var barrel_carry = cpu.cpsr.carry
  let rn {.used.} = int(bits_range(instr, 16, 19))  # MOV/MVN instantiations never read rn
  let rd = int(bits_range(instr, 12, 15))
  let operand_2 =
    when imm_flag:
      cpu.immediate_offset(bits_range(instr, 0, 11), addr barrel_carry)
    else:
      cpu.rotate_register(bits_range(instr, 0, 11), addr barrel_carry, allow_register_shifts = true)
  when opcode == AND:
    discard cpu.set_reg(rd, cpu.r[rn] and operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  elif opcode == EOR:
    discard cpu.set_reg(rd, cpu.r[rn] xor operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  elif opcode == SUB:
    discard cpu.set_reg(rd, cpu.sub(cpu.r[rn], operand_2, set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == RSB:
    discard cpu.set_reg(rd, cpu.sub(operand_2, cpu.r[rn], set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == ADD:
    discard cpu.set_reg(rd, cpu.add(cpu.r[rn], operand_2, set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == ADC:
    discard cpu.set_reg(rd, cpu.adc(cpu.r[rn], operand_2, set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == SBC:
    discard cpu.set_reg(rd, cpu.sbc(cpu.r[rn], operand_2, set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == RSC:
    discard cpu.set_reg(rd, cpu.sbc(operand_2, cpu.r[rn], set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == TST:
    cpu.set_neg_and_zero_flags(cpu.r[rn] and operand_2)
    cpu.cpsr.carry = barrel_carry
    cpu.step_arm()
  elif opcode == TEQ:
    cpu.set_neg_and_zero_flags(cpu.r[rn] xor operand_2)
    cpu.cpsr.carry = barrel_carry
    cpu.step_arm()
  elif opcode == CMP:
    discard cpu.sub(cpu.r[rn], operand_2, set_cond)
    cpu.step_arm()
  elif opcode == CMN:
    discard cpu.add(cpu.r[rn], operand_2, set_cond)
    cpu.step_arm()
  elif opcode == ORR:
    discard cpu.set_reg(rd, cpu.r[rn] or operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  elif opcode == MOV:
    discard cpu.set_reg(rd, operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  elif opcode == BIC:
    discard cpu.set_reg(rd, cpu.r[rn] and not operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  else:  # MVN
    discard cpu.set_reg(rd, not operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  when pc_reads_12_ahead: cpu.r[15] -= 4
  if rd == 15 and set_cond:
    cpu.exception_return_restore()
