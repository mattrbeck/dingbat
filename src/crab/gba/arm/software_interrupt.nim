# ARM software interrupt (SWI) (included by gba.nim)

proc hle_swi*(cpu: CPU; swi_num: uint32) =
  ## HLE BIOS dispatch for the most common GBA SWI calls.
  ## Only used when no real BIOS file is provided.
  case swi_num
  of 0x02, 0x06:  # Halt / Halt2
    cpu.halted = true
  of 0x04:  # IntrWait(discard_flags, intr_flags)
    let discard_flags = cpu.r[0]
    let intr_mask = uint16(cpu.r[1])
    if discard_flags != 0:
      cpu.gba.interrupts.reg_if.value =
        cpu.gba.interrupts.reg_if.value and not intr_mask
    cpu.gba.interrupts.reg_ie.value =
      cpu.gba.interrupts.reg_ie.value or intr_mask
    cpu.halted = true
  of 0x05:  # VBlankIntrWait
    cpu.gba.interrupts.reg_if.vblank = false
    cpu.gba.interrupts.reg_ie.vblank = true
    cpu.halted = true
  else:
    discard  # unimplemented SWI: return immediately (no-op)

proc arm_software_interrupt*(cpu: CPU; instr: uint32) =
  if cpu.gba.bios_path == "":
    # HLE mode: handle SWI in Nim, then continue past the SWI instruction
    let swi_num = bits_range(instr, 16, 23)
    cpu.hle_swi(swi_num)
    cpu.step_arm()
  else:
    let lr = cpu.r[15] - 4
    cpu.switch_mode(modeSVC)
    discard cpu.set_reg(14, lr)
    cpu.cpsr.irq_disable = true
    discard cpu.set_reg(15, 0x08'u32)
