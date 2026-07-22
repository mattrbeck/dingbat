import std/[os, strutils, math]
import dingbat/gba/gba
import dingbat/common/test_output
import dingbat/common/input

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = true
  let frames = parseInt(paramStr(2))
  # Optional: mash START+A to advance past title screens into gameplay music,
  # which is where BDPCM (compressed) instruments tend to show up. Enabled when
  # a 3rd arg "drive" is passed. Also let capture start after a warmup so intro
  # jingles don't dominate the A/B RMS.
  let drive = paramCount() >= 3 and paramStr(3) == "drive"
  for f in 0 ..< frames:
    if drive:
      # press for a few frames, release, cycling A then START
      let phase = (f div 8) mod 4
      let btn = (if (f div 32) mod 2 == 0: A else: START)
      let down = phase < 2
      emu.keypad.handle_input(btn, down)
    emu.step_frame()
  mp2k_write_wav("/tmp/mp2k_hle.wav")
  proc rms(s: seq[int16]): float =
    if s.len == 0: return 0
    var acc = 0.0
    for v in s: acc += float(v) * float(v)
    sqrt(acc / float(s.len))
  proc peak(s: seq[int16]): int =
    for v in s: result = max(result, abs(int(v)))
  proc zcr(s: seq[int16]): float =
    # zero crossings per second over the L channel (interleaved stereo)
    if s.len < 4: return 0
    var cross = 0
    var i = 2
    while i < s.len:
      if (s[i-2] >= 0) != (s[i] >= 0): cross.inc
      i += 2
    float(cross) / (float(s.len div 2) / 32768.0)
  echo "engaged=", emu.mp2k.engaged
  echo "compressed_skipped=", emu.mp2k.compressed_skipped, " compressed_used=", emu.mp2k.dbg_compressed_used
  echo "reverb=", int(emu.mp2k.dbg_reverb), " pcm_rate=", emu.mp2k.dbg_pcm_rate
  echo "HLE  : rms=", rms(mp2kWavCapture), " peak=", peak(mp2kWavCapture), " n=", mp2kWavCapture.len, " zcr=", zcr(mp2kWavCapture)
  echo "REAL : rms=", rms(realDmaCapture), " peak=", peak(realDmaCapture), " n=", realDmaCapture.len, " zcr=", zcr(realDmaCapture)
  echo "gain-to-match(rms) = ", (if rms(mp2kWavCapture) > 0: rms(realDmaCapture)/rms(mp2kWavCapture) else: 0.0)

main()
