## Boot a ROM from power-on, run N frames, and save a state — regenerates a
## test save state for the drum/resync harnesses (the original hand-placed
## state was deleted in a Downloads cleanup).
import std/[os, strutils]
import dingbat/gba/gba
import dingbat/common/test_output

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  let frames = if paramCount() >= 3: parseInt(paramStr(3)) else: 1800
  for _ in 0 ..< frames: emu.step_frame()
  if not emu.save_state(paramStr(2)):
    echo "SAVE STATE FAILED"; quit(1)
  echo "saved ", paramStr(2), " after ", frames, " frames"

main()
