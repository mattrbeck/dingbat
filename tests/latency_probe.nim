# Headless input-latency probe: how many emulated frames pass between a
# keypress (applied at a frame boundary, exactly like the frontends do) and
# the first framebuffer that differs because of it?
#
# Method: run two identical GBA cores through the same warmup, press a key in
# one of them only, then step both in lockstep and report the first frame
# index (1 = the very next frame) where their framebuffers diverge. Works on
# animated screens too, since the control core animates identically.
#
# Usage: latency_probe <rom> [warmup=300] [input=A] [hold=60]
import std/[os, strutils]
import dingbat/gba/gba
import dingbat/common/input

proc fb_hash(fb: seq[uint16]): uint32 =
  result = 0x811C9DC5'u32
  for v in fb:
    result = (result xor uint32(v and 0xFF)) * 0x01000193'u32
    result = (result xor uint32(v shr 8)) * 0x01000193'u32

proc main() =
  if paramCount() < 1:
    echo "usage: latency_probe <rom> [warmup] [input] [hold]"
    quit 1
  let rom = paramStr(1)
  let warmup = if paramCount() >= 2: parseInt(paramStr(2)) else: 300
  let inp = if paramCount() >= 3: parseEnum[Input](paramStr(3)) else: A
  let hold = if paramCount() >= 4: parseInt(paramStr(4)) else: 60

  proc make(): GBA =
    result = new_gba("", rom, run_bios = false, use_hle = true)
    result.post_init()

  let pressed = make()
  let control = make()
  for wf in 0 ..< warmup:
    pressed.step_frame()
    control.step_frame()
  if fb_hash(pressed.ppu.framebuffer) != fb_hash(control.ppu.framebuffer):
    echo "NONDETERMINISTIC: cores diverged during warmup; results invalid"
    quit 2

  # Press in one core only, at the frame boundary (vblank start), exactly
  # where the frontends apply input between step_frame calls.
  pressed.handle_input(inp, true)
  var released = false
  var pram_frame = 0
  var seen_frame = 0
  for frame in 1 .. hold * 2:
    if frame > hold and not released:
      pressed.handle_input(inp, false)
      released = true
    keyinput_reads = 0
    keyinput_last_read = 0xFFFF'u16
    pressed.step_frame()
    if seen_frame == 0:
      if keyinput_reads > 0 and (keyinput_last_read and 0x3FF) != 0x3FF:
        seen_frame = frame
        echo "game read pressed KEYINPUT during frame ", frame,
             " (reads this frame: ", keyinput_reads, ")"
      elif keyinput_reads == 0:
        echo "frame ", frame, ": no KEYINPUT reads"
    control.step_frame()
    if pram_frame == 0 and pressed.ppu.pram != control.ppu.pram:
      pram_frame = frame
      echo "PRAM diverged at frame ", frame
    if fb_hash(pressed.ppu.framebuffer) != fb_hash(control.ppu.framebuffer):
      echo "DIVERGED at frame ", frame, " after press (1 = next frame)"
      quit 0
  echo "NO DIVERGENCE within ", hold * 2, " frames — input ", inp,
       " may not affect this screen (try more warmup or another key)"
  quit 3

main()
