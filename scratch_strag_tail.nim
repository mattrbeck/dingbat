# Reverb tail decay A/B: force SoundInfo.reverb, let music play, then zero all
# SoundChannel right/leftVolume every frame from a cut frame — voices then mix
# silence and both reverbs decay from their ring content alone. Prints per-
# frame RMS of REAL vs HLE captures through the tail.
#   nim c -d:danger -d:mp2kwav -d:test_harness --mm:arc -o:/tmp/strag_tail --path:src scratch_strag_tail.nim
#   /tmp/strag_tail <rom> <reverb> <cut_frame> <frames>
import std/[os, strutils, math]
import dingbat/gba/gba
import dingbat/common/test_output

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = true
  let rev = parseInt(paramStr(2))
  let cutf = parseInt(paramStr(3))
  let frames = parseInt(paramStr(4))
  var lastN = 0
  for f in 0 ..< frames:
    let sip = emu.bus.read_word_internal(0x03007FF0'u32)
    if (sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32:
      if emu.bus.read_word_internal(sip) != 0:
        emu.bus.write_byte_internal(sip + 5'u32, uint8(rev))
        if f >= cutf:
          for c in 0 ..< 12:
            let base = sip + uint32(0x50 + c*64)
            emu.bus.write_byte_internal(base + 2'u32, 0'u8)
            emu.bus.write_byte_internal(base + 3'u32, 0'u8)
    emu.step_frame()
    let n = min(mp2kWavCapture.len, realDmaCapture.len)
    if f >= cutf - 5 and n > lastN:
      var re, he: float
      var cnt = 0
      var i = lastN
      while i < n:
        re += float(realDmaCapture[i])*float(realDmaCapture[i])
        he += float(mp2kWavCapture[i])*float(mp2kWavCapture[i])
        cnt.inc
        i.inc
      echo f, "\t", sqrt(re/float(cnt)).formatFloat(ffDecimal,3), "\t",
        sqrt(he/float(cnt)).formatFloat(ffDecimal,3)
    lastN = n

main()
