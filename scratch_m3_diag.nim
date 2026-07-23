# Mother 3 MP2K-detection diagnostic: boots the ROM, taps START/A periodically
# to get past intro screens, and dumps the SOUND_INFO_PTR slot + ident magic +
# detection state every 60 frames.
#   nim c -d:danger -d:mp2kwav -d:test_harness --mm:arc -o:BIN --path:src scratch_m3_diag.nim
#   ./scratch_m3_diag <rom> [frames=1800]
import std/[os, strutils, math, streams]
import dingbat/gba/gba
import dingbat/common/test_output
import dingbat/common/input as dinput

proc write_ppm(path: string; buf: seq[uint16]) =
  var f = open(path, fmWrite)
  f.write("P6\n240 160\n255\n")
  for pixel in buf:
    let r5 = uint8(pixel and 0x1F); let g5 = uint8((pixel shr 5) and 0x1F)
    let b5 = uint8((pixel shr 10) and 0x1F)
    f.write(char((r5 shl 3) or (r5 shr 2)))
    f.write(char((g5 shl 3) or (g5 shr 2)))
    f.write(char((b5 shl 3) or (b5 shr 2)))
  f.close()

proc main() =
  let emu = new_gba("", paramStr(1), run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.mp2k_hle = getEnv("DINGBAT_NOHLE") != "1"
  let frames = if paramCount() >= 2: parseInt(paramStr(2)) else: 1800
  for f in 0 ..< frames:
    # Tap START then A repeatedly (gets through title + accepts naming-screen
    # defaults: START jumps the cursor to OK, A confirms).
    let phase = f mod 180
    emu.keypad.handle_input(START, phase >= 0 and phase < 5)
    emu.keypad.handle_input(A, phase >= 90 and phase < 95)
    emu.step_frame()
    if getEnv("DINGBAT_SHOTS") != "" and f mod 300 == 299:
      write_ppm(getEnv("DINGBAT_SHOTS") & "/f" & $f & ".ppm", emu.ppu.framebuffer)
    if f == 700 or f == 3000:
      let sip = emu.bus.read_word_internal(0x03007FF0'u32)
      var hexdump = "SoundInfo[0..0x20): "
      for off in 0'u32 ..< 0x20'u32:
        hexdump.add toHex(emu.bus.read_byte_internal(sip + off)) & " "
      echo hexdump
    if f mod 60 == 59:
      let sip = emu.bus.read_word_internal(0x03007FF0'u32)
      var ident = 0'u32
      if (sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32:
        ident = emu.bus.read_word_internal(sip)
      echo "f=", f, " sip=", toHex(sip), " ident=", toHex(ident),
           " engaged=", emu.mp2k.engaged, " hook=", toHex(emu.mp2k.hook_addr),
           " fires=", emu.mp2k.dbg_hook_fires, " probing=", emu.mp2k.probing,
           " fails=", emu.mp2k.probe_fails,
           " reverb=", emu.mp2k.reverb_strength, " period=", emu.mp2k.rev_period,
           " mono=", emu.mp2k.mono_mode, " pcmrate=", emu.mp2k.pcm_sample_rate
  proc rms(s: seq[int16]): float =
    if s.len == 0: return 0
    var a = 0.0
    for v in s: a += float(v) * float(v)
    sqrt(a / float(s.len))
  echo "HLE rms=", rms(mp2kWavCapture), "  REAL rms=", rms(realDmaCapture)
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

main()
