# ARM multiply long (UMULL/UMLAL/SMULL/SMLAL) (included by gba.nim)

proc arm_multiply_long*(cpu: CPU; instr: uint32) =
  let signed        = bit(instr, 22)
  let accumulate    = bit(instr, 21)
  let set_conditions = bit(instr, 20)
  let rdhi          = int(bits_range(instr, 16, 19))
  let rdlo          = int(bits_range(instr, 12, 15))
  let rs            = int(bits_range(instr, 8, 11))
  let rm            = int(bits_range(instr, 0, 3))
  var res: uint64 =
    if signed:
      cast[uint64](int64(cast[int32](cpu.r[rm])) * int64(cast[int32](cpu.r[rs])))
    else:
      uint64(cpu.r[rm]) * uint64(cpu.r[rs])
  if accumulate:
    res += (uint64(cpu.r[rdhi]) shl 32) or uint64(cpu.r[rdlo])
  discard cpu.set_reg(rdhi, uint32(res shr 32))
  discard cpu.set_reg(rdlo, uint32(res))
  if set_conditions:
    cpu.cpsr.negative = bit(cpu.r[rdhi], 31)
    cpu.cpsr.zero     = (res == 0)
  if rdhi != 15 and rdlo != 15: cpu.step_arm()
