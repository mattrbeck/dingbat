# ARM instruction LUT (included by gba.nim, must come after all ARM handler includes)
# Builds a 4096-entry compile-time dispatch table indexed by
# bits 27..20 and 7..4 of the instruction word.

macro armLutBuilder(): untyped =
  result = newTree(nnkBracket)
  for i in 0'u32 ..< 4096'u32:
    result.add:
      checkBits i:
      of "000000..1001": call("arm_multiply")
      of "00001...1001": call("arm_multiply_long")
      of "00010.001001": call("arm_single_data_swap")
      of "000100100001": call("arm_branch_exchange")
      of "000..1..1..1": call("arm_halfword_data_transfer_immediate")
      of "000..0..1..1": call("arm_halfword_data_transfer_register")
      of "011........1": call("arm_unimplemented")  # undefined instruction
      of "01..........": call("arm_single_data_transfer")
      of "100.........": call("arm_block_data_transfer")
      of "101.........": call("arm_branch")
      of "110.........": call("arm_unimplemented")  # coprocessor data transfer
      of "1110.......0": call("arm_unimplemented")  # coprocessor data operation
      of "1110.......1": call("arm_unimplemented")  # coprocessor register transfer
      of "1111........": call("arm_software_interrupt")
      of "00.10..0....": call("arm_psr_transfer")
      of "00..........": call("arm_data_processing")
      else:              call("arm_unused")

{.push warning[UnreachableCode]: off.}
const armLut = armLutBuilder()
{.pop.}

proc arm_execute*(cpu: CPU; instr: uint32) =
  if cpu.check_cond(bits_range(instr, 28, 31)):
    let hash = (instr shr 16 and 0x0FF0'u32) or (instr shr 4 and 0xF'u32)
    armLut[hash](cpu, instr)
  else:
    log("Skipping instruction, cond: " & hex_str(uint8(instr shr 28)))
    cpu.step_arm()
