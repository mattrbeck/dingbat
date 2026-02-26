# CPU implementation (included by gba.nim)

proc mode_bank*(m: CpuMode): int =
  case m
  of modeUSR, modeSYS: 0
  of modeFIQ:          1
  of modeIRQ:          2
  of modeSVC:          3
  of modeABT:          4
  of modeUND:          5

proc new_cpu*(gba: GBA): CPU =
  result = CPU(
    gba: gba,
    cpsr: PSR(value: uint32(modeSYS)),
    spsr: PSR(value: uint32(modeSYS)),
    pipeline: Pipeline(),
    halted: false,
    count_cycles: 0,
    attempt_waitloop_detection: true,
    cache_waitloop_results: true,
    branch_dest: 0,
    entered_waitloop: false,
  )
  for i in 0..15: result.r[i] = 0
  for bank in 0..5:
    for reg in 0..6: result.reg_banks[bank][reg] = 0
    result.spsr_banks[bank] = uint32(modeSYS)
  result.waitloop_instr_lut = build_waitloop_lut()
  result.lut = result.fill_lut()
  result.thumb_lut = result.fill_thumb_lut()
  result.clear_pipeline()

proc skip_bios*(cpu: CPU) =
  cpu.reg_banks[mode_bank(modeUSR)][5] = 0x03007F00'u32
  cpu.r[13] = 0x03007F00'u32
  cpu.reg_banks[mode_bank(modeIRQ)][5] = 0x03007FA0'u32
  cpu.reg_banks[mode_bank(modeSVC)][5] = 0x03007FE0'u32
  cpu.r[15] = 0x08000000'u32
  cpu.clear_pipeline()

proc switch_mode*(cpu: CPU; new_mode: CpuMode) =
  let old_mode  = CpuMode(cpu.cpsr.mode)
  if new_mode == old_mode: return
  let new_bank  = mode_bank(new_mode)
  let old_bank  = mode_bank(old_mode)
  if new_mode == modeFIQ or old_mode == modeFIQ:
    for idx in 0..4:
      cpu.reg_banks[old_bank][idx] = cpu.r[8 + idx]
      cpu.r[8 + idx] = cpu.reg_banks[new_bank][idx]
  cpu.reg_banks[old_bank][5] = cpu.r[13]
  cpu.reg_banks[old_bank][6] = cpu.r[14]
  cpu.spsr_banks[old_bank]   = cpu.spsr.value
  cpu.r[13]         = cpu.reg_banks[new_bank][5]
  cpu.r[14]         = cpu.reg_banks[new_bank][6]
  cpu.spsr.value    = cpu.cpsr.value
  cpu.cpsr.mode     = uint32(new_mode)

