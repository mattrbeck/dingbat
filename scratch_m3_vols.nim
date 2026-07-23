# Live per-channel volume-relationship dump: every N frames, print each active
# DirectSound channel's envelopeVolume(+9), envelopeVolumeRight(+0x0A),
# envelopeVolumeLeft(+0x0B), rightVolume(+2), leftVolume(+3), plus SoundInfo
# masterVolume/maxChans — to compare the evr ~= evol*rV>>8 relation across
# engine vintages (stock Emerald vs Mother 3's modified driver).
#   nim c -d:danger -d:mp2kwav -d:test_harness --mm:arc -o:BIN --path:src scratch_m3_vols.nim
#   ./scratch_m3_vols <rom> <frames> [--state=IN] [--every=N] [--tapstart]
import std/[os, strutils, math]
import dingbat/gba/gba
import dingbat/common/test_output
import dingbat/common/input as dinput

proc main() =
  var rom = ""; var frames = 900; var every = 30
  var statein = ""; var tapstart = false
  var positional = 0
  for arg in commandLineParams():
    if arg.startsWith("--state="): statein = arg[8 .. ^1]
    elif arg.startsWith("--every="): every = parseInt(arg[8 .. ^1])
    elif arg == "--tapstart": tapstart = true
    else:
      if positional == 0: rom = arg else: frames = parseInt(arg)
      inc positional
  let emu = new_gba("", rom, run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  if statein != "":
    if not emu.load_state(statein): echo "LOAD STATE FAILED"; quit(1)
  emu.mp2k_hle = true
  for f in 0 ..< frames:
    if tapstart:
      let phase = f mod 180
      emu.keypad.handle_input(START, phase >= 0 and phase < 5)
      emu.keypad.handle_input(A, phase >= 90 and phase < 95)
    emu.step_frame()
    if f mod every == every - 1:
      let sip = emu.bus.read_word_internal(0x03007FF0'u32)
      if (sip shr 24) != 0x02'u32 and (sip shr 24) != 0x03'u32: continue
      let ident = emu.bus.read_word_internal(sip)
      if ident != 0x68736D53'u32 and ident != 0x68736D54'u32: continue
      let maxc = int(emu.bus.read_byte_internal(sip + 6))
      let mvol = int(emu.bus.read_byte_internal(sip + 7))
      var line = "f=" & $f & " master=" & $mvol & " maxc=" & $maxc & " |"
      for i in 0 ..< min(maxc, 12):
        let base = sip + uint32(0x50 + i * 64)
        let st = emu.bus.read_byte_internal(base + 0)
        if (st and 0xC7'u8) == 0: continue
        let evol = int(emu.bus.read_byte_internal(base + 9))
        let evr = int(emu.bus.read_byte_internal(base + 0x0A))
        let evl = int(emu.bus.read_byte_internal(base + 0x0B))
        let rv = int(emu.bus.read_byte_internal(base + 2))
        let lv = int(emu.bus.read_byte_internal(base + 3))
        # stock prediction: evr = evol*rv shr 8
        let prR = (evol * rv) shr 8
        let prL = (evol * lv) shr 8
        line.add " ch" & $i & "[st=" & toHex(st) & " ev=" & $evol &
          " rV=" & $rv & " lV=" & $lv & " evr=" & $evr & "(pred " & $prR &
          ") evl=" & $evl & "(pred " & $prL & ")]"
      echo line
  proc rms(s: seq[int16]): float =
    if s.len == 0: return 0
    var a = 0.0
    for v in s: a += float(v) * float(v)
    sqrt(a / float(s.len))
  echo "engaged=", emu.mp2k.engaged, " mono=", emu.mp2k.mono_mode
  echo "HLE rms=", rms(mp2kWavCapture), "  REAL rms=", rms(realDmaCapture)

main()
