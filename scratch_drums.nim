import std/[os, strutils, math, streams]
import dingbat/gba/gba
import dingbat/common/test_output

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  if not emu.load_state(paramStr(2)):
    echo "LOAD STATE FAILED"; quit(1)
  emu.mp2k_hle = true
  if getEnv("DINGBAT_RSMODE") != "": emu.mp2k.resample_mode = parseInt(getEnv("DINGBAT_RSMODE"))
  if getEnv("DINGBAT_ENVMODE") != "": emu.mp2k.env_mode = parseInt(getEnv("DINGBAT_ENVMODE"))
  if getEnv("DINGBAT_DBDELAY") != "": emu.mp2k.db_delay = parseInt(getEnv("DINGBAT_DBDELAY"))
  let frames = if paramCount() >= 3: parseInt(paramStr(3)) else: 150
  for _ in 0 ..< frames: emu.step_frame()
  mp2k_write_wav("/tmp/mp2k_drums.wav")
  block:
    let s = newFileStream("/tmp/mp2k_real.wav", fmWrite)
    let nn = realDmaCapture.len
    s.write("RIFF"); s.write(uint32(36 + nn*2)); s.write("WAVE")
    s.write("fmt "); s.write(uint32(16)); s.write(uint16(1)); s.write(uint16(2))
    s.write(uint32(32768)); s.write(uint32(32768*4)); s.write(uint16(4)); s.write(uint16(16))
    s.write("data"); s.write(uint32(nn*2))
    for v in realDmaCapture: s.write(v)
    s.close()
  proc rms(s: seq[int16]): float =
    if s.len == 0: return 0
    var a = 0.0
    for v in s: a += float(v) * float(v)
    sqrt(a / float(s.len))
  echo "engaged=", emu.mp2k.engaged, "  retriggers=", dbgRetrigCount,
       "  hook_fires=", emu.mp2k.dbg_hook_fires,
       "  reverb=", emu.mp2k.reverb_strength, "  period=", emu.mp2k.rev_period,
       "  mono=", emu.mp2k.mono_mode
  echo "HLE rms=", rms(mp2kWavCapture), "  REAL rms=", rms(realDmaCapture)

main()
