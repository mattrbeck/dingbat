# Boot a ROM for N frames and save a state — used to regenerate save-state
# fixtures for the scratch_drums harness.
#   ./scratch_mkstate <rom> <out.state> [frames=600]
import std/[os, strutils]
import dingbat/gba/gba
import dingbat/common/test_output

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  let frames = if paramCount() >= 3: parseInt(paramStr(3)) else: 600
  for _ in 0 ..< frames: emu.step_frame()
  if not emu.save_state(paramStr(2)):
    echo "SAVE STATE FAILED"; quit(1)
  echo "saved ", paramStr(2), " after ", frames, " frames"

main()
