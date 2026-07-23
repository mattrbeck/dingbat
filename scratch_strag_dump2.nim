# Dump both HLE and REAL capture buffers as raw s16le interleaved-stereo files
# for offline analysis.
#   nim c -d:danger -d:mp2kwav -d:test_harness --mm:arc -o:/tmp/strag_dump2 --path:src scratch_strag_dump2.nim
#   /tmp/strag_dump2 <rom> <frames> <outprefix>
import std/[os, strutils, streams]
import dingbat/gba/gba
import dingbat/common/test_output

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = true
  let frames = parseInt(paramStr(2))
  let prefix = paramStr(3)
  for _ in 0 ..< frames: emu.step_frame()
  proc raw(path: string; s: seq[int16]) =
    let st = newFileStream(path, fmWrite)
    for v in s: st.write(v)
    st.close()
  raw(prefix & "_hle.raw", mp2kWavCapture)
  raw(prefix & "_real.raw", realDmaCapture)
  echo "n=", mp2kWavCapture.len, " ", realDmaCapture.len

main()
