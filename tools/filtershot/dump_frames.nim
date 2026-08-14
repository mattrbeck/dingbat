## filtershot: dump raw BGR555 frames from a headless run, so the web
## presenter's actual GLSL upscale filters can be applied to them offline
## (tools/filtershot/render.mjs) for side-by-side filter comparisons.
##
##   dump_frames <rom(.gb|.gbc|.gba)> <outprefix> <script> <shots> [panel]
##
##   script: comma-separated FRAME:KEY[:HOLD] ("" for none) — same contract as
##           tools/romfuzz/dingbat_nav.nim / tools/gbfuzz/dingbat_gb_nav.nim
##   shots:  comma-separated frame numbers; each writes
##           <outprefix>.f<frame>.rgb555 — raw little-endian uint16 pixels,
##           row-major from the top-left, exactly the buffer the presenters
##           upload. Prints "W H" once so the renderer knows the shape.
##   panel:  off (default) | auto | dmg | cgb | agb | ags — drive the LCD
##           response model alongside and ALSO write the responded frame at
##           each shot as <outprefix>.f<frame>.ghost.rgb555 (the model advances
##           every frame, exactly as the frontends run it, so a shot's ghost
##           state reflects the whole run up to it). The pair feeds
##           render.mjs's ghost modes for old-vs-new order comparisons.
##
## Build: nim c -d:test_harness -d:release --path:src \
##          -o:tools/filtershot/dump_frames tools/filtershot/dump_frames.nim

import std/[os, strutils, strformat]
import dingbat/gba/gba
import dingbat/gb/gb
import dingbat/common/input
import dingbat/common/lcd_response
import dingbat/common/test_output

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

proc write_raw(path: string; buf: pointer; pixels: int) =
  var f = open(path, fmWrite)
  discard f.writeBuffer(buf, pixels * 2)
  f.close()

proc shot_path(prefix: string; frame: int; ghost: bool): string =
  # Plain concatenation: strformat's `&` does not survive template expansion.
  prefix & ".f" & align($frame, 4, '0') & (if ghost: ".ghost" else: "") &
    ".rgb555"

proc main() =
  let args = commandLineParams()
  if args.len notin 4 .. 5:
    echo "usage: dump_frames <rom> <outprefix> <script> <shots> [panel]"
    quit(2)
  let rom_path = args[0]
  let prefix = args[1]
  let script = parse_script(args[2])
  var shots: seq[int]
  for tok in args[3].split(','):
    if tok.len > 0: shots.add(parseInt(tok))
  let panel_arg = if args.len > 4: args[4] else: "off"
  var max_frame = 0
  for s in shots: max_frame = max(max_frame, s)
  var resp: LcdResponse

  # One loop body serves both cores: step, feed the response model (its state
  # must advance EVERY frame, exactly as the frontends run it, not only at
  # shots), and dump the clean/responded pair.
  template run(emu: untyped; w, h: int) =
    for f in 0 .. max_frame:
      for ev in script:
        if ev.frame == f: emu.handle_input(ev.key, ev.pressed)
      emu.step_frame()
      let clean = cast[ptr UncheckedArray[uint16]](addr emu.ppu.framebuffer[0])
      let ghost = resp.apply(clean, w * h)   # == clean when the panel is off
      if f in shots:
        write_raw(shot_path(prefix, f, false), clean, w * h)
        if resp.active:
          write_raw(shot_path(prefix, f, true), ghost, w * h)

  if rom_path.toLowerAscii().endsWith(".gba"):
    let emu = new_gba("", rom_path, run_bios = false, use_hle = true)
    emu.test_output = new_test_output()
    emu.post_init()
    resp.set_panel(parse_panel(panel_arg, gba = true, cgb = false))
    echo "240 160"
    run(emu, 240, 160)
  else:
    let emu = new_gb("", rom_path, fifo = true, headless = true,
                     run_bios = false)
    emu.post_init()
    resp.set_panel(parse_panel(panel_arg, gba = false, cgb = emu.cgb_enabled))
    echo "160 144"
    run(emu, 160, 144)

main()
