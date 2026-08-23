## Frames-per-emulated-second probe for dingbat's GB/GBC core.
##
## Usage: dingbat_gb_fps <rom> <bootromdir|none> <frames> [skip] [script] [window]
##
## Counts step_frame presents against the panel dot clock (4194304 Hz), the
## same definition sameboy_fps.c uses, so the two can be compared directly.
## Hardware presents
## 4194304 / 70224 = 59.7275 frames per second of emulated time whenever the
## LCD stays on for the whole run.
##
## `script` is the nav runners' input format (FRAME:KEY[:HOLD],...), with frame
## numbers counted from power-on. `window` > 0 prints a per-window fps line.
##
## Build: nim c -d:release -d:gb_dot_counter --path:src \
##            -o:tools/gbfuzz/dingbat_gb_fps tools/gbfuzz/dingbat_gb_fps.nim

import std/[os, strutils, strformat]
import dingbat/gb/gb
import dingbat/common/input

type InputEvent = tuple[frame: int, key: Input, pressed: bool]

proc parse_script(script: string): seq[InputEvent] =
  for entry in script.split(','):
    if entry.len == 0: continue
    let parts = entry.split(':')
    let frame = parseInt(parts[0])
    let key = parseEnum[Input](parts[1].toUpperAscii())
    let hold = if parts.len > 2: parseInt(parts[2]) else: 10
    result.add((frame, key, true))
    result.add((frame + hold, key, false))

proc main() =
  let args = commandLineParams()
  if args.len < 3:
    echo "Usage: dingbat_gb_fps <rom> <bootromdir|none> <frames> [skip] [script] [window]"
    quit(2)
  let rom_path = args[0]
  let bootdir = args[1]
  let want = parseInt(args[2])
  let skip = if args.len > 3: parseInt(args[3]) else: 0
  let script = if args.len > 4: parse_script(args[4]) else: @[]
  let window = if args.len > 5: parseInt(args[5]) else: 0
  let fifo = getEnv("GBFUZZ_SCANLINE") == ""

  let run_bios = getEnv("GBFUZZ_SKIP_BIOS") == "" and bootdir != "none"
  var bootrom = ""
  if run_bios:
    var hdr = newSeq[uint8](0x150)
    let fh = open(rom_path, fmRead)
    discard fh.readBuffer(addr hdr[0], hdr.len)
    fh.close()
    bootrom = bootdir / (if (hdr[0x143] and 0x80) != 0: "cgb_boot.bin" else: "dmg_boot.bin")

  let emu = new_gb(bootrom, rom_path, fifo = fifo, headless = true,
                   run_bios = run_bios)
  emu.post_init()

  var frames = 0
  var counted = 0
  var base, prev, wprev: int
  var n0, o0, e0: uint64
  var mind = high(int)
  var maxd = 0
  var wframes = 0
  var hist: array[128, int]
  while counted < want:
    for ev in script:
      if ev.frame == frames: emu.handle_input(ev.key, ev.pressed)
    emu.step_frame()
    inc frames
    let now = int(gb_total_dots)
    if frames <= skip:
      base = now; prev = now; wprev = now
      n0 = gb_frame_normal; o0 = gb_frame_lcd_off; e0 = gb_frame_lcd_on
      continue
    inc counted
    let d = now - prev
    prev = now
    if d < mind: mind = d
    if d > maxd: maxd = d
    var b = d div 1000
    if b > 127: b = 127
    inc hist[b]
    inc wframes
    if window > 0 and wframes == window:
      let ws = (now - wprev).float / 4194304.0
      echo &"  win frame={frames} fps={wframes.float / ws:.4f}"
      wprev = now
      wframes = 0
  let dots = int(gb_total_dots) - base
  let secs = dots.float / 4194304.0
  echo &"emu=dingbat rom={rom_path} frames={counted} dots={dots} secs={secs:.6f} " &
       &"fps={counted.float / secs:.4f}"
  echo &"  per-frame dots: min={mind} max={maxd} mean={dots.float / counted.float:.1f}"
  echo &"  pushes: normal={gb_frame_normal - n0} lcd_off={gb_frame_lcd_off - o0} " &
       &"lcd_on_catchup={gb_frame_lcd_on - e0}"
  var s = "  hist(kdots):"
  for i, c in hist:
    if c > 0: s.add &" {i}:{c}"
  echo s

main()