proc irq*(cpu: CPU) =
  if not cpu.cpsr.irq_disable:
    let lr = cpu.r[15] - (if cpu.cpsr.thumb: 0'u32 else: 4'u32)
    cpu.switch_mode(modeIRQ)
    cpu.cpsr.thumb = false
    cpu.cpsr.irq_disable = true
    discard cpu.set_reg(14, lr)
    discard cpu.set_reg(15, 0x18'u32)

proc und*(cpu: CPU) =
  let lr = cpu.r[15] - 4'u32
  cpu.switch_mode(modeUND)
  cpu.cpsr.thumb = false
  cpu.cpsr.irq_disable = true
  discard cpu.set_reg(14, lr)
  discard cpu.set_reg(15, 0x04'u32)

proc fill_pipeline*(cpu: CPU) =
  if cpu.cpsr.thumb:
    let pc = cpu.r[15] and not 1'u32
    if cpu.pipeline.size == 0:
      cpu.pipeline.push(uint32(cpu.gba.bus.read_half(pc - 2)))
    if cpu.pipeline.size == 1:
      cpu.pipeline.push(uint32(cpu.gba.bus.read_half(pc)))
  else:
    let pc = cpu.r[15] and not 3'u32
    if cpu.pipeline.size == 0:
      cpu.pipeline.push(cpu.gba.bus.read_word(pc - 4))
    if cpu.pipeline.size == 1:
      cpu.pipeline.push(cpu.gba.bus.read_word(pc))

proc clear_pipeline*(cpu: CPU) =
  cpu.pipeline.clear()
  if cpu.cpsr.thumb:
    cpu.r[15] += 4
  else:
    cpu.r[15] += 8

proc read_instr*(cpu: CPU): uint32 =
  if cpu.pipeline.size == 0:
    if cpu.cpsr.thumb:
      cpu.r[15] = cpu.r[15] and not 1'u32
      uint32(cpu.gba.bus.read_half(cpu.r[15] - 4))
    else:
      cpu.r[15] = cpu.r[15] and not 3'u32
      cpu.gba.bus.read_word(cpu.r[15] - 8)
  else:
    cpu.pipeline.shift()

proc set_reg*(cpu: CPU; reg: int; value: uint32): uint32 {.discardable, inline.} =
  cpu.r[reg] = value
  if reg == 15: cpu.clear_pipeline()
  value

proc set_neg_and_zero_flags*(cpu: CPU; value: uint32) {.inline.} =
  cpu.cpsr.negative = bit(value, 31)
  cpu.cpsr.zero     = (value == 0)

proc step_arm*(cpu: CPU) {.inline.} =
  cpu.r[15] += 4

proc step_thumb*(cpu: CPU) {.inline.} =
  cpu.r[15] += 2

proc check_cond*(cpu: CPU; cond: uint32): bool =
  case cond
  of 0x0: cpu.cpsr.zero
  of 0x1: not cpu.cpsr.zero
  of 0x2: cpu.cpsr.carry
  of 0x3: not cpu.cpsr.carry
  of 0x4: cpu.cpsr.negative
  of 0x5: not cpu.cpsr.negative
  of 0x6: cpu.cpsr.overflow
  of 0x7: not cpu.cpsr.overflow
  of 0x8: cpu.cpsr.carry and not cpu.cpsr.zero
  of 0x9: not cpu.cpsr.carry or cpu.cpsr.zero
  of 0xA: cpu.cpsr.negative == cpu.cpsr.overflow
  of 0xB: cpu.cpsr.negative != cpu.cpsr.overflow
  of 0xC: not cpu.cpsr.zero and cpu.cpsr.negative == cpu.cpsr.overflow
  of 0xD: cpu.cpsr.zero or cpu.cpsr.negative != cpu.cpsr.overflow
  of 0xE: true
  else: false  # NV (never) - ARMv4T reserved, treated as no-op

proc lsl*(cpu: CPU; word: uint32; bits: uint32; carry_out: ptr bool): uint32 =
  log("lsl - word:" & hex_str(word) & ", bits:" & $bits)
  if bits == 0: return word
  if bits < 32:
    carry_out[] = bit(word, int(32 - bits))
    word shl bits
  elif bits == 32:
    carry_out[] = bit(word, 0)
    0'u32
  else:
    carry_out[] = false
    0'u32

proc lsr*(cpu: CPU; word: uint32; bits: uint32; immediate: bool; carry_out: ptr bool): uint32 =
  log("lsr - word:" & hex_str(word) & ", bits:" & $bits)
  var b = bits
  if b == 0:
    if not immediate: return word
    b = 32
  if b < 32:
    carry_out[] = bit(word, int(b - 1))
    word shr b
  elif b == 32:
    carry_out[] = bit(word, 31)
    0'u32
  else:
    carry_out[] = false
    0'u32

proc asr*(cpu: CPU; word: uint32; bits: uint32; immediate: bool; carry_out: ptr bool): uint32 =
  log("asr - word:" & hex_str(word) & ", bits:" & $bits)
  var b = bits
  if b == 0:
    if not immediate: return word
    b = 32
  if b <= 31:
    carry_out[] = bit(word, int(b - 1))
    (word shr b) or (0xFFFFFFFF'u32 * (word shr 31)) shl (32 - b)
  else:
    carry_out[] = bit(word, 31)
    0xFFFFFFFF'u32 * (word shr 31)

proc ror*(cpu: CPU; word: uint32; bits: uint32; immediate: bool; carry_out: ptr bool): uint32 =
  log("ror - word:" & hex_str(word) & ", bits:" & $bits)
  if bits == 0:
    if not immediate: return word
    # RRX
    let res = (word shr 1) or (uint32(cpu.cpsr.carry) shl 31)
    carry_out[] = bit(word, 0)
    return res
  var b = bits and 31
  if b == 0: b = 32  # ROR by 32
  carry_out[] = bit(word, int(b - 1))
  (word shr b) or (word shl (32 - b))

proc sub*(cpu: CPU; operand_1, operand_2: uint32; set_conditions: bool): uint32 =
  log("sub - operand_1:" & hex_str(operand_1) & ", operand_2:" & hex_str(operand_2))
  let res = operand_1 - operand_2
  if set_conditions:
    cpu.set_neg_and_zero_flags(res)
    cpu.cpsr.carry    = operand_1 >= operand_2
    cpu.cpsr.overflow = bit((operand_1 xor operand_2) and (operand_1 xor res), 31)
  res

proc sbc*(cpu: CPU; operand_1, operand_2: uint32; set_conditions: bool): uint32 =
  log("sbc - operand_1:" & hex_str(operand_1) & ", operand_2:" & hex_str(operand_2))
  let c   = uint32(cpu.cpsr.carry)
  let res = operand_1 - operand_2 - 1 + c
  if set_conditions:
    cpu.set_neg_and_zero_flags(res)
    cpu.cpsr.carry    = uint64(operand_1) >= uint64(operand_2) + 1 - uint64(c)
    cpu.cpsr.overflow = bit((operand_1 xor operand_2) and (operand_1 xor res), 31)
  res

proc add*(cpu: CPU; operand_1, operand_2: uint32; set_conditions: bool): uint32 =
  log("add - operand_1:" & hex_str(operand_1) & ", operand_2:" & hex_str(operand_2))
  let res = operand_1 + operand_2
  if set_conditions:
    cpu.set_neg_and_zero_flags(res)
    cpu.cpsr.carry    = res < operand_1
    cpu.cpsr.overflow = bit(not (operand_1 xor operand_2) and (operand_2 xor res), 31)
  res

proc adc*(cpu: CPU; operand_1, operand_2: uint32; set_conditions: bool): uint32 =
  log("adc - operand_1:" & hex_str(operand_1) & ", operand_2:" & hex_str(operand_2))
  let c   = uint32(cpu.cpsr.carry)
  let res = operand_1 + operand_2 + c
  if set_conditions:
    cpu.set_neg_and_zero_flags(res)
    cpu.cpsr.carry    = uint64(res) < uint64(operand_1) + uint64(c)
    cpu.cpsr.overflow = bit(not (operand_1 xor operand_2) and (operand_2 xor res), 31)
  res

proc tick*(cpu: CPU) =
  if not cpu.halted:
    let instr = cpu.read_instr()
    if cpu.cpsr.thumb:
      cpu.thumb_execute(instr)
    else:
      cpu.arm_execute(instr)
    let cycles = cpu.gba.bus.cycles
    cpu.gba.bus.cycles = 0
    cpu.count_cycles += cycles
    if cpu.entered_waitloop:
      cpu.gba.scheduler.fast_forward()
      cpu.entered_waitloop = false
    else:
      cpu.gba.scheduler.tick(cycles)
  else:
    cpu.gba.scheduler.fast_forward()
