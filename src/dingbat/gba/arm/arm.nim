# ARM instruction handlers (included by gba.nim)

proc bios_arctan(a: int32): int32 =
  ## GBA BIOS ArcTan polynomial approximation (standard HLE coefficients).
  ## Input: tan value in 1.14 fixed-point (signed).
  ## Output: theta where 0x4000 = pi/2.
  let a64 = int64(a)
  let neg_a_sq = -((a64 * a64) shr 14)
  var r3 = (int64(0xA9) * neg_a_sq) shr 14
  r3 = ((r3 + 0x0390) * neg_a_sq) shr 14
  r3 = ((r3 + 0x091C) * neg_a_sq) shr 14
  r3 = ((r3 + 0x0FB6) * neg_a_sq) shr 14
  r3 = ((r3 + 0x16AA) * neg_a_sq) shr 14
  r3 = ((r3 + 0x2081) * neg_a_sq) shr 14
  r3 = ((r3 + 0x3651) * neg_a_sq) shr 14
  r3 = r3 + 0xA2F9
  result = cast[int32](uint32((a64 * r3) shr 14))

proc hle_swi*(cpu: CPU; swi_num: uint32) =
  ## HLE BIOS dispatch for the most common GBA SWI calls.
  ## Only used when no real BIOS file is provided.
  case swi_num
  of 0x02:  # Halt
    cpu.halted = true
  of 0x06:  # Div
    let numer = int64(cast[int32](cpu.r[0]))
    let denom = int64(cast[int32](cpu.r[1]))
    if denom == 0:
      cpu.r[0] = if numer < 0: 0xFFFFFFFF'u32 else: 1'u32
      cpu.r[1] = uint32(numer and 0xFFFFFFFF)
      cpu.r[3] = 1'u32
    else:
      let quot = numer div denom
      let rem = numer mod denom
      cpu.r[0] = cast[uint32](uint32(quot and 0xFFFFFFFF))
      cpu.r[1] = cast[uint32](uint32(rem and 0xFFFFFFFF))
      cpu.r[3] = uint32(abs(quot) and 0xFFFFFFFF)
  of 0x07:  # DivArm (swapped inputs)
    let numer = int64(cast[int32](cpu.r[1]))
    let denom = int64(cast[int32](cpu.r[0]))
    if denom == 0:
      cpu.r[0] = if numer < 0: 0xFFFFFFFF'u32 else: 1'u32
      cpu.r[1] = uint32(numer and 0xFFFFFFFF)
      cpu.r[3] = 1'u32
    else:
      let quot = numer div denom
      let rem = numer mod denom
      cpu.r[0] = cast[uint32](uint32(quot and 0xFFFFFFFF))
      cpu.r[1] = cast[uint32](uint32(rem and 0xFFFFFFFF))
      cpu.r[3] = uint32(abs(quot) and 0xFFFFFFFF)
  of 0x04:  # IntrWait(discard_flags, intr_flags)
    let discard_flags = cpu.r[0]
    let intr_mask = uint16(cpu.r[1])
    if discard_flags != 0:
      cpu.gba.interrupts.reg_if =
        cast[InterruptReg](uint16(cpu.gba.interrupts.reg_if) and not intr_mask)
    cpu.gba.interrupts.reg_ie =
      cast[InterruptReg](uint16(cpu.gba.interrupts.reg_ie) or intr_mask)
    cpu.halted = true
  of 0x05:  # VBlankIntrWait
    cpu.gba.interrupts.reg_if.vblank = false
    cpu.gba.interrupts.reg_ie.vblank = true
    cpu.halted = true
  of 0x08:  # Sqrt
    let val = cpu.r[0]
    if val == 0:
      cpu.r[0] = 0
    else:
      var result_val: uint32 = 0
      var bit_val: uint32 = 1'u32 shl 30
      var num = val
      while bit_val > num:
        bit_val = bit_val shr 2
      while bit_val != 0:
        if num >= result_val + bit_val:
          num -= result_val + bit_val
          result_val = (result_val shr 1) + bit_val
        else:
          result_val = result_val shr 1
        bit_val = bit_val shr 2
      cpu.r[0] = result_val
  of 0x09:  # ArcTan
    cpu.r[0] = cast[uint32](bios_arctan(cast[int32](cpu.r[0])))
  of 0x0A:  # ArcTan2
    let x = cast[int16](cpu.r[0] and 0xFFFF)
    let y = cast[int16](cpu.r[1] and 0xFFFF)
    if x == 0 and y == 0:
      cpu.r[0] = 0
    elif y == 0:
      cpu.r[0] = if x > 0: 0'u32 else: 0x8000'u32
    elif x == 0:
      cpu.r[0] = if y > 0: 0x4000'u32 else: 0xC000'u32
    else:
      if abs(int32(x)) > abs(int32(y)):
        cpu.r[0] = cast[uint32](bios_arctan((int32(y) shl 14) div int32(x)))
        if x < 0:
          if y >= 0:
            cpu.r[0] = cpu.r[0] + 0x8000'u32
          else:
            cpu.r[0] = cpu.r[0] - 0x8000'u32
      else:
        cpu.r[0] = cast[uint32](bios_arctan((int32(x) shl 14) div int32(y)))
        if y > 0:
          cpu.r[0] = 0x4000'u32 - cpu.r[0]
        else:
          cpu.r[0] = 0xC000'u32 - cpu.r[0]
  of 0x0B:  # CpuSet
    var src = cpu.r[0]
    var dst = cpu.r[1]
    let ctrl = cpu.r[2]
    let count = bits_range(ctrl, 0, 20)
    let fill = bit(ctrl, 24)
    let word_mode = bit(ctrl, 26)
    if word_mode:
      src = src and not 3'u32
      dst = dst and not 3'u32
      let fill_val = cpu.gba.bus.read_word(src)
      for i in 0'u32 ..< count:
        let val = if fill: fill_val else: cpu.gba.bus.read_word(src)
        cpu.gba.bus.write_word(dst, val)
        if not fill: src += 4
        dst += 4
    else:
      src = src and not 1'u32
      dst = dst and not 1'u32
      let fill_val = cpu.gba.bus.read_half(src)
      for i in 0'u32 ..< count:
        let val = if fill: fill_val else: cpu.gba.bus.read_half(src)
        cpu.gba.bus.write_half(dst, val)
        if not fill: src += 2
        dst += 2
  of 0x0C:  # CpuFastSet
    var src = cpu.r[0]
    var dst = cpu.r[1]
    let ctrl = cpu.r[2]
    let count = (bits_range(ctrl, 0, 20) + 7) and not 7'u32  # round up to multiple of 8
    let fill = bit(ctrl, 24)
    let fill_val = cpu.gba.bus.read_word(src)
    for i in 0'u32 ..< count:
      let val = if fill: fill_val else: cpu.gba.bus.read_word(src)
      cpu.gba.bus.write_word(dst, val)
      if not fill: src += 4
      dst += 4
  else:
    discard  # unimplemented SWI: return immediately (no-op)

