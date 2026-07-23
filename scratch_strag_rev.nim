# Reverb-model A/B: boot a ROM, force SoundInfo.reverb to a given value every
# frame (the driver reads it per mixer pass), and report span-matched HLE/REAL
# RMS over the tail of the run. A faithful reverb model keeps the ratio flat
# across forced values.
#   nim c -d:danger -d:mp2kwav -d:test_harness --mm:arc -o:/tmp/strag_rev --path:src scratch_strag_rev.nim
#   /tmp/strag_rev <rom> <frames> <reverb 0..127 | -1 = leave alone> [measure_from_frame]
import std/[os, strutils, math, streams]
import dingbat/gba/gba
import dingbat/common/test_output

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = true
  let frames = parseInt(paramStr(2))
  let rev = parseInt(paramStr(3))
  let fromf = if paramCount() >= 4: parseInt(paramStr(4)) else: 120
  var mark = 0
  for f in 0 ..< frames:
    if rev >= 0:
      let sip = emu.bus.read_word_internal(0x03007FF0'u32)
      if (sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32:
        let ident = emu.bus.read_word_internal(sip)
        if ident != 0:
          emu.bus.write_byte_internal(sip + 5'u32, uint8(rev))
    emu.step_frame()
    if f == fromf: mark = min(mp2kWavCapture.len, realDmaCapture.len)
  proc rmsFrom(s: seq[int16]; i0: int): float =
    if s.len <= i0: return 0
    var a = 0.0
    for i in i0 ..< s.len: a += float(s[i]) * float(s[i])
    sqrt(a / float(s.len - i0))
  let hr = rmsFrom(mp2kWavCapture, mark)
  let rr = rmsFrom(realDmaCapture, mark)
  echo "rev=", rev, " HLE=", hr.formatFloat(ffDecimal,3), " REAL=", rr.formatFloat(ffDecimal,3),
    " ratio=", (if rr > 0: hr/rr else: 0.0).formatFloat(ffDecimal,4),
    " n=", mp2kWavCapture.len - mark,
    " dbg_rev=", int(emu.mp2k.dbg_reverb), " trig=", emu.mp2k.dbg_overlay_triggers
  let outp = getEnv("DINGBAT_REV_DUMP")
  if outp != "":
    proc raw(path: string; s: seq[int16]) =
      let st = newFileStream(path, fmWrite)
      for v in s: st.write(v)
      st.close()
    raw(outp & "_hle.raw", mp2kWavCapture)
    raw(outp & "_real.raw", realDmaCapture)

main()
