# Dump a region of guest RAM (after booting N frames) to a binary file, plus
# report the learned mixer hook address.
#   /tmp/strag_dumpram <rom> <frames> <addr_hex> <len_hex> <out>
import std/[os, strutils, streams]
import dingbat/gba/gba
import dingbat/common/test_output

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = true
  let frames = parseInt(paramStr(2))
  let a0 = fromHex[uint32](paramStr(3))
  let ln = fromHex[uint32](paramStr(4))
  for _ in 0 ..< frames: emu.step_frame()
  let st = newFileStream(paramStr(5), fmWrite)
  for i in 0'u32 ..< ln:
    st.write(emu.bus.read_byte_internal(a0 + i))
  st.close()
  echo "hook=", toHex(emu.mp2k.hook_addr, 8), " entry=", toHex(emu.mp2k.entry_addr, 8)

main()
