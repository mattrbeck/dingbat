# ARM data processing instructions (included by gba.nim)

proc arm_data_processing*(cpu: CPU; instr: uint32) =
  let imm_flag      = bit(instr, 25)
  let opcode        = int(bits_range(instr, 21, 24))
  let set_conditions = bit(instr, 20)
  let rn            = int(bits_range(instr, 16, 19))
  let rd            = int(bits_range(instr, 12, 15))
  let pc_reads_12_ahead = not imm_flag and bit(instr, 4)
  if pc_reads_12_ahead: cpu.r[15] += 4
  var barrel_shifter_carry_out = cpu.cpsr.carry
  let operand_2 =
    if imm_flag:
      cpu.immediate_offset(bits_range(instr, 0, 11), addr barrel_shifter_carry_out)
    else:
      cpu.rotate_register(bits_range(instr, 0, 11), addr barrel_shifter_carry_out, allow_register_shifts = true)
  case opcode
  of 0b0000:  # AND
    discard cpu.set_reg(rd, cpu.r[rn] and operand_2)
    if set_conditions:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_shifter_carry_out
    if rd != 15: cpu.step_arm()
  of 0b0001:  # EOR
    discard cpu.set_reg(rd, cpu.r[rn] xor operand_2)
    if set_conditions:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_shifter_carry_out
    if rd != 15: cpu.step_arm()
  of 0b0010:  # SUB
    discard cpu.set_reg(rd, cpu.sub(cpu.r[rn], operand_2, set_conditions))
    if rd != 15: cpu.step_arm()
  of 0b0011:  # RSB
    discard cpu.set_reg(rd, cpu.sub(operand_2, cpu.r[rn], set_conditions))
    if rd != 15: cpu.step_arm()
  of 0b0100:  # ADD
    discard cpu.set_reg(rd, cpu.add(cpu.r[rn], operand_2, set_conditions))
    if rd != 15: cpu.step_arm()
  of 0b0101:  # ADC
    discard cpu.set_reg(rd, cpu.adc(cpu.r[rn], operand_2, set_conditions))
    if rd != 15: cpu.step_arm()
  of 0b0110:  # SBC
    discard cpu.set_reg(rd, cpu.sbc(cpu.r[rn], operand_2, set_conditions))
    if rd != 15: cpu.step_arm()
  of 0b0111:  # RSC
    discard cpu.set_reg(rd, cpu.sbc(operand_2, cpu.r[rn], set_conditions))
    if rd != 15: cpu.step_arm()
  of 0b1000:  # TST
    cpu.set_neg_and_zero_flags(cpu.r[rn] and operand_2)
    cpu.cpsr.carry = barrel_shifter_carry_out
    cpu.step_arm()
  of 0b1001:  # TEQ
    cpu.set_neg_and_zero_flags(cpu.r[rn] xor operand_2)
    cpu.cpsr.carry = barrel_shifter_carry_out
    cpu.step_arm()
  of 0b1010:  # CMP
    discard cpu.sub(cpu.r[rn], operand_2, set_conditions)
    cpu.step_arm()
  of 0b1011:  # CMN
    discard cpu.add(cpu.r[rn], operand_2, set_conditions)
    cpu.step_arm()
  of 0b1100:  # ORR
    discard cpu.set_reg(rd, cpu.r[rn] or operand_2)
    if set_conditions:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_shifter_carry_out
    if rd != 15: cpu.step_arm()
  of 0b1101:  # MOV
    discard cpu.set_reg(rd, operand_2)
    if set_conditions:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_shifter_carry_out
    if rd != 15: cpu.step_arm()
  of 0b1110:  # BIC
    discard cpu.set_reg(rd, cpu.r[rn] and not operand_2)
    if set_conditions:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_shifter_carry_out
    if rd != 15: cpu.step_arm()
  of 0b1111:  # MVN
    discard cpu.set_reg(rd, not operand_2)
    if set_conditions:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_shifter_carry_out
    if rd != 15: cpu.step_arm()
  else:
    raise newException(Exception, "Unimplemented data processing opcode: " & hex_str(uint8(opcode)))
  if pc_reads_12_ahead: cpu.r[15] -= 4
  if rd == 15 and set_conditions:
    if cpu.spsr.thumb: cpu.r[15] -= 4
    let old_spsr  = uint32(cpu.spsr)
    let new_mode  = CpuMode(cpu.spsr.mode)
    cpu.switch_mode(new_mode)
    cpu.cpsr = cast[PSR](old_spsr)
    let bank = mode_bank(new_mode)
    cpu.spsr = cast[PSR](if bank == 0: uint32(cpu.cpsr) else: cpu.spsr_banks[bank])
