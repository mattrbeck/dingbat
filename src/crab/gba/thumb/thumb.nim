# THUMB instruction LUT (included by gba.nim, must come after all THUMB handler includes)
# Builds a 1024-entry compile-time dispatch table indexed by bits 15..6 of the instruction.

proc thumb_unimplemented*(cpu: CPU; instr: uint32) =
  raise newException(Exception, "Unimplemented THUMB instruction: " & hex_str(uint16(instr)))

macro thumbLutBuilder(): untyped =
  result = newTree(nnkBracket)
  for i in 0'u32 ..< 1024'u32:
    result.add:
      checkBits i:
      of "1111......": call("thumb_long_branch_link")
      of "11100.....": call("thumb_unconditional_branch")
      of "11011111..": call("thumb_software_interrupt")
      of "1101......": call("thumb_conditional_branch")
      of "1100......": call("thumb_multiple_load_store")
      of "1011.10...": call("thumb_push_pop_registers")
      of "10110000..": call("thumb_add_offset_to_stack_pointer")
      of "1010......": call("thumb_load_address")
      of "1001......": call("thumb_sp_relative_load_store")
      of "1000......": call("thumb_load_store_halfword")
      of "011.......": call("thumb_load_store_immediate_offset")
      of "0101..1...": call("thumb_load_store_sign_extended")
      of "0101..0...": call("thumb_load_store_register_offset")
      of "01001.....": call("thumb_pc_relative_load")
      of "010001....": call("thumb_high_reg_branch_exchange")
      of "010000....": call("thumb_alu_operations")
      of "001.......": call("thumb_move_compare_add_subtract")
      of "00011.....": call("thumb_add_subtract")
      of "000.......": call("thumb_move_shifted_register")
      else:            call("thumb_unimplemented")

{.push warning[UnreachableCode]: off.}
const thumbLut = thumbLutBuilder()
{.pop.}

proc thumb_execute*(cpu: CPU; instr: uint32) =
  thumbLut[instr shr 6](cpu, instr)
