# THUMB software interrupt (SWI) (included by gba.nim)

proc thumb_software_interrupt*(cpu: CPU; instr: uint32) =
  if cpu.gba.bios_path == "":
    # HLE mode: handle SWI in Nim, then continue past the SWI instruction
    let swi_num = bits_range(instr, 0, 7)
    cpu.hle_swi(swi_num)
    cpu.step_thumb()
  else:
    let lr = cpu.r[15] - 2
    cpu.switch_mode(modeSVC)
    discard cpu.set_reg(14, lr)
    cpu.cpsr.irq_disable = true
    cpu.cpsr.thumb = false
    discard cpu.set_reg(15, 0x08'u32)