proc arm_unimplemented*(cpu: CPU; instr: uint32) =
  cpu.und()
  cpu.step_arm()

proc arm_unused*(cpu: CPU; instr: uint32) =
  cpu.und()
  cpu.step_arm()

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

proc arm_multiply*[accumulate, set_cond: static bool](cpu: CPU; instr: uint32) =
  let rd  = int(bits_range(instr, 16, 19))
  let rn  = int(bits_range(instr, 12, 15))
  let rs  = int(bits_range(instr, 8, 11))
  let rm  = int(bits_range(instr, 0, 3))
  let acc = when accumulate: cpu.r[rn] else: 0'u32
  discard cpu.set_reg(rd, cpu.r[rm] * cpu.r[rs] + acc)
  when set_cond: cpu.set_neg_and_zero_flags(cpu.r[rd])
  if rd != 15: cpu.step_arm()

proc arm_multiply_long*[signed, accumulate, set_cond: static bool](cpu: CPU; instr: uint32) =
  let rdhi = int(bits_range(instr, 16, 19))
  let rdlo = int(bits_range(instr, 12, 15))
  let rs   = int(bits_range(instr, 8, 11))
  let rm   = int(bits_range(instr, 0, 3))
  var res: uint64 =
    when signed:
      cast[uint64](int64(cast[int32](cpu.r[rm])) * int64(cast[int32](cpu.r[rs])))
    else:
      uint64(cpu.r[rm]) * uint64(cpu.r[rs])
  when accumulate:
    res += (uint64(cpu.r[rdhi]) shl 32) or uint64(cpu.r[rdlo])
  discard cpu.set_reg(rdhi, uint32(res shr 32))
  discard cpu.set_reg(rdlo, uint32(res))
  when set_cond:
    cpu.cpsr.negative = bit(cpu.r[rdhi], 31)
    cpu.cpsr.zero     = (res == 0)
    # ARM7TDMI "meaningless" carry flag: determined by the Booth multiplier internals.
    # For long multiply, the carry depends on the number of Booth iterations and
    # the interaction of Rm/Rs bit patterns in the carry-save adder.
    block:
      let rs_val = cpu.r[rs]
      let rm_val = cpu.r[rm]
      when signed:
        var rs33 = uint64(rs_val)
        if bit(rs_val, 31): rs33 = rs33 or 0x1_00000000'u64
        let four_iters = not ((rs33 shr 8) == 0 or (rs33 shr 8) == 0x1FFFFFF'u64 or
                              (rs33 shr 16) == 0 or (rs33 shr 16) == 0x1FFFF'u64 or
                              (rs33 shr 24) == 0 or (rs33 shr 24) == 0x1FF'u64)
        cpu.cpsr.carry = four_iters and (bit(rm_val, 31) xor bit(rs_val, 31))
      else:
        let four_iters = rs_val > 0xFFFFFF'u32
        if four_iters and ((rs_val shr 29) == 7):
          # Rs bits [31:29] all set: Booth chunk 15 cancels, carry from chunk 16
          cpu.cpsr.carry = bit(rm_val, 30)
        else:
          cpu.cpsr.carry = four_iters and bit(rm_val, 31)
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
  if rd != 15: cpu.step_arm()

proc arm_branch_exchange*(cpu: CPU; instr: uint32) =
  let address = cpu.r[int(bits_range(instr, 0, 3))]
  cpu.cpsr.thumb = bit(address, 0)
  discard cpu.set_reg(15, address)

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
      discard cpu.set_reg(rd, cpu.gba.bus.read_half_rotate(address))
    else:
      cpu.gba.bus.write_half(address, uint16(cpu.r[rd] and 0xFFFF'u32))
      if rd == 15:
        cpu.gba.bus.write_half(address, uint16(cpu.gba.bus.read_half(address)) + 4)
  elif sh == 0b10:  # ldrsb
    discard cpu.set_reg(rd, uint32(cast[int32](cast[int8](cpu.gba.bus[address]))))
  else:  # sh == 0b11, ldrsh
    discard cpu.set_reg(rd, cpu.gba.bus.read_half_signed(address))
  when not pre:
    when add: address += offset
    else:     address -= offset
  when write_back or not pre:
    if rd != rn or not load:
      discard cpu.set_reg(rn, address)
  if not (load and rd == 15): cpu.step_arm()

proc arm_single_data_transfer*[imm_flag, pre_addressing, add_offset, byte_quantity,
                                 write_back, load, bit0: static bool](cpu: CPU; instr: uint32) =
  var carry_out = false
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
  when load:
    when byte_quantity:
      discard cpu.set_reg(rd, uint32(cpu.gba.bus[address]))
    else:
      discard cpu.set_reg(rd, cpu.gba.bus.read_word_rotate(address))
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
  when write_back or not pre_addressing:
    if rd != rn or not load:
      discard cpu.set_reg(rn, address)
  if not (load and rd == 15): cpu.step_arm()

proc arm_block_data_transfer*[pre_address, add, s_bit, write_back, load: static bool](cpu: CPU; instr: uint32) =
  let rn = int(bits_range(instr, 16, 19))
  var list = bits_range(instr, 0, 15)
  var saved_mode: uint32 = 0
  when s_bit:
    if bit(list, 15):
      raise newException(Exception, "todo: handle cases with r15 in list")
    saved_mode = cpu.cpsr.mode
    cpu.switch_mode(modeUSR)
  var address  = cpu.r[rn]
  var bits_set = count_set_bits(list)
  if bits_set == 0:
    bits_set = 16
    list = 0x8000'u32
  let step       = when add: 4 else: -4
  let final_addr = uint32(int(address) + bits_set * step)
  when add:
    when pre_address: address += 4
  else:
    address = final_addr
    when not pre_address: address += 4
  var first_transfer = false
  for idx in 0..15:
    if bit(list, idx):
      when load:
        discard cpu.set_reg(idx, cpu.gba.bus.read_word(address))
      else:
        cpu.gba.bus.write_word(address, cpu.r[idx])
        if idx == 15:
          cpu.gba.bus.write_word(address, cpu.gba.bus.read_word(address) + 4)
      address += 4
      when write_back:
        if not first_transfer and not (load and bit(list, rn)):
          discard cpu.set_reg(rn, final_addr)
      first_transfer = true
  when s_bit:
    cpu.switch_mode(cast[CpuMode](saved_mode))
  if not (load and bit(list, 15)): cpu.step_arm()

proc arm_branch*[link: static bool](cpu: CPU; instr: uint32) =
  let offset = cast[int32](bits_range(instr, 0, 23) shl 8) shr 6
  when link: discard cpu.set_reg(14, cpu.r[15] - 4)
  discard cpu.set_reg(15, uint32(int(cpu.r[15]) + offset))

proc arm_software_interrupt*(cpu: CPU; instr: uint32) =
  if cpu.gba.bios_path == "":
    let swi_num = bits_range(instr, 16, 23)
    cpu.hle_swi(swi_num)
    cpu.step_arm()
  else:
    let lr = cpu.r[15] - 4
    cpu.switch_mode(modeSVC)
    discard cpu.set_reg(14, lr)
    cpu.cpsr.irq_disable = true
    discard cpu.set_reg(15, 0x08'u32)

proc arm_psr_transfer*[imm_flag, spsr, msr: static bool](cpu: CPU; instr: uint32) =
  let mode     = cast[CpuMode](cpu.cpsr.mode)
  let has_spsr = mode != modeUSR and mode != modeSYS
  when msr:
    var mask: uint32 = 0
    if bit(instr, 19): mask = mask or 0xFF000000'u32
    if bit(instr, 18): mask = mask or 0x00FF0000'u32
    if bit(instr, 17): mask = mask or 0x0000FF00'u32
    if bit(instr, 16): mask = mask or 0x000000FF'u32
    var carry_out = false
    let value =
      when imm_flag:
        cpu.immediate_offset(bits_range(instr, 0, 11), addr carry_out) and mask
      else:
        cpu.r[int(bits_range(instr, 0, 3))] and mask
    when spsr:
      if has_spsr:
        cpu.spsr = cast[PSR]((uint32(cpu.spsr) and not mask) or value)
    else:
      let thumb = cpu.cpsr.thumb
      let was_irq_disabled = cpu.cpsr.irq_disable
      if (mask and 0xFF) > 0:
        cpu.switch_mode(cast[CpuMode](value and 0x1F'u32))
      cpu.cpsr = cast[PSR]((uint32(cpu.cpsr) and not mask) or value)
      cpu.cpsr.thumb = thumb
      if was_irq_disabled and not cpu.cpsr.irq_disable:
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

proc arm_data_processing*[imm_flag: static bool, opcode: static ArmAluOp,
                            set_cond, bit4: static bool](cpu: CPU; instr: uint32) =
  const pc_reads_12_ahead = not imm_flag and bit4
  when pc_reads_12_ahead: cpu.r[15] += 4
  var barrel_carry = cpu.cpsr.carry
  let rn = int(bits_range(instr, 16, 19))
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
    if cpu.spsr.thumb: cpu.r[15] -= 4
    let old_spsr = uint32(cpu.spsr)
    let was_irq_disabled = cpu.cpsr.irq_disable
    let new_mode = cast[CpuMode](cpu.spsr.mode)
    cpu.switch_mode(new_mode)
    cpu.cpsr = cast[PSR](old_spsr)
    let bank = mode_bank(new_mode)
    cpu.spsr = cast[PSR](if bank == 0: uint32(cpu.cpsr) else: cpu.spsr_banks[bank])
    if was_irq_disabled and not cpu.cpsr.irq_disable:
      cpu.gba.interrupts.schedule_interrupt_check()
