# Boot-from-power-on MP2K detection harness: no save state needed. Boots the
# ROM with the HLE BIOS for N frames (games init their sound engine early) and
# reports whether the MP2K HLE engaged, the learned hook address, hook fire
# count, and HLE vs REAL DirectSound RMS.
#   nim c -d:danger -d:mp2kwav -d:test_harness --mm:arc -o:scratch_mp2k_boot --path:src scratch_mp2k_boot.nim
#   ./scratch_mp2k_boot <rom> [frames=600]
import std/[os, strutils, math]
import dingbat/gba/gba
import dingbat/common/test_output

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = getEnv("DINGBAT_NOHLE") != "1"
  let frames = if paramCount() >= 2: parseInt(paramStr(2)) else: 600
  for _ in 0 ..< frames: emu.step_frame()
  proc rms(s: seq[int16]): float =
    if s.len == 0: return 0
    var a = 0.0
    for v in s: a += float(v) * float(v)
    sqrt(a / float(s.len))
  echo "engaged=", emu.mp2k.engaged,
       "  hook=", toHex(emu.mp2k.hook_addr),
       "  hook_fires=", emu.mp2k.dbg_hook_fires
  echo "HLE rms=", rms(mp2kWavCapture), "  REAL rms=", rms(realDmaCapture)

main()
