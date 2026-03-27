# THUMB instruction handlers + LUT (included by gba.nim)
# All instructions are statically parameterized by bits extracted from the
# 10-bit LUT index (bits 15-6 of the instruction word, i.e. instr shr 6).

proc thumb_long_branch_link*[second_instr: static bool](cpu: CPU; instr: uint32) =
  let offset = bits_range(instr, 0, 10)
  when second_instr:
    let temp = cpu.r[15] - 2
    discard cpu.set_reg(15, cpu.r[14] + (offset shl 1))
    discard cpu.set_reg(14, temp or 1'u32)
  else:
    let off_signed = cast[int32](cast[int16](uint16(offset shl 5))) shr 5
    discard cpu.set_reg(14, uint32(int(cpu.r[15]) + (off_signed shl 12)))
    cpu.step_thumb()

proc thumb_unconditional_branch*(cpu: CPU; instr: uint32) =
  let offset = bits_range(instr, 0, 10)
  let off_signed = cast[int32](cast[int16](uint16(offset shl 5))) shr 4
  discard cpu.set_reg(15, uint32(int(cpu.r[15]) + off_signed))

proc thumb_software_interrupt*(cpu: CPU; instr: uint32) =
  let use_hle = cpu.gba.use_hle or (cpu.gba.hle_after_bios and cpu.r[15] >= 0x08000000'u32)
  let swi_num = bits_range(instr, 0, 7)
  if use_hle and uint8(swi_num) in hle_swi_set:
    cpu.hle_swi(swi_num)
    cpu.step_thumb()
  else:
    let lr = cpu.r[15] - 2
    cpu.switch_mode(modeSVC)
    discard cpu.set_reg(14, lr)
    cpu.cpsr.irq_disable = true
    cpu.cpsr.thumb = false
    discard cpu.set_reg(15, 0x08'u32)

proc thumb_conditional_branch*[cond: static uint32](cpu: CPU; instr: uint32) =
  let offset      = cast[int32](cast[int8](uint8(bits_range(instr, 0, 7))))
  let branch_dest = uint32(int(cpu.r[15]) + offset * 2)
  cpu.analyze_loop(branch_dest, cpu.r[15] - 4)
  if cpu.check_cond(cond):
    discard cpu.set_reg(15, branch_dest)
  else:
    cpu.step_thumb()

proc thumb_multiple_load_store*[load: static bool](cpu: CPU; instr: uint32) =
  let rb      = int(bits_range(instr, 8, 10))
  let list    = bits_range(instr, 0, 7)
  var address = cpu.r[rb]
  if list != 0:
    let final_addr = 4'u32 * uint32(count_set_bits(list)) + address
    when load:  # ldmia
      cpu.r[rb] = final_addr  # writeback immediately
      for idx in 0..7:
        if bit(list, idx):
          discard cpu.set_reg(idx, cpu.gba.bus.read_word(address))
          address += 4
    else:  # stmia
      var first_transfer = false
      for idx in 0..7:
        if bit(list, idx):
          cpu.gba.bus.write_word(address, cpu.r[idx])
          address += 4
          if not first_transfer:
            cpu.r[rb] = final_addr  # writeback after first transfer
          first_transfer = true
  else:  # empty list edge case
    when load:
      discard cpu.set_reg(15, cpu.gba.bus.read_word(address))
    else:
      cpu.gba.bus.write_word(address, cpu.r[15] + 2)
    discard cpu.set_reg(rb, address + 0x40'u32)
  if not (list == 0 and load): cpu.step_thumb()

proc thumb_push_pop_registers*[pop, pclr: static bool](cpu: CPU; instr: uint32) =
  let list    = bits_range(instr, 0, 7)
  var address = cpu.r[13]
  when pop:
    for idx in 0..7:
      if bit(list, idx):
        discard cpu.set_reg(idx, cpu.gba.bus.read_word(address))
        address += 4
    when pclr:
      discard cpu.set_reg(15, cpu.gba.bus.read_word(address))
      address += 4
  else:
    when pclr:
      address -= 4
      cpu.gba.bus.write_word(address, cpu.r[14])
    var idx = 7
    while idx >= 0:
      if bit(list, idx):
        address -= 4
        cpu.gba.bus.write_word(address, cpu.r[idx])
      dec idx
  discard cpu.set_reg(13, address)
  if not (pop and pclr): cpu.step_thumb()

proc thumb_add_offset_to_stack_pointer*[sign: static bool](cpu: CPU; instr: uint32) =
  let offset = bits_range(instr, 0, 6)
  when sign:
    discard cpu.set_reg(13, cpu.r[13] - (offset shl 2))
  else:
    discard cpu.set_reg(13, cpu.r[13] + (offset shl 2))
  cpu.step_thumb()

proc thumb_load_address*[source: static bool](cpu: CPU; instr: uint32) =
  let rd  = int(bits_range(instr, 8, 10))
  let imm = bits_range(instr, 0, 7) shl 2
  cpu.r[rd] = (when source: cpu.r[13] else: cpu.r[15] and not 2'u32) + imm
  cpu.step_thumb()

proc thumb_sp_relative_load_store*[load: static bool](cpu: CPU; instr: uint32) =
  let rd      = int(bits_range(instr, 8, 10))
  let address = cpu.r[13] + (bits_range(instr, 0, 7) shl 2)
  when load:
    discard cpu.set_reg(rd, cpu.gba.bus.read_word_rotate(address))
  else:
    cpu.gba.bus.write_word(address, cpu.r[rd])
  cpu.step_thumb()

proc thumb_load_store_halfword*[load: static bool](cpu: CPU; instr: uint32) =
  let rb      = int(bits_range(instr, 3, 5))
  let rd      = int(bits_range(instr, 0, 2))
  let address = cpu.r[rb] + (bits_range(instr, 6, 10) shl 1)
  when load:
    discard cpu.set_reg(rd, cpu.gba.bus.read_half_rotate(address))
  else:
    cpu.gba.bus.write_half(address, uint16(cpu.r[rd]))
  cpu.step_thumb()

proc thumb_load_store_immediate_offset*[bq_and_load: static uint32](cpu: CPU; instr: uint32) =
  let offset    = bits_range(instr, 6, 10)
  let rb        = int(bits_range(instr, 3, 5))
  let rd        = int(bits_range(instr, 0, 2))
  let base_addr = cpu.r[rb]
  when bq_and_load == 0b00:  # str
    cpu.gba.bus.write_word(base_addr + (offset shl 2), cpu.r[rd])
  elif bq_and_load == 0b01:  # ldr
    discard cpu.set_reg(rd, cpu.gba.bus.read_word_rotate(base_addr + (offset shl 2)))
  elif bq_and_load == 0b10:  # strb
    cpu.gba.bus[base_addr + offset] = uint8(cpu.r[rd])
  else:  # ldrb
    discard cpu.set_reg(rd, uint32(cpu.gba.bus[base_addr + offset]))
  cpu.step_thumb()

proc thumb_load_store_sign_extended*[hs: static uint32](cpu: CPU; instr: uint32) =
  let ro      = int(bits_range(instr, 6, 8))
  let rb      = int(bits_range(instr, 3, 5))
  let rd      = int(bits_range(instr, 0, 2))
  let address = cpu.r[rb] + cpu.r[ro]
  when hs == 0b00:  # strh
    cpu.gba.bus.write_half(address, uint16(cpu.r[rd]))
  elif hs == 0b01:  # ldsb
    discard cpu.set_reg(rd, uint32(cast[int32](cast[int8](cpu.gba.bus[address]))))
  elif hs == 0b10:  # ldrh
    discard cpu.set_reg(rd, cpu.gba.bus.read_half_rotate(address))
  else:  # ldsh
    discard cpu.set_reg(rd, cpu.gba.bus.read_half_signed(address))
  cpu.step_thumb()

proc thumb_load_store_register_offset*[lb_and_bq: static uint32](cpu: CPU; instr: uint32) =
  let ro      = int(bits_range(instr, 6, 8))
  let rb      = int(bits_range(instr, 3, 5))
  let rd      = int(bits_range(instr, 0, 2))
  let address = cpu.r[rb] + cpu.r[ro]
  when lb_and_bq == 0b00:  # str
    cpu.gba.bus.write_word(address, cpu.r[rd])
  elif lb_and_bq == 0b01:  # strb
    cpu.gba.bus[address] = uint8(cpu.r[rd])
  elif lb_and_bq == 0b10:  # ldr
    discard cpu.set_reg(rd, cpu.gba.bus.read_word_rotate(address))
  else:  # ldrb
    discard cpu.set_reg(rd, uint32(cpu.gba.bus[address]))
  cpu.step_thumb()

proc thumb_pc_relative_load*(cpu: CPU; instr: uint32) =
  let imm = bits_range(instr, 0, 7)
  let rd  = int(bits_range(instr, 8, 10))
  discard cpu.set_reg(rd, cpu.gba.bus.read_word((cpu.r[15] and not 2'u32) + (imm shl 2)))
  cpu.step_thumb()

proc thumb_high_reg_branch_exchange*[op: static uint32, h1, h2: static bool](cpu: CPU; instr: uint32) =
  var rs = int(bits_range(instr, 3, 5))
  var rd = int(bits_range(instr, 0, 2))
  when h1: rd += 8
  when h2: rs += 8
  when op == 0b00:
    discard cpu.set_reg(rd, cpu.add(cpu.r[rd], cpu.r[rs], false))
  elif op == 0b01:
    discard cpu.sub(cpu.r[rd], cpu.r[rs], true)
  elif op == 0b10:
    discard cpu.set_reg(rd, cpu.r[rs])
  else:  # 0b11: BX
    if bit(cpu.r[rs], 0):
      discard cpu.set_reg(15, cpu.r[rs])
    else:
      cpu.cpsr.thumb = false
      discard cpu.set_reg(15, cpu.r[rs])
  if rd != 15 and op != 0b11: cpu.step_thumb()

proc thumb_alu_operations*[op: static uint32](cpu: CPU; instr: uint32) =
  let rs = int(bits_range(instr, 3, 5))
  let rd = int(bits_range(instr, 0, 2))
  var barrel_carry = cpu.cpsr.carry
  var res: uint32
  when op == 0b0000: res = cpu.set_reg(rd, cpu.r[rd] and cpu.r[rs])
  elif op == 0b0001: res = cpu.set_reg(rd, cpu.r[rd] xor cpu.r[rs])
  elif op == 0b0010:
    res = cpu.set_reg(rd, cpu.lsl(cpu.r[rd], cpu.r[rs], addr barrel_carry))
    cpu.cpsr.carry = barrel_carry
  elif op == 0b0011:
    res = cpu.set_reg(rd, cpu.lsr(cpu.r[rd], cpu.r[rs], false, addr barrel_carry))
    cpu.cpsr.carry = barrel_carry
  elif op == 0b0100:
    res = cpu.set_reg(rd, cpu.asr(cpu.r[rd], cpu.r[rs], false, addr barrel_carry))
    cpu.cpsr.carry = barrel_carry
  elif op == 0b0101: res = cpu.set_reg(rd, cpu.adc(cpu.r[rd], cpu.r[rs], set_conditions = true))
  elif op == 0b0110: res = cpu.set_reg(rd, cpu.sbc(cpu.r[rd], cpu.r[rs], set_conditions = true))
  elif op == 0b0111:
    res = cpu.set_reg(rd, cpu.ror(cpu.r[rd], cpu.r[rs], false, addr barrel_carry))
    cpu.cpsr.carry = barrel_carry
  elif op == 0b1000: res = cpu.r[rd] and cpu.r[rs]
  elif op == 0b1001: res = cpu.set_reg(rd, cpu.sub(0'u32, cpu.r[rs], set_conditions = true))
  elif op == 0b1010: res = cpu.sub(cpu.r[rd], cpu.r[rs], set_conditions = true)
  elif op == 0b1011: res = cpu.add(cpu.r[rd], cpu.r[rs], set_conditions = true)
  elif op == 0b1100: res = cpu.set_reg(rd, cpu.r[rd] or cpu.r[rs])
  elif op == 0b1101: res = cpu.set_reg(rd, cpu.r[rs] * cpu.r[rd])
  elif op == 0b1110: res = cpu.set_reg(rd, cpu.r[rd] and not cpu.r[rs])
  else:              res = cpu.set_reg(rd, not cpu.r[rs])
  cpu.set_neg_and_zero_flags(res)
  cpu.step_thumb()

proc thumb_move_compare_add_subtract*[op: static uint32](cpu: CPU; instr: uint32) =
  let rd     = int(bits_range(instr, 8, 10))
  let offset = bits_range(instr, 0, 7)
  when op == 0b00:
    discard cpu.set_reg(rd, offset)
    cpu.set_neg_and_zero_flags(cpu.r[rd])
  elif op == 0b01: discard cpu.sub(cpu.r[rd], offset, true)
  elif op == 0b10: discard cpu.set_reg(rd, cpu.add(cpu.r[rd], offset, true))
  else:            discard cpu.set_reg(rd, cpu.sub(cpu.r[rd], offset, true))
  cpu.step_thumb()

proc thumb_add_subtract*[imm_flag, sub: static bool](cpu: CPU; instr: uint32) =
  let imm = bits_range(instr, 6, 8)
  let rs  = int(bits_range(instr, 3, 5))
  let rd  = int(bits_range(instr, 0, 2))
  let operand = when imm_flag: imm else: cpu.r[int(imm)]
  when sub:
    discard cpu.set_reg(rd, cpu.sub(cpu.r[rs], operand, true))
  else:
    discard cpu.set_reg(rd, cpu.add(cpu.r[rs], operand, true))
  cpu.step_thumb()

proc thumb_move_shifted_register*[op: static uint32](cpu: CPU; instr: uint32) =
  let offset = bits_range(instr, 6, 10)
  let rs     = int(bits_range(instr, 3, 5))
  let rd     = int(bits_range(instr, 0, 2))
  var carry_out = cpu.cpsr.carry
  when op == 0b00: discard cpu.set_reg(rd, cpu.lsl(cpu.r[rs], offset, addr carry_out))
  elif op == 0b01: discard cpu.set_reg(rd, cpu.lsr(cpu.r[rs], offset, true, addr carry_out))
  elif op == 0b10: discard cpu.set_reg(rd, cpu.asr(cpu.r[rs], offset, true, addr carry_out))
  else: discard  # encodes thumb add/subtract
  cpu.set_neg_and_zero_flags(cpu.r[rd])
  cpu.cpsr.carry = carry_out
  cpu.step_thumb()

proc thumb_unimplemented*(cpu: CPU; instr: uint32) =
  raise newException(Exception, "Unimplemented THUMB instruction: " & hex_str(uint16(instr)))

macro thumbLutBuilder(): untyped =
  result = newTree(nnkBracket)
  for i in 0'u32 ..< 1024'u32:
    result.add:
      checkBits i:
      of "1111......": call("thumb_long_branch_link", i.bit(5))
      of "11100.....": call("thumb_unconditional_branch")
      of "11011111..": call("thumb_software_interrupt")
      of "1101......": call("thumb_conditional_branch", bits_range(i, 2, 5))
      of "1100......": call("thumb_multiple_load_store", i.bit(5))
      of "1011.10...": call("thumb_push_pop_registers", i.bit(5), i.bit(2))
      of "10110000..": call("thumb_add_offset_to_stack_pointer", i.bit(1))
      of "1010......": call("thumb_load_address", i.bit(5))
      of "1001......": call("thumb_sp_relative_load_store", i.bit(5))
      of "1000......": call("thumb_load_store_halfword", i.bit(5))
      of "011.......": call("thumb_load_store_immediate_offset", bits_range(i, 5, 6))
      of "0101..1...": call("thumb_load_store_sign_extended", bits_range(i, 4, 5))
      of "0101..0...": call("thumb_load_store_register_offset", bits_range(i, 4, 5))
      of "01001.....": call("thumb_pc_relative_load")
      of "010001....": call("thumb_high_reg_branch_exchange", bits_range(i, 2, 3), i.bit(1), i.bit(0))
      of "010000....": call("thumb_alu_operations", bits_range(i, 0, 3))
      of "001.......": call("thumb_move_compare_add_subtract", bits_range(i, 5, 6))
      of "00011.....": call("thumb_add_subtract", i.bit(4), i.bit(3))
      of "000.......": call("thumb_move_shifted_register", bits_range(i, 5, 6))
      else:            call("thumb_unimplemented")

{.push warning[UnreachableCode]: off.}
const thumbLut = thumbLutBuilder()
{.pop.}

proc thumb_execute*(cpu: CPU; instr: uint32) =
  thumbLut[instr shr 6](cpu, instr)
