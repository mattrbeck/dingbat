# ARM helpers (included by gba.nim)

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
