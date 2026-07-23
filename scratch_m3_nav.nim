# Scripted navigation harness (Mother 3 progression): boot a ROM (optionally
# loading a state first), feed a button script, dump periodic screenshots and
# the engine reverb byte, and optionally save a state at the end.
#   ./scratch_m3_nav <rom> <frames> [--state=IN] [--save=OUT] [--script=FILE]
#     [--shots=DIR] [--shotevery=N]
# Script file lines: "<frame> <button> <hold_frames>", buttons UP/DOWN/LEFT/
# RIGHT/A/B/SELECT/START/L/R. Lines starting with # are ignored.
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

proc parse_btn(s: string): Input =
  case s
  of "UP": UP
  of "DOWN": DOWN
  of "LEFT": LEFT
  of "RIGHT": RIGHT
  of "A": A
  of "B": B
  of "SELECT": SELECT
  of "START": START
  of "L": L
  else: R

proc main() =
  var rom = ""; var frames = 600
  var statein = ""; var saveout = ""; var script = ""; var shots = ""
  var shotevery = 300
  var forcereverb = -1
  var positional = 0
  for arg in commandLineParams():
    if arg.startsWith("--forcereverb="): forcereverb = parseInt(arg[14 .. ^1])
    elif arg.startsWith("--state="): statein = arg[8 .. ^1]
    elif arg.startsWith("--save="): saveout = arg[7 .. ^1]
    elif arg.startsWith("--script="): script = arg[9 .. ^1]
    elif arg.startsWith("--shots="): shots = arg[8 .. ^1]
    elif arg.startsWith("--shotevery="): shotevery = parseInt(arg[12 .. ^1])
    else:
      if positional == 0: rom = arg else: frames = parseInt(arg)
      inc positional
  let emu = new_gba("", rom, run_bios = false, use_hle = true)
  emu.test_output = new_test_output()
  emu.post_init()
  if statein != "":
    if not emu.load_state(statein): echo "LOAD STATE FAILED"; quit(1)
  emu.mp2k_hle = true
  # events[frame] = (button, hold)
  var press: array[10, int]   # frames remaining held, per Input
  var evs: seq[(int, Input, int)] = @[]
  if script != "":
    for line in lines(script):
      let l = line.strip()
      if l.len == 0 or l[0] == '#': continue
      let p = l.splitWhitespace()
      evs.add (parseInt(p[0]), parse_btn(p[1]), parseInt(p[2]))
  var last_rev = 255'u8
  for f in 0 ..< frames:
    for (ef, eb, eh) in evs:
      if ef == f: press[ord(eb)] = eh
    for b in Input:
      emu.keypad.handle_input(b, press[ord(b)] > 0)
      if press[ord(b)] > 0: dec press[ord(b)]
    if forcereverb >= 0:
      # Controlled A/B experiment: poke SoundInfo.reverb (+5, the byte the
      # real SoundMainRAM reads each pass and the HLE consumes at the same
      # hook) so the REAL driver runs its own reverb path on demand.
      let sip = emu.bus.read_word_internal(0x03007FF0'u32)
      if (sip shr 24) == 0x02'u32 or (sip shr 24) == 0x03'u32:
        if emu.bus.read_word_internal(sip) == 0x68736D53'u32:
          emu.bus[sip + 5] = uint8(forcereverb)
    emu.step_frame()
    if emu.mp2k.reverb_strength != last_rev:
      echo "f=", f, " reverb=", emu.mp2k.reverb_strength
      last_rev = emu.mp2k.reverb_strength
    if shots != "" and f mod shotevery == shotevery - 1:
      write_ppm(shots & "/f" & $f & ".ppm", emu.ppu.framebuffer)
  if shots != "":
    write_ppm(shots & "/final.ppm", emu.ppu.framebuffer)
  if saveout != "":
    if not emu.save_state(saveout): echo "SAVE STATE FAILED"; quit(1)
    echo "saved ", saveout
  proc rms(s: seq[int16]): float =
    if s.len == 0: return 0
    var a = 0.0
    for v in s: a += float(v) * float(v)
    sqrt(a / float(s.len))
  echo "engaged=", emu.mp2k.engaged, " reverb=", emu.mp2k.reverb_strength,
       " period=", emu.mp2k.rev_period, " mono=", emu.mp2k.mono_mode
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
