# ARM PSR transfer (MRS/MSR) (included by gba.nim)

proc arm_psr_transfer*(cpu: CPU; instr: uint32) =
  let spsr  = bit(instr, 22)
  let mode  = CpuMode(cpu.cpsr.mode)
  let has_spsr = mode != modeUSR and mode != modeSYS
  if bit(instr, 21):  # MSR
    var mask: uint32 = 0
    if bit(instr, 19): mask = mask or 0xFF000000'u32
    if bit(instr, 18): mask = mask or 0x00FF0000'u32
    if bit(instr, 17): mask = mask or 0x0000FF00'u32
    if bit(instr, 16): mask = mask or 0x000000FF'u32
    var value: uint32
    if bit(instr, 25):
      var carry_out = false
      value = cpu.immediate_offset(bits_range(instr, 0, 11), addr carry_out)
    else:
      value = cpu.r[int(bits_range(instr, 0, 3))]
    value = value and mask
    if spsr:
      if has_spsr:
        cpu.spsr = cast[PSR]((uint32(cpu.spsr) and not mask) or value)
    else:
      let thumb = cpu.cpsr.thumb
      if (mask and 0xFF) > 0:
        cpu.switch_mode(CpuMode(value and 0x1F'u32))
      cpu.cpsr = cast[PSR]((uint32(cpu.cpsr) and not mask) or value)
      cpu.cpsr.thumb = thumb
  else:  # MRS
    let rd = int(bits_range(instr, 12, 15))
    if spsr and has_spsr:
      discard cpu.set_reg(rd, uint32(cpu.spsr))
    else:
      discard cpu.set_reg(rd, uint32(cpu.cpsr))
  if not (not bit(instr, 21) and bits_range(instr, 12, 15) == 15):
    cpu.step_arm()
